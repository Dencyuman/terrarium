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
	Action.Kind.LOOK: 1,
	Action.Kind.REPRODUCE_WITH: 1,
}

const LOOK_LENGTH: int = 5   # 覗き見る奥行き(方向 5 マス)
const LOOK_HALF_WIDTH: int = 1   # 幅 ±1(合計 3)

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
var grass_move_hunger: int = 2
var forest_move_hunger: int = 2
var rock_move_hunger: int = 4   # 岩タイル上の move に適用される hunger コスト(草地/森より高い)
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
var look_stamina: int = 2
# Phase 5 加齢 / 老衰
var elder_age_days: int = 6      # この日数以上で老衰による health drain が始まる
var elder_health_drain: int = 2  # 老衰時の 1 tick あたり health 減少
# Phase 5 生殖
var reproduce_stamina_cost: int = 20
var reproduce_hunger_cost: int = 10
var reproduce_success_prob: float = 0.5
# Phase 5.E 内的衝動: libido(性欲)
var puberty_age_days: int = 2            # この age 以降 libido が蓄積し始める(第二次性徴)
var libido_initial: int = 20             # puberty 到達時の初期値
var libido_gain_per_tick: int = 5        # puberty 後の自然蓄積
var libido_fail_penalty: int = 10        # reproduce 失敗時の減衰(2 tick 分)
# Phase 5.E 内的衝動: aggression_pressure(攻撃衝動)
var aggr_starving_gain: int = 4          # hunger == 0 時の蓄積
var aggr_on_attacked: int = 40           # 自分が被攻撃時の即時加算
var aggr_on_witness_attack: int = 15     # 攻撃目撃時の加算
var aggr_on_witness_death: int = 20      # 死亡目撃時の加算
var aggr_discharge_on_attack: int = 40   # attack 実行時の減算(発散)
var aggr_decay_on_wait: int = 2          # wait 時の自然減
var aggr_on_embrace_received: int = 15   # embrace を受けたときの減算(鎮め)
# 攻撃以外の発散経路(これが無いと「怒ったらとりあえず攻撃」になる)
var aggr_on_eat: int = 15                # 食事で満腹 → frustration 解消
var aggr_on_give: int = 5                # 利他行動による小さな発散
var aggr_on_speak: int = 3               # 吐露による小さな発散

# tick 内で既に生殖が成立したペア集合(重複妊娠防止)。finalize_tick で clear。
# key: "min_id|max_id" 形式のソート済みペア文字列。
var reproduce_paired_this_tick: Dictionary = {}

