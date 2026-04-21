class_name World
extends RefCounted

enum Terrain { GRASS, WATER, FOREST, ROCK }

var size: int = 20
var world_seed: int = 0
var terrain: Array = []

func _init(size_: int = 20, seed_: int = 0) -> void:
	size = size_
	world_seed = seed_
	_generate()

func _generate() -> void:
	var noise_water := FastNoiseLite.new()
	noise_water.seed = world_seed
	noise_water.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_water.frequency = 0.11

	var noise_forest := FastNoiseLite.new()
	noise_forest.seed = world_seed ^ 0x9E3779B1
	noise_forest.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_forest.frequency = 0.14

	var noise_rock := FastNoiseLite.new()
	noise_rock.seed = world_seed ^ 0x5F3759DF
	noise_rock.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_rock.frequency = 0.09

	terrain = []
	var center := Vector2(size / 2.0, size / 2.0)
	var max_dist := center.length()
	for y in size:
		var row: Array = []
		for x in size:
			var pos := Vector2(x, y)
			var corner_bias := pos.distance_to(center) / max_dist
			var w := noise_water.get_noise_2d(x, y)
			var f := noise_forest.get_noise_2d(x, y)
			var r := noise_rock.get_noise_2d(x, y)
			var t: int
			if w > 0.30:
				t = Terrain.WATER
			elif corner_bias > 0.78 and r > -0.05:
				t = Terrain.ROCK
			elif f > 0.15:
				t = Terrain.FOREST
			else:
				t = Terrain.GRASS
			row.append(t)
		terrain.append(row)

func get_terrain(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= size or y >= size:
		return Terrain.GRASS
	return terrain[y][x]

func is_passable(x: int, y: int) -> bool:
	var t := get_terrain(x, y)
	return t != Terrain.WATER
