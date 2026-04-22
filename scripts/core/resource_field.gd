class_name ResourceField
extends RefCounted

# 食料グリッド。v0.1 では「果実/獲物」を区別せず単一のスカラーとして扱う。
# 各タイルは has_food(x,y) で 1/0 を持つ。再生は確率的。スポーン/再生率は config.json で可変。

var size: int = 20
var world: World
var food: Array = []  # 2D bool array [y][x]
var rng: RandomNumberGenerator

var spawn_rate_by_terrain: Dictionary = {0: 0.06, 1: 0.0, 2: 0.12, 3: 0.0}
var regen_rate_by_terrain: Dictionary = {0: 0.003, 1: 0.0, 2: 0.008, 3: 0.0}
var food_nutrition: int = 25

func _init(world_: World, seed_: int, cfg: Dictionary = {}) -> void:
	world = world_
	size = world.size
	rng = RandomNumberGenerator.new()
	rng.seed = seed_ ^ 0x13579BDF
	_configure(cfg)
	_initial_spawn()

func _configure(cfg: Dictionary) -> void:
	var initial: Dictionary = cfg.get("initial_spawn", {})
	spawn_rate_by_terrain[0] = float(initial.get("grass", spawn_rate_by_terrain[0]))
	spawn_rate_by_terrain[2] = float(initial.get("forest", spawn_rate_by_terrain[2]))
	var regen: Dictionary = cfg.get("regen_per_tick", {})
	regen_rate_by_terrain[0] = float(regen.get("grass", regen_rate_by_terrain[0]))
	regen_rate_by_terrain[2] = float(regen.get("forest", regen_rate_by_terrain[2]))
	food_nutrition = int(cfg.get("food_nutrition", food_nutrition))

func _initial_spawn() -> void:
	food = []
	for y in size:
		var row: Array = []
		for x in size:
			var t: int = world.get_terrain(x, y)
			var p: float = spawn_rate_by_terrain.get(t, 0.0)
			row.append(rng.randf() < p)
		food.append(row)

func has_food(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= size or y >= size:
		return false
	return food[y][x]

func take(x: int, y: int) -> int:
	if not has_food(x, y):
		return 0
	food[y][x] = false
	return food_nutrition

func tick_regen() -> void:
	for y in size:
		for x in size:
			if food[y][x]:
				continue
			var t: int = world.get_terrain(x, y)
			var p: float = regen_rate_by_terrain.get(t, 0.0)
			if p > 0.0 and rng.randf() < p:
				food[y][x] = true