# 誕生した子エージェントの命名プール。先頭から使い切ったら "新%d" に fallback。
const NEWBORN_POOL := [
	{"name": "暁", "romaji": "Akatsuki"},
	{"name": "澪", "romaji": "Mio"},
	{"name": "凛", "romaji": "Rin"},
	{"name": "篤", "romaji": "Atsushi"},
	{"name": "朱", "romaji": "Ake"},
	{"name": "翠", "romaji": "Midori"},
	{"name": "柚", "romaji": "Yuzu"},
	{"name": "薫", "romaji": "Kaoru"},
	{"name": "凪", "romaji": "Nagi"},
	{"name": "麗", "romaji": "Rei"},
	{"name": "颯", "romaji": "Hayate"},
	{"name": "蒼", "romaji": "Aoi"},
	{"name": "碧", "romaji": "Heki"},
	{"name": "葉", "romaji": "Ha"},
	{"name": "陽", "romaji": "Haru"},
	{"name": "瑞", "romaji": "Mizu"},
	{"name": "紡", "romaji": "Tsumugi"},
	{"name": "結", "romaji": "Yui"},
	{"name": "燈", "romaji": "Tomoshi"},
	{"name": "稔", "romaji": "Minoru"},
]

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
	# 互換: 旧 "move_hunger" が残っていれば grass/forest のデフォルトとして適用
	var legacy_move: int = int(cfg.get("move_hunger", 2))
	grass_move_hunger = int(cfg.get("grass_move_hunger", legacy_move))
	forest_move_hunger = int(cfg.get("forest_move_hunger", legacy_move))
	rock_move_hunger = int(cfg.get("rock_move_hunger", rock_move_hunger))
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
	look_stamina = int(cfg.get("look_stamina", look_stamina))
	elder_age_days = int(cfg.get("elder_age_days", elder_age_days))
	elder_health_drain = int(cfg.get("elder_health_drain", elder_health_drain))
	reproduce_stamina_cost = int(cfg.get("reproduce_stamina_cost", reproduce_stamina_cost))
	reproduce_hunger_cost = int(cfg.get("reproduce_hunger_cost", reproduce_hunger_cost))
	reproduce_success_prob = float(cfg.get("reproduce_success_prob", reproduce_success_prob))
	puberty_age_days = int(cfg.get("puberty_age_days", puberty_age_days))
	libido_initial = int(cfg.get("libido_initial", libido_initial))
	libido_gain_per_tick = int(cfg.get("libido_gain_per_tick", libido_gain_per_tick))
	libido_fail_penalty = int(cfg.get("libido_fail_penalty", libido_fail_penalty))
	aggr_starving_gain = int(cfg.get("aggr_starving_gain", aggr_starving_gain))
	aggr_on_attacked = int(cfg.get("aggr_on_attacked", aggr_on_attacked))
	aggr_on_witness_attack = int(cfg.get("aggr_on_witness_attack", aggr_on_witness_attack))
	aggr_on_witness_death = int(cfg.get("aggr_on_witness_death", aggr_on_witness_death))
	aggr_discharge_on_attack = int(cfg.get("aggr_discharge_on_attack", aggr_discharge_on_attack))
	aggr_decay_on_wait = int(cfg.get("aggr_decay_on_wait", aggr_decay_on_wait))
	aggr_on_embrace_received = int(cfg.get("aggr_on_embrace_received", aggr_on_embrace_received))
	aggr_on_eat = int(cfg.get("aggr_on_eat", aggr_on_eat))
	aggr_on_give = int(cfg.get("aggr_on_give", aggr_on_give))
	aggr_on_speak = int(cfg.get("aggr_on_speak", aggr_on_speak))

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
	# 移動の占有判定は「自分以外の全エージェント(死体含む)」。
	# 死体もタイルを占有する = 重ならない(UI クリックで 1 体に特定できる)。
	# ただし slide-past が任意距離で働くので、死体も生者も跨いで通過可能。
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
	agent.apply_tick_decay(tick_base_hunger, starving_health_drain, elder_age_days, elder_health_drain)
	if pre_health > 0 and agent.health <= 0:
		# 死因の分離: 空腹 0 なら餓死、そうでなければ老衰
		var cause: String = "starvation" if agent.hunger == 0 else "old_age"
		_emit_death(agent, cause, null)

func finalize_tick() -> void:
	# tick 境界で resource 再生と day 進行を処理。LLM 経路で apply_bundle_for_agent を
	# 個別に呼び終えたあとに 1 度だけ呼ぶ。
	resources.tick_regen()
	tick += 1
	if tick_per_day > 0 and tick % tick_per_day == 0:
		day += 1
		# 日付が進んだら生存中の agent 全員を 1 歳ずつ加齢させる
		for a in agents:
			if a.is_alive():
				a.age_days += 1
	# 内的衝動の tick ごとの自然変動
	for a in agents:
		if not a.is_alive():
			continue
		# libido: puberty 以降に蓄積。初回 puberty 到達時は底上げ。
		if a.age_days >= puberty_age_days:
			if a.libido < libido_initial:
				a.libido = libido_initial
			a.libido = min(100, a.libido + libido_gain_per_tick)
		# aggression_pressure: 空腹 0 でフラストレーション蓄積
		if a.hunger == 0:
			a.aggression_pressure = min(100, a.aggression_pressure + aggr_starving_gain)
	# 生殖ペアの tick-local 記録をクリア(次 tick で持ち越さない)
	reproduce_paired_this_tick.clear()
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
			# 休息。stamina を回復(max を超えない)。攻撃衝動も自然減。
			agent.gain_stamina(wait_stamina_restore)
			agent.aggression_pressure = max(0, agent.aggression_pressure - aggr_decay_on_wait)
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
				agent.aggression_pressure = max(0, agent.aggression_pressure - aggr_on_eat)
				action.succeeded = true
			else:
				var nut: int = resources.take(agent.grid_pos.x, agent.grid_pos.y)
				if nut > 0:
					agent.eat_amount(nut)
					agent.spend_stamina(eat_stamina)
					agent.aggression_pressure = max(0, agent.aggression_pressure - aggr_on_eat)
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
				# すれ違い移動: 空きタイルが見つかるまで同方向に延々スキャン。
				# is_passable が false (= 水タイル) または 盤外に当たったら中断。
				# 岩は is_passable true なので通過可(岩上の move は hunger コスト高だが通行は可)。
				# 他の生存エージェントが連続していてもその先に空きがあれば飛ぶ。
				# 盤面サイズが上限なので最悪でも world.size 回のループ。
				var found_empty: bool = false
				var k: int = 2
				while k <= world.size:
					var step_k := agent.grid_pos + dir * k
					if not _in_bounds(step_k.x, step_k.y):
						action.failure_note = "occupied_blocked"
						return
					if not world.is_passable(step_k.x, step_k.y):
						action.failure_note = "occupied_blocked"
						return
					if not occupied.has(step_k) or occupied[step_k] == agent.id:
						final_pos = step_k
						found_empty = true
						break
					k += 1
				if not found_empty:
					action.failure_note = "occupied_blocked"
					return
				slid = true
			if not agent.can_afford_stamina(move_stamina):
				action.failure_note = "exhausted"
				return
			occupied.erase(agent.grid_pos)
			occupied[final_pos] = agent.id
			agent.grid_pos = final_pos
			# 踏み込んだタイルの種別ごとに hunger コストが異なる。
			var land_t: int = world.get_terrain(final_pos.x, final_pos.y)
			var h_cost: int
			match land_t:
				2: h_cost = forest_move_hunger
				3: h_cost = rock_move_hunger
				_: h_cost = grass_move_hunger
			agent.hunger = max(0, agent.hunger - h_cost)
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
			agent.aggression_pressure = max(0, agent.aggression_pressure - aggr_on_speak)
			_propagate_speech(agent, action)
			action.succeeded = true
		Action.Kind.LOOK:
			_apply_look(agent, action)
		Action.Kind.REPRODUCE_WITH:
			_apply_reproduce_with(agent, action)

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

