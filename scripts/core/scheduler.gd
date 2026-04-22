class_name Scheduler
extends RefCounted

signal phase_changed(phase_name: String)
signal tick_completed(tick_no: int)
signal event_emitted(event: Dictionary)   # 年代記用の重大イベント
signal action_applied(agent_id: int, action: Action, snapshot: Dictionary)   # 1 アクション適用直後の状態

enum Phase { IDLE, OBSERVE, DECIDE, COMMIT }

const DIRS_4: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

const VISION_RADIUS: int = 3

# 1 tick 内で同時実行できるアクションの物理的上限。
# - 声は 1 つ(speak は 1 回)
# - 歩は連続可能(move 複数)、身体接触系や食事系も連続可能
# - 合計 5 個(1 tick で詰め込める動作の限界)
# 実行順は harness では決めない。エージェントが指定した配列の順にそのまま流す。
const TICK_MAX_ACTIONS: int = 5
const PER_KIND_MAX := {
	Action.Kind.WAIT: 1,
	Action.Kind.MOVE: 3,
	Action.Kind.TAKE: 5,   # take 固有の上限なし。5 アクション/tick の全体上限のみ。
	Action.Kind.EAT: 2,
	Action.Kind.GIVE: 2,
	Action.Kind.ATTACK: 2,
	Action.Kind.EMBRACE: 2,
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
var eat_hunger_restore: int = 25
var attack_health_damage: int = 15
var starving_health_drain: int = 2
# stamina 関連
var move_stamina: int = 2
var take_stamina: int = 1
var eat_stamina: int = 0
var give_stamina: int = 2
var attack_stamina_cost: int = 12
var attack_stamina_target_drain: int = 3
var embrace_stamina_cost: int = 5
var embrace_stamina_gift: int = 3
var speak_stamina: int = 2
var wait_stamina_restore: int = 10

# 関係性の更新量(config.json の relations セクションで上書き可能)
var rel_affection_per_give: int = 10
var rel_trust_per_give: int = 5
var rel_affection_per_attack: int = -20
var rel_trust_per_attack: int = -15
var rel_affection_per_embrace: int = 5
var rel_trust_per_embrace: int = 2
var rel_affection_per_speak_addressed: int = 1
var rel_trust_per_speak_addressed: int = 1
var rel_affection_per_witness_attack: int = -5

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
	eat_hunger_restore = int(cfg.get("eat_hunger_restore", eat_hunger_restore))
	attack_health_damage = int(cfg.get("attack_health_damage", attack_health_damage))
	starving_health_drain = int(cfg.get("starving_health_drain", starving_health_drain))
	move_stamina = int(cfg.get("move_stamina", move_stamina))
	take_stamina = int(cfg.get("take_stamina", take_stamina))
	eat_stamina = int(cfg.get("eat_stamina", eat_stamina))
	give_stamina = int(cfg.get("give_stamina", give_stamina))
	attack_stamina_cost = int(cfg.get("attack_stamina_cost", attack_stamina_cost))
	attack_stamina_target_drain = int(cfg.get("attack_stamina_target_drain", attack_stamina_target_drain))
	embrace_stamina_cost = int(cfg.get("embrace_stamina_cost", embrace_stamina_cost))
	embrace_stamina_gift = int(cfg.get("embrace_stamina_gift", embrace_stamina_gift))
	speak_stamina = int(cfg.get("speak_stamina", speak_stamina))
	wait_stamina_restore = int(cfg.get("wait_stamina_restore", wait_stamina_restore))

func configure_relations(cfg: Dictionary) -> void:
	rel_affection_per_give = int(cfg.get("affection_per_give", rel_affection_per_give))
	rel_trust_per_give = int(cfg.get("trust_per_give", rel_trust_per_give))
	rel_affection_per_attack = int(cfg.get("affection_per_attack", rel_affection_per_attack))
	rel_trust_per_attack = int(cfg.get("trust_per_attack", rel_trust_per_attack))
	rel_affection_per_embrace = int(cfg.get("affection_per_embrace", rel_affection_per_embrace))
	rel_trust_per_embrace = int(cfg.get("trust_per_embrace", rel_trust_per_embrace))
	rel_affection_per_speak_addressed = int(cfg.get("affection_per_speak_addressed", rel_affection_per_speak_addressed))
	rel_trust_per_speak_addressed = int(cfg.get("trust_per_speak_addressed", rel_trust_per_speak_addressed))
	rel_affection_per_witness_attack = int(cfg.get("affection_per_witness_attack", rel_affection_per_witness_attack))

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
		# per-action スナップショットを emit
		action_applied.emit(agent.id, action, {
			"hunger": agent.hunger,
			"health": agent.health,
			"stamina": agent.stamina,
			"pos": [agent.grid_pos.x, agent.grid_pos.y],
			"inventory_size": agent.inventory.size(),
		})
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
	var pre_health: int = agent.health
	agent.apply_tick_decay(tick_base_hunger, starving_health_drain)
	if pre_health > 0 and agent.health <= 0:
		_emit_death(agent, "starvation", null)

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
			# 休息。stamina を回復(max を超えない)。
			agent.gain_stamina(wait_stamina_restore)
			action.succeeded = true
			return
		Action.Kind.TAKE:
			# 9 マス(自タイル + 8 近傍)からの拾得を許容。direction は (-1..1, -1..1)。
			var tdir: Vector2i = action.direction
			if absi(tdir.x) > 1 or absi(tdir.y) > 1:
				action.failure_note = "out_of_reach"
				return
			var tx: int = agent.grid_pos.x + tdir.x
			var ty: int = agent.grid_pos.y + tdir.y
			if not _in_bounds(tx, ty):
				action.failure_note = "out_of_bounds"
				return
			if not agent.inventory_has_space():
				action.failure_note = "inventory_full"
				return
			if not agent.can_afford_stamina(take_stamina):
				action.failure_note = "exhausted"
				return
			var nut: int = resources.take(tx, ty)
			if nut > 0:
				agent.inventory_add("food")
				agent.spend_stamina(take_stamina)
				action.succeeded = true
			else:
				action.failure_note = "no_food_there"
		Action.Kind.EAT:
			# eat は stamina コストが 0 なので疲労時でも食える(生存権)。
			if agent.inventory_remove_first("food"):
				agent.eat_amount(eat_hunger_restore)
				agent.spend_stamina(eat_stamina)
				action.succeeded = true
			else:
				var nut: int = resources.take(agent.grid_pos.x, agent.grid_pos.y)
				if nut > 0:
					agent.eat_amount(nut)
					agent.spend_stamina(eat_stamina)
					action.succeeded = true
				else:
					action.failure_note = "no_food_available"
		Action.Kind.GIVE:
			_apply_give(agent, action)
		Action.Kind.ATTACK:
			_apply_attack(agent, action)
		Action.Kind.EMBRACE:
			_apply_embrace(agent, action)
		Action.Kind.MOVE:
			var dir: Vector2i = action.direction
			var step1 := agent.grid_pos + dir
			# 1 歩目の成立可否
			if not _in_bounds(step1.x, step1.y):
				action.failure_note = "out_of_bounds"
				return
			if not world.is_passable(step1.x, step1.y):
				action.failure_note = "impassable"
				return
			var final_pos: Vector2i = step1
			var slid: bool = false
			if occupied.has(step1) and occupied[step1] != agent.id:
				# 1 歩目が他者で占有 → すれ違いで +1 滑り抜けを試す(最大 1 タイルのみ)
				var step2 := agent.grid_pos + dir * 2
				if not _in_bounds(step2.x, step2.y):
					action.failure_note = "occupied_blocked"
					return
				if not world.is_passable(step2.x, step2.y):
					action.failure_note = "occupied_blocked"
					return
				if occupied.has(step2) and occupied[step2] != agent.id:
					action.failure_note = "occupied_blocked"
					return
				final_pos = step2
				slid = true
			if not agent.can_afford_stamina(move_stamina):
				action.failure_note = "exhausted"
				return
			occupied.erase(agent.grid_pos)
			occupied[final_pos] = agent.id
			agent.grid_pos = final_pos
			agent.hunger = max(0, agent.hunger - move_hunger)
			agent.spend_stamina(move_stamina)
			action.succeeded = true
			if slid:
				action.failure_note = "slid_past"   # 失敗ではないが記録用マーカー
		Action.Kind.SPEAK:
			if not agent.can_afford_stamina(speak_stamina):
				action.failure_note = "exhausted"
				return
			agent.hunger = max(0, agent.hunger - speak_hunger)
			agent.spend_stamina(speak_stamina)
			_propagate_speech(agent, action)
			action.succeeded = true

# --- 新しい物理動作(Phase 4) ---

func _get_agent_by_id(target_id: int) -> Agent:
	for a in agents:
		if a.id == target_id:
			return a
	return null

func _is_adjacent(a: Agent, b: Agent) -> bool:
	var dx: int = absi(a.grid_pos.x - b.grid_pos.x)
	var dy: int = absi(a.grid_pos.y - b.grid_pos.y)
	return (dx + dy) == 1

# Chebyshev 距離(8 近傍を半径 r の square)で視認可能か。
# give は遠投可能という想定で VISION_RADIUS(3)内を許容。
func _within_vision(a: Agent, b: Agent) -> bool:
	var dx: int = absi(a.grid_pos.x - b.grid_pos.x)
	var dy: int = absi(a.grid_pos.y - b.grid_pos.y)
	return dx <= VISION_RADIUS and dy <= VISION_RADIUS

func _emit_event(event: Dictionary) -> void:
	event_emitted.emit(event)

func _emit_death(victim: Agent, cause: String, killer: Agent) -> void:
	var text: String
	if cause == "attack" and killer != null:
		text = "%s が %s に攻撃されて倒れた" % [victim.agent_name, killer.agent_name]
	elif cause == "starvation":
		text = "%s が餓死した" % victim.agent_name
	else:
		text = "%s が倒れた" % victim.agent_name
	_emit_event({
		"tick": tick,
		"kind": "death",
		"actor_id": killer.id if killer != null else -1,
		"target_id": victim.id,
		"position": victim.grid_pos,
		"cause": cause,
		"text": text,
	})
	# 加害者側の life_event: 自身が致死に至らせた事実
	if killer != null:
		killer.append_life_event(tick, "私が %s を殺した" % victim.agent_name)
	# 視界内の生存者に broadcast(目撃証言)
	for witness in agents:
		if witness.id == victim.id:
			continue
		if not witness.is_alive():
			continue
		var dxw: int = absi(witness.grid_pos.x - victim.grid_pos.x)
		var dyw: int = absi(witness.grid_pos.y - victim.grid_pos.y)
		if dxw > VISION_RADIUS or dyw > VISION_RADIUS:
			continue
		witness.recent_events.append("%s が倒れた" % victim.agent_name)
		while witness.recent_events.size() > 5:
			witness.recent_events.pop_front()
		# 死亡目撃は長期記憶にも刻む
		var life_text: String
		if cause == "attack" and killer != null:
			life_text = "%s が %s に殺されるのを見た" % [victim.agent_name, killer.agent_name]
		elif cause == "starvation":
			life_text = "%s が餓死するのを見た" % victim.agent_name
		else:
			life_text = "%s が倒れるのを見た" % victim.agent_name
		witness.append_life_event(tick, life_text)

func _apply_give(agent: Agent, action: Action) -> void:
	var target := _get_agent_by_id(action.target_id)
	if target == null or not target.is_alive():
		action.failure_note = "target_invalid"
		return
	# give は視界半径内なら可(遠投 / 手渡し両方想定)
	if not _within_vision(agent, target):
		action.failure_note = "out_of_range"
		return
	if agent.inventory.is_empty():
		action.failure_note = "nothing_to_give"
		return
	if not target.inventory_has_space():
		action.failure_note = "target_inventory_full"
		return
	if not agent.can_afford_stamina(give_stamina):
		action.failure_note = "exhausted"
		return
	var item: String = agent.inventory[0]
	agent.inventory.remove_at(0)
	target.inventory_add(item)
	agent.spend_stamina(give_stamina)
	target.adjust_relation(agent.id, rel_affection_per_give, rel_trust_per_give, tick)
	agent.adjust_relation(target.id, 1, 0, tick)
	agent.append_interaction(target.id, tick, "私が %s に食料を渡した" % target.agent_name)
	target.append_interaction(agent.id, tick, "%s から食料を受け取った" % agent.agent_name)
	agent.append_life_event(tick, "私が %s に食料を渡した" % target.agent_name)
	target.append_life_event(tick, "%s から食料を受け取った" % agent.agent_name)
	action.succeeded = true
	_emit_event({
		"tick": tick,
		"kind": "give",
		"actor_id": agent.id,
		"target_id": target.id,
		"position": agent.grid_pos,
		"text": "%s が %s に食料を与えた" % [agent.agent_name, target.agent_name],
	})

func _apply_attack(agent: Agent, action: Action) -> void:
	var target := _get_agent_by_id(action.target_id)
	if target == null or not target.is_alive():
		action.failure_note = "target_invalid"
		return
	if not _is_adjacent(agent, target):
		action.failure_note = "not_adjacent"
		return
	if not agent.can_afford_stamina(attack_stamina_cost):
		action.failure_note = "exhausted"
		return
	var pre_health: int = target.health
	target.health = max(0, target.health - attack_health_damage)
	agent.spend_stamina(attack_stamina_cost)
	target.spend_stamina(attack_stamina_target_drain)
	action.succeeded = true
	agent.append_interaction(target.id, tick, "私が %s を攻撃した" % target.agent_name)
	target.append_interaction(agent.id, tick, "%s に攻撃された" % agent.agent_name)
	agent.append_life_event(tick, "私が %s を攻撃した" % target.agent_name)
	target.append_life_event(tick, "%s に攻撃された" % agent.agent_name)
	_emit_event({
		"tick": tick,
		"kind": "attack",
		"actor_id": agent.id,
		"target_id": target.id,
		"position": target.grid_pos,
		"text": "%s が %s を攻撃した (%d → %d)" % [agent.agent_name, target.agent_name, pre_health, target.health],
	})
	# 第三者目撃: 視界内の他エージェントは witnesses 扱い(interactions に観察を追記)
	for witness in agents:
		if witness.id == agent.id or witness.id == target.id:
			continue
		if not witness.is_alive():
			continue
		var dxw: int = absi(witness.grid_pos.x - agent.grid_pos.x)
		var dyw: int = absi(witness.grid_pos.y - agent.grid_pos.y)
		if dxw > VISION_RADIUS or dyw > VISION_RADIUS:
			continue
		witness.append_interaction(agent.id, tick, "%s が %s を攻撃するのを見た" % [agent.agent_name, target.agent_name])
		witness.append_life_event(tick, "%s が %s を攻撃するのを見た" % [agent.agent_name, target.agent_name])
	# 致死判定
	if pre_health > 0 and target.health <= 0:
		_emit_death(target, "attack", agent)
	# 関係更新
	target.adjust_relation(agent.id, rel_affection_per_attack, rel_trust_per_attack, tick)
	agent.adjust_relation(target.id, rel_affection_per_attack / 2, rel_trust_per_attack / 2, tick)
	# 第三者目撃: 視界内の他エージェントは攻撃者への印象が下がる
	for witness in agents:
		if witness.id == agent.id or witness.id == target.id:
			continue
		if not witness.is_alive():
			continue
		var dxw: int = absi(witness.grid_pos.x - agent.grid_pos.x)
		var dyw: int = absi(witness.grid_pos.y - agent.grid_pos.y)
		if dxw > VISION_RADIUS or dyw > VISION_RADIUS:
			continue
		witness.adjust_relation(agent.id, rel_affection_per_witness_attack, 0, tick)
		# 目撃イベントを recent_events に
		var line := "%s が %s を攻撃した" % [agent.agent_name, target.agent_name]
		witness.recent_events.append(line)
		while witness.recent_events.size() > 5:
			witness.recent_events.pop_front()
	# 被害者自身の recent_events
	target.recent_events.append("%s に攻撃された" % agent.agent_name)
	while target.recent_events.size() > 5:
		target.recent_events.pop_front()

func _apply_embrace(agent: Agent, action: Action) -> void:
	var target := _get_agent_by_id(action.target_id)
	if target == null or not target.is_alive():
		action.failure_note = "target_invalid"
		return
	if not _is_adjacent(agent, target):
		action.failure_note = "not_adjacent"
		return
	if not agent.can_afford_stamina(embrace_stamina_cost):
		action.failure_note = "exhausted"
		return
	# 非対称コスト: する側 -5, される側 +3(癒される)
	agent.spend_stamina(embrace_stamina_cost)
	target.gain_stamina(embrace_stamina_gift)
	target.adjust_relation(agent.id, rel_affection_per_embrace, rel_trust_per_embrace, tick)
	agent.adjust_relation(target.id, rel_affection_per_embrace, rel_trust_per_embrace, tick)
	agent.append_interaction(target.id, tick, "私が %s を抱擁した" % target.agent_name)
	target.append_interaction(agent.id, tick, "%s が私を抱擁した" % agent.agent_name)
	agent.append_life_event(tick, "私が %s を抱擁した" % target.agent_name)
	target.append_life_event(tick, "%s が私を抱擁した" % agent.agent_name)
	action.succeeded = true
	_emit_event({
		"tick": tick,
		"kind": "embrace",
		"actor_id": agent.id,
		"target_id": target.id,
		"position": agent.grid_pos,
		"text": "%s が %s を抱擁した" % [agent.agent_name, target.agent_name],
	})
	target.recent_events.append("%s に寄り添われた" % agent.agent_name)
	while target.recent_events.size() > 5:
		target.recent_events.pop_front()

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
		var addressed: bool = has_target and other.id in action.speech_target_ids
		if addressed:
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
			# 自分宛に話しかけられた → 話者への好感度/信頼度を微増
			other.adjust_relation(speaker.id, rel_affection_per_speak_addressed, rel_trust_per_speak_addressed, tick)
		elif has_target:
			line = "%s→%s:「%s」" % [speaker.agent_name, targets_label, action.speech_text]
		else:
			line = "%s:「%s」" % [speaker.agent_name, action.speech_text]
		other.recent_events.append(line)
		while other.recent_events.size() > 5:
			other.recent_events.pop_front()

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < world.size and y < world.size

func _summarize_action(action: Action) -> String:
	var base: String = ""
	match action.kind:
		Action.Kind.WAIT:
			base = "wait"
		Action.Kind.MOVE:
			var dir := ""
			match action.direction:
				Vector2i(0, -1): dir = "↑"
				Vector2i(0, 1):  dir = "↓"
				Vector2i(1, 0):  dir = "→"
				Vector2i(-1, 0): dir = "←"
				Vector2i(1, -1): dir = "↗"
				Vector2i(-1, -1): dir = "↖"
				Vector2i(1, 1):  dir = "↘"
				Vector2i(-1, 1): dir = "↙"
				_: dir = "?"
			base = "move " + dir
		Action.Kind.TAKE:
			base = "take food"
		Action.Kind.EAT:
			base = "eat"
		Action.Kind.GIVE:
			base = "give"
		Action.Kind.ATTACK:
			base = "attack"
		Action.Kind.EMBRACE:
			base = "embrace"
		Action.Kind.SPEAK:
			base = "speak \"%s\"" % action.speech_text
		_:
			base = "?"
	# 失敗時は LLM が振り返れるように理由を併記(wait/speak は常に成功扱い)
	if not action.succeeded and action.kind != Action.Kind.WAIT and action.kind != Action.Kind.SPEAK:
		var note: String = action.failure_note if action.failure_note != "" else "failed"
		return "%s (failed:%s)" % [base, note]
	return base

func _summarize_bundle(ordered: Array) -> String:
	if ordered.is_empty():
		return "wait"
	var parts: Array[String] = []
	for a in ordered:
		parts.append(_summarize_action(a))
	return " + ".join(parts)
