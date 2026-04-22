class_name Scheduler
extends RefCounted

signal phase_changed(phase_name: String)
signal tick_completed(tick_no: int)

enum Phase { IDLE, OBSERVE, DECIDE, COMMIT }

const DIRS_4: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

const VISION_RADIUS: int = 3

# 1 tick 内で同時実行できるアクションの物理的上限。
# - 同 kind は 1 回(身体は 1 つ、同時に 2 歩や 2 発話は不可)
# - 合計 3 個(1 tick で詰め込める動作の限界)
# 実行順は harness では決めない。エージェントが指定した配列の順にそのまま流す。
const TICK_MAX_ACTIONS: int = 3
const PER_KIND_MAX := {
	Action.Kind.WAIT: 1,
	Action.Kind.MOVE: 1,
	Action.Kind.TAKE: 1,
	Action.Kind.SPEAK: 1,
}

var world: World
var resources: ResourceField
var agents: Array
var rng: RandomNumberGenerator

var tick: int = 0
var day: int = 0
var tick_per_day: int = 10
var phase: int = Phase.IDLE

# コスト(config.json の costs セクションで上書き可能)
var tick_base_hunger: int = 1
var move_hunger: int = 2
var speak_hunger: int = 1
var starving_health_drain: int = 2

func _init(world_: World, resources_: ResourceField, agents_: Array, seed_: int, tick_per_day_: int = 10) -> void:
	world = world_
	resources = resources_
	agents = agents_
	tick_per_day = tick_per_day_
	rng = RandomNumberGenerator.new()
	rng.seed = seed_ ^ 0x2468ACE0

func configure_costs(cfg: Dictionary) -> void:
	tick_base_hunger = int(cfg.get("tick_base_hunger", tick_base_hunger))
	move_hunger = int(cfg.get("move_hunger", move_hunger))
	speak_hunger = int(cfg.get("speak_hunger", speak_hunger))
	starving_health_drain = int(cfg.get("starving_health_drain", starving_health_drain))

func step() -> void:
	# Phase 2 互換の同期 step。Phase 3 以降は Main が
	# observe() → (外部 decide 非同期) → commit(decisions) → advance_tick() を駆動する。
	observe()
	var decisions := decide_local_all()
	commit(decisions)
	advance_tick()

# --- public phases (Phase 3 async driver 用) ---

func observe() -> void:
	phase = Phase.OBSERVE
	phase_changed.emit("Observe")

func enter_decide_phase() -> void:
	phase = Phase.DECIDE
	phase_changed.emit("Decide")

func decide_local_all() -> Array:
	enter_decide_phase()
	var decisions: Array = []
	for agent in agents:
		if not agent.is_alive():
			decisions.append([Action.wait()] as Array)
			continue
		# ローカルロジックは単一アクション(Array に包む)
		decisions.append([_decide_local(agent)] as Array)
	return decisions

# 入力されたアクション列を物理制約(per-kind 1 回、合計上限)だけでフィルタする。
# 順序は harness で並べ替えない。エージェントが指定した配列の順序を保持する。
# 物理的に実行できないアクション(水タイルへの move 等)は apply 時に静かに失敗する。
func sanitize_bundle(bundle: Array) -> Array:
	var seen_counts: Dictionary = {}
	var kept: Array = []
	for a in bundle:
		if not (a is Action):
			continue
		var kind: int = a.kind
		var cap: int = int(PER_KIND_MAX.get(kind, 1))
		var cur: int = int(seen_counts.get(kind, 0))
		if cur >= cap:
			continue
		seen_counts[kind] = cur + 1
		kept.append(a)
		if kept.size() >= TICK_MAX_ACTIONS:
			break
	return kept

func commit(decisions: Array) -> void:
	# ローカル経路(LLM 未使用)用。agent_id 順で各 bundle を順次 apply する。
	phase = Phase.COMMIT
	phase_changed.emit("Commit")
	var sorted_idx: Array = range(agents.size())
	sorted_idx.sort_custom(func(a, b): return agents[a].id < agents[b].id)
	for idx in sorted_idx:
		var agent: Agent = agents[idx]
		var bundle: Array = decisions[idx] if idx < decisions.size() else []
		if not agent.is_alive():
			continue
		apply_bundle_for_agent(agent, bundle)