# 死亡時の inventory ドロップ: 死体タイルと周囲空きタイル(草/森で食料未生成)に食料を残す。
# 他のエージェントが後から take できるので、殺害や餓死が局所的な食料再分配を生む。
func _drop_inventory_on_death(victim: Agent) -> void:
	var drops: int = victim.inventory.size()
	if drops == 0:
		return
	var candidates: Array = []
	# 死亡位置を優先、次に 8 近傍(草/森で既存食料なし・通行可タイル)
	var order: Array = [Vector2i.ZERO]
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			order.append(Vector2i(dx, dy))
	for d: Vector2i in order:
		var nx: int = victim.grid_pos.x + d.x
		var ny: int = victim.grid_pos.y + d.y
		if not _in_bounds(nx, ny):
			continue
		var t: int = world.get_terrain(nx, ny)
		# 草地・森のみ。岩・水には食料を残せない(物理的に根付かない)。
		if t != 0 and t != 2:
			continue
		if resources.has_food(nx, ny):
			continue
		candidates.append(Vector2i(nx, ny))
		if candidates.size() >= drops:
			break
	for i in range(min(drops, candidates.size())):
		resources.food[candidates[i].y][candidates[i].x] = true
	victim.inventory.clear()

func _emit_death(victim: Agent, cause: String, killer: Agent) -> void:
	_drop_inventory_on_death(victim)
	var text: String
	if cause == "attack" and killer != null:
		text = "%s が %s に攻撃されて倒れた" % [victim.agent_name, killer.agent_name]
	elif cause == "starvation":
		text = "%s が餓死した" % victim.agent_name
	elif cause == "old_age":
		text = "%s が老衰で倒れた (age %d)" % [victim.agent_name, victim.age_days]
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
		elif cause == "old_age":
			life_text = "%s が老衰で亡くなるのを見届けた" % victim.agent_name
		else:
			life_text = "%s が倒れるのを見た" % victim.agent_name
		witness.append_life_event(tick, life_text)
		# 死亡目撃は攻撃衝動を跳ね上げる(ショック / 報復心理)
		witness.aggression_pressure = min(100, witness.aggression_pressure + aggr_on_witness_death)

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
	# 利他行動による小さな攻撃衝動の発散(施す側のみ)
	agent.aggression_pressure = max(0, agent.aggression_pressure - aggr_on_give)
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
	# 攻撃衝動: 加害者は発散、被害者は急上昇
	agent.aggression_pressure = max(0, agent.aggression_pressure - aggr_discharge_on_attack)
	target.aggression_pressure = min(100, target.aggression_pressure + aggr_on_attacked)
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
		witness.aggression_pressure = min(100, witness.aggression_pressure + aggr_on_witness_attack)
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
	# 受け手側の攻撃衝動を鎮める(鎮痛作用)
	target.aggression_pressure = max(0, target.aggression_pressure - aggr_on_embrace_received)
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

