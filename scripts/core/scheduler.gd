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

var world: World
var resources: ResourceField
var agents: Array
var rng: RandomNumberGenerator

var tick: int = 0
var day: int = 0
var tick_per_day: int = 10
var phase: int = Phase.IDLE

func _init(world_: World, resources_: ResourceField, agents_: Array, seed_: int, tick_per_day_: int = 10) -> void:
	world = world_
	resources = resources_
	agents = agents_
	tick_per_day = tick_per_day_
	rng = RandomNumberGenerator.new()
	rng.seed = seed_ ^ 0x2468ACE0

func step() -> void:
	_observe()
	var decisions := _decide()
	_commit(decisions)
	_post_commit_tick()

# --- phases ---

func _observe() -> void:
	phase = Phase.OBSERVE
	phase_changed.emit("Observe")
	# v0.1 Phase 2 ではエージェントの記憶/ローリングログはまだ Phase 3 のため、
	# 観測フェーズ自体は空(世界状態を参照する順序だけ保つ)。

func _decide() -> Array:
	phase = Phase.DECIDE
	phase_changed.emit("Decide")
	var decisions: Array = []
	for agent in agents:
		if not agent.is_alive():
			decisions.append(Action.wait())
			continue
		decisions.append(_decide_local(agent))
	return decisions

func _commit(decisions: Array) -> void:
	phase = Phase.COMMIT
	phase_changed.emit("Commit")
	# 衝突解決: agent_id 順で順次適用。同タイル食料は先取り優先、
	# 同タイル移動は先着勝ち、後者は wait 扱い。
	var occupied: Dictionary = {}
	for a in agents:
		occupied[a.grid_pos] = a.id
	var sorted_idx: Array = range(agents.size())
	sorted_idx.sort_custom(func(a, b): return agents[a].id < agents[b].id)
	for idx in sorted_idx:
		var agent: Agent = agents[idx]
		var action: Action = decisions[idx]
		if not agent.is_alive():
			continue
		_apply_action(agent, action, occupied)
		agent.apply_tick_decay()

func _post_commit_tick() -> void:
	resources.tick_regen()
	tick += 1
	if tick_per_day > 0 and tick % tick_per_day == 0:
		day += 1
	phase = Phase.IDLE
	phase_changed.emit("Idle")
	tick_completed.emit(tick)

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
			occupied.erase(agent.grid_pos)
			occupied[target] = agent.id
			agent.grid_pos = target

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < world.size and y < world.size