# LLM 経路ではレスポンスが返ってきた瞬間(first-come-first-served)に個別 apply する。
# 衝突解決: 先に応答が返ったエージェントが tile を占有する。
# 入力側(LLM に渡す world state)は decide_all 開始時にスナップショット済みなので
# 適用が non-deterministic でも LLM の意思決定自体は frozen state に基づく。
func apply_bundle_for_agent(agent: Agent, bundle: Array) -> void:
	if not agent.is_alive():
		return
	var occupied: Dictionary = {}
	for a in agents:
		if a.id != agent.id:
			occupied[a.grid_pos] = a.id
	var ordered := sanitize_bundle(bundle)
	var primary_reason: String = ""
	for action in ordered:
		_apply_action(agent, action, occupied)
		if primary_reason == "" and action.reason != "":
			primary_reason = action.reason
		if action.kind == Action.Kind.SPEAK:
			agent.last_speech = action.speech_text
			agent.last_speech_tick = tick
			agent.last_speech_target_ids = action.speech_target_ids
	if ordered.is_empty():
		agent.last_action_kind = Action.Kind.WAIT
		agent.last_action_reason = ""
	else:
		agent.last_action_kind = ordered[-1].kind
		agent.last_action_reason = primary_reason
	var summary: String = _summarize_bundle(ordered)
	agent.own_history.append("t%d %s" % [tick, summary])
	while agent.own_history.size() > 5:
		agent.own_history.pop_front()
	agent.apply_tick_decay(tick_base_hunger, starving_health_drain)

func finalize_tick() -> void:
	# tick 境界で resource 再生と day 進行を処理。LLM 経路で apply_bundle_for_agent を
	# 個別に呼び終えたあとに 1 度だけ呼ぶ。
	resources.tick_regen()
	tick += 1
	if tick_per_day > 0 and tick % tick_per_day == 0:
		day += 1
	phase = Phase.IDLE
	phase_changed.emit("Idle")
	tick_completed.emit(tick)

func advance_tick() -> void:
	# 旧 API。finalize_tick() のエイリアス。
	finalize_tick()

# 互換エイリアス(既存呼び出しサイトのため残す)
func decide_local_for(agent: Agent) -> Action:
	return _decide_local(agent)

# --- local decide ---

func _decide_local(agent: Agent) -> Action:
	var pos: Vector2i = agent.grid_pos
	if resources.has_food(pos.x, pos.y):
		return Action.take()
	var target := _nearest_visible_food(agent)
	if target.x >= 0:
		var dir := _step_toward(pos, target)
		if dir != Vector2i.ZERO:
			return Action.move(dir)
	var rnd_dir := _random_passable_dir(pos)
	if rnd_dir == Vector2i.ZERO:
		return Action.wait()
	return Action.move(rnd_dir)

func _nearest_visible_food(agent: Agent) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist := 9999
	var p: Vector2i = agent.grid_pos
	for dy in range(-VISION_RADIUS, VISION_RADIUS + 1):
		for dx in range(-VISION_RADIUS, VISION_RADIUS + 1):
			var x := p.x + dx
			var y := p.y + dy
			if not _in_bounds(x, y):
				continue
			if not resources.has_food(x, y):
				continue
			var d: int = absi(dx) + absi(dy)
			if d > 0 and d < best_dist:
				best_dist = d
				best = Vector2i(x, y)
	return best

func _step_toward(from: Vector2i, to: Vector2i) -> Vector2i:
	var dx: int = sign(to.x - from.x)
	var dy: int = sign(to.y - from.y)
	# 優先軸: 距離が大きい方を先に詰める
	var ax: int = abs(to.x - from.x)
	var ay: int = abs(to.y - from.y)
	var candidates: Array[Vector2i] = []
	if ax >= ay:
		if dx != 0:
			candidates.append(Vector2i(dx, 0))
		if dy != 0:
			candidates.append(Vector2i(0, dy))
	else:
		if dy != 0:
			candidates.append(Vector2i(0, dy))
		if dx != 0:
			candidates.append(Vector2i(dx, 0))
	for c in candidates:
		var nx := from.x + c.x
		var ny := from.y + c.y
		if _in_bounds(nx, ny) and world.is_passable(nx, ny):
			return c
	return Vector2i.ZERO

