class_name ResourceField
extends RefCounted

# 食料グリッド。v0.1 では「果実/獲物」を区別せず単一のスカラーとして扱う。
# 各タイルは has_food(x,y) で 1/0 を持つ。再生は確率的。

const SPAWN_RATE_BY_TERRAIN := {
	0: 0.12,  # GRASS
	1: 0.00,  # WATER
	2: 0.20,  # FOREST
	3: 0.00,  # ROCK
}

const REGEN_RATE_BY_TERRAIN := {
	0: 0.008,  # GRASS: ~1/125 tick per empty tile
	1: 0.0,
	2: 0.015,  # FOREST: ~1.5×
	3: 0.0,
}

const FOOD_NUTRITION: int = 25

var size: int = 20
var world: World
var food: Array = []  # 2D bool array [y][x]
var rng: RandomNumberGenerator

func _init(world_: World, seed_: int) -> void:
	world = world_
	size = world.size
	rng = RandomNumberGenerator.new()
	rng.seed = seed_ ^ 0x13579BDF
	_initial_spawn()

func _initial_spawn() -> void:
	food = []
	for y in size:
		var row: Array = []
		for x in size:
			var t: int = world.get_terrain(x, y)
			var p: float = SPAWN_RATE_BY_TERRAIN.get(t, 0.0)
			row.append(rng.randf() < p)
		food.append(row)

func has_food(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= size or y >= size:
		return false
	return food[y][x]

func take(x: int, y: int) -> int:
	# 返り値: 吸収した栄養量(0 なら食料なし)
	if not has_food(x, y):
		return 0
	food[y][x] = false
	return FOOD_NUTRITION

func tick_regen() -> void:
	for y in size:
		for x in size:
			if food[y][x]:
				continue
			var t: int = world.get_terrain(x, y)
			var p: float = REGEN_RATE_BY_TERRAIN.get(t, 0.0)
			if p > 0.0 and rng.randf() < p:
				food[y][x] = true