# look アクション: エージェントが direction の方向に 5 マス奥行き × 幅 3 を覗き見る。
# 結果は scouted_tiles に各タイル分の dict として追記される。
# direction は cardinal 4 方位 (北/東/南/西) のみを想定(斜めは未対応)。
func _apply_look(agent: Agent, action: Action) -> void:
	if not agent.can_afford_stamina(look_stamina):
		action.failure_note = "exhausted"
		return
	var dir: Vector2i = action.direction
	# 斜め指定は 4 方位にスナップ(x or y の優勢側を残す)
	if dir.x != 0 and dir.y != 0:
		if absi(dir.x) >= absi(dir.y):
			dir = Vector2i(sign(dir.x), 0)
		else:
			dir = Vector2i(0, sign(dir.y))
	if dir == Vector2i.ZERO:
		action.failure_note = "no_direction"
		return
	# 幅の「垂直」単位ベクトル(direction に直交)
	var perp := Vector2i(-dir.y, dir.x)
	var living_by_pos: Dictionary = {}
	for a in agents:
		if a.id == agent.id: continue
		living_by_pos[a.grid_pos] = a
	var seen_any: bool = false
	for step in range(1, LOOK_LENGTH + 1):
		for w in range(-LOOK_HALF_WIDTH, LOOK_HALF_WIDTH + 1):
			var tx: int = agent.grid_pos.x + dir.x * step + perp.x * w
			var ty: int = agent.grid_pos.y + dir.y * step + perp.y * w
			if not _in_bounds(tx, ty):
				continue
			var t: int = world.get_terrain(tx, ty)
			var entry: Dictionary = {
				"tick": tick,
				"pos": [tx, ty],
				"terrain": _terrain_name(t),
			}
			if resources.has_food(tx, ty):
				entry["food"] = true
			var occ: Agent = living_by_pos.get(Vector2i(tx, ty), null)
			if occ != null:
				if occ.is_alive():
					entry["agent"] = occ.agent_name
				else:
					entry["corpse"] = occ.agent_name
			agent.append_scouted(entry)
			seen_any = true
	if not seen_any:
		action.failure_note = "out_of_bounds"
		return
	agent.spend_stamina(look_stamina)
	action.succeeded = true

# 生殖は物理アクション。harness は以下の物理制約のみを設ける:
#   - target が生存していること
#   - 自分自身でないこと
#   - 異性(gender が異なる)
#   - 隣接(Chebyshev 距離 1)
#   - stamina コストを払える
# 合意は物理制約ではなく社会通念。harness は強制しない(暴力的生殖も物理的に成立する)。
# 確率 reproduce_success_prob で妊娠、失敗してもコストは消費される。
# 同 tick 内の同一ペアで 2 回目以降は物理的には重複扱いで silent fail(双子防止)。
func _apply_reproduce_with(agent: Agent, action: Action) -> void:
	var target := _get_agent_by_id(action.target_id)
	if target == null or not target.is_alive():
		action.failure_note = "target_invalid"
		return
	if target.id == agent.id:
		action.failure_note = "target_invalid"
		return
	if target.gender == agent.gender:
		action.failure_note = "same_gender"
		return
	if not _is_adjacent(agent, target):
		action.failure_note = "not_adjacent"
		return
	if not agent.can_afford_stamina(reproduce_stamina_cost):
		action.failure_note = "exhausted"
		return
	var pair_key: String = "%d|%d" % [min(agent.id, target.id), max(agent.id, target.id)]
	if reproduce_paired_this_tick.has(pair_key):
		# 同じペアで既に今 tick 成立済み
		action.failure_note = "already_mated_this_tick"
		return
	# コスト消費(成功失敗によらず)
	agent.spend_stamina(reproduce_stamina_cost)
	agent.hunger = max(0, agent.hunger - reproduce_hunger_cost)
	reproduce_paired_this_tick[pair_key] = true
	# 確率判定
	if rng.randf() > reproduce_success_prob:
		action.succeeded = true
		action.failure_note = "infertile"
		# 失敗: initiator の libido のみ小さく減衰(衝動は残る)
		agent.libido = max(0, agent.libido - libido_fail_penalty)
		agent.append_life_event(tick, "%s と交わったが子は宿らなかった" % target.agent_name)
		target.append_life_event(tick, "%s と交わったが子は宿らなかった" % agent.agent_name)
		_emit_event({
			"tick": tick,
			"kind": "reproduce_fail",
			"actor_id": agent.id,
			"target_id": target.id,
			"position": agent.grid_pos,
			"text": "%s と %s が交わったが子は宿らなかった" % [agent.agent_name, target.agent_name],
		})
		return
	# 隣接空きマスを探す(親の周り→相手の周りの順)
	var birth_pos: Vector2i = _find_empty_adjacent(agent.grid_pos)
	if birth_pos.x < 0:
		birth_pos = _find_empty_adjacent(target.grid_pos)
	if birth_pos.x < 0:
		action.succeeded = true
		action.failure_note = "no_space_for_birth"
		# 交合は成立したので両者の libido はリセット
		agent.libido = 0
		target.libido = 0
		agent.append_life_event(tick, "%s と結ばれたが子の居場所が無かった" % target.agent_name)
		target.append_life_event(tick, "%s と結ばれたが子の居場所が無かった" % agent.agent_name)
		return
	var child := _spawn_child(agent, target, birth_pos)
	agents.append(child)
	action.succeeded = true
	# 出産成功: 両親とも libido リセット
	agent.libido = 0
	target.libido = 0
	_emit_event({
		"tick": tick,
		"kind": "birth",
		"actor_id": agent.id,
		"target_id": target.id,
		"position": child.grid_pos,
		"child_id": child.id,
		"text": "%s と %s の間に %s が生まれた" % [agent.agent_name, target.agent_name, child.agent_name],
	})
	agent.append_life_event(tick, "%s との間に %s を授かった" % [target.agent_name, child.agent_name])
	target.append_life_event(tick, "%s との間に %s を授かった" % [agent.agent_name, child.agent_name])