func _random_passable_dir(pos: Vector2i) -> Vector2i:
	var shuffled: Array[Vector2i] = DIRS_4.duplicate()
	shuffled.shuffle()
	for d: Vector2i in shuffled:
		var nx: int = pos.x + d.x
		var ny: int = pos.y + d.y
		if _in_bounds(nx, ny) and world.is_passable(nx, ny):
			return d
	return Vector2i.ZERO

# --- apply ---

func _apply_action(agent: Agent, action: Action, occupied: Dictionary) -> void:
	match action.kind:
		Action.Kind.WAIT:
			return
		Action.Kind.TAKE:
			# take は成功時のみ +food_nutrition。失敗(食料なし)はコストもゼロ。
			var nut: int = resources.take(agent.grid_pos.x, agent.grid_pos.y)
			if nut > 0:
				agent.eat(nut)
		Action.Kind.MOVE:
			var target := agent.grid_pos + action.direction
			if not _in_bounds(target.x, target.y):
				return
			if not world.is_passable(target.x, target.y):
				return
			if occupied.has(target) and occupied[target] != agent.id:
				return
			# 成功時のみコスト。失敗(衝突/水など)はエネルギー消費なし。
			occupied.erase(agent.grid_pos)
			occupied[target] = agent.id
			agent.grid_pos = target
			agent.hunger = max(0, agent.hunger - move_hunger)
		Action.Kind.SPEAK:
			# 発声は物理的にエネルギーを消費する。失敗条件は現状ないので常に徴収。
			agent.hunger = max(0, agent.hunger - speak_hunger)
			_propagate_speech(agent, action)

func _propagate_speech(speaker: Agent, action: Action) -> void:
	# broadcast: 話者の視界半径 3 内全員に伝達。
	# target_ids の扱いは音声イベントのラベリングだけで、物理的伝達範囲には影響しない。
	var has_target: bool = action.speech_target_ids.size() > 0
	# target 名前リスト(傍聞き表示用)
	var target_names: Array[String] = []
	if has_target:
		for tid in action.speech_target_ids:
			for a in agents:
				if a.id == tid:
					target_names.append(a.agent_name)
					break
	var targets_label: String = ",".join(target_names)
	for other in agents:
		if other.id == speaker.id:
			continue
		if not other.is_alive():
			continue
		var dx: int = absi(other.grid_pos.x - speaker.grid_pos.x)
		var dy: int = absi(other.grid_pos.y - speaker.grid_pos.y)
		if dx > VISION_RADIUS or dy > VISION_RADIUS:
			continue
		var line: String
		if has_target and other.id in action.speech_target_ids:
			# 自分が target に含まれている
			if action.speech_target_ids.size() > 1:
				var others_names: Array[String] = []
				for nm in target_names:
					if nm != other.agent_name:
						others_names.append(nm)
				if others_names.size() > 0:
					line = "%s→あなた,%s:「%s」" % [speaker.agent_name, ",".join(others_names), action.speech_text]
				else:
					line = "%s→あなた:「%s」" % [speaker.agent_name, action.speech_text]
			else:
				line = "%s→あなた:「%s」" % [speaker.agent_name, action.speech_text]
		elif has_target:
			# target に含まれない傍聞き
			line = "%s→%s:「%s」" % [speaker.agent_name, targets_label, action.speech_text]
		else:
			# 不特定発話
			line = "%s:「%s」" % [speaker.agent_name, action.speech_text]
		other.recent_events.append(line)
		while other.recent_events.size() > 5:
			other.recent_events.pop_front()

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < world.size and y < world.size

func _summarize_action(action: Action) -> String:
	match action.kind:
		Action.Kind.WAIT:
			return "wait"
		Action.Kind.MOVE:
			var dir := ""
			if action.direction == Vector2i(0, -1):
				dir = "N"
			elif action.direction == Vector2i(0, 1):
				dir = "S"
			elif action.direction == Vector2i(1, 0):
				dir = "E"
			elif action.direction == Vector2i(-1, 0):
				dir = "W"
			return "move " + dir
		Action.Kind.TAKE:
			return "take food"
		Action.Kind.SPEAK:
			return "speak \"%s\"" % action.speech_text
		_:
			return "?"

func _summarize_bundle(ordered: Array) -> String:
	if ordered.is_empty():
		return "wait"
	var parts: Array[String] = []
	for a in ordered:
		parts.append(_summarize_action(a))
	return " + ".join(parts)