# 親周辺の空き(通行可 + 他者占有なし)タイルを探す。
func _find_empty_adjacent(origin: Vector2i) -> Vector2i:
	var occupied_set: Dictionary = {}
	for a in agents:
		if a.is_alive():
			occupied_set[a.grid_pos] = true
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var nx: int = origin.x + dx
			var ny: int = origin.y + dy
			if not _in_bounds(nx, ny):
				continue
			if not world.is_passable(nx, ny):
				continue
			var p := Vector2i(nx, ny)
			if occupied_set.has(p):
				continue
			return p
	return Vector2i(-1, -1)

# 子エージェント生成。性格は両親平均 ± ノイズ(±10)、性別は 50/50、
# 初期 age_days 0、親の id を parent_ids に。名前は NEWBORN_POOL から。
func _spawn_child(parent_a: Agent, parent_b: Agent, birth_pos: Vector2i) -> Agent:
	var child := Agent.new(_next_child_id())
	var pool_idx: int = (child.id) % NEWBORN_POOL.size()
	# 既出名との衝突は避ける(愚直にチェック、衝突したら "新%d" に逃げる)
	var name_used: Dictionary = {}
	for a in agents:
		name_used[a.agent_name] = true
	var nm: String = NEWBORN_POOL[pool_idx]["name"]
	var rj: String = NEWBORN_POOL[pool_idx]["romaji"]
	if name_used.has(nm):
		nm = "新%d" % child.id
		rj = "Shin%d" % child.id
	child.agent_name = nm
	child.romaji = rj
	child.gender = "female" if rng.randf() < 0.5 else "male"
	child.cooperative = _mix_personality(parent_a.cooperative, parent_b.cooperative)
	child.aggressive = _mix_personality(parent_a.aggressive, parent_b.aggressive)
	child.curious = _mix_personality(parent_a.curious, parent_b.curious)
	child.grid_pos = birth_pos
	child.age_days = 0
	child.hunger = Agent.HUNGER_INITIAL
	child.health = Agent.HEALTH_INITIAL
	child.stamina = Agent.STAMINA_INITIAL
	child.inventory_capacity = parent_a.inventory_capacity
	child.parent_ids = [parent_a.id, parent_b.id]
	return child

func _mix_personality(a: int, b: int) -> int:
	var avg: int = (a + b) / 2
	var noise: int = int(round(rng.randf_range(-10.0, 10.0)))
	return clampi(avg + noise, 0, 100)

func _next_child_id() -> int:
	var max_id: int = -1
	for a in agents:
		if a.id > max_id:
			max_id = a.id
	return max_id + 1

func _terrain_name(t: int) -> String:
	match t:
		1: return "water"
		2: return "forest"
		3: return "rock"
		_: return "grass"

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
		Action.Kind.LOOK:
			var ldir := ""
			match action.direction:
				Vector2i(0, -1): ldir = "↑"
				Vector2i(0, 1):  ldir = "↓"
				Vector2i(1, 0):  ldir = "→"
				Vector2i(-1, 0): ldir = "←"
				_: ldir = "?"
			base = "look " + ldir
		Action.Kind.REPRODUCE_WITH:
			base = "reproduce_with"
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
