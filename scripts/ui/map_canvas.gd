class_name MapCanvas
extends Control

# エディタ用 20×20 タイルペイント。マウス左でペイント / ドラッグで連続塗り。
# ペイント対象の terrain は {0: grass, 1: water, 2: forest, 3: rock}。
# 保存時はこの配列を row-major(terrain[y][x] = int)でシリアライズする。

signal tile_painted(x: int, y: int)

const TILE_PX: int = 20
const GRID_SIZE: int = 20

var terrain: Array = []
var selected_terrain: int = 0
var _is_painting: bool = false
var _enabled: bool = true

const COLOR_GRASS  := Color(0.37, 0.56, 0.33, 1.0)
const COLOR_WATER  := Color(0.28, 0.46, 0.72, 1.0)
const COLOR_FOREST := Color(0.18, 0.38, 0.22, 1.0)
const COLOR_ROCK   := Color(0.54, 0.51, 0.47, 1.0)
const COLOR_GRID   := Color(0.08, 0.10, 0.13, 0.55)

func _ready() -> void:
	custom_minimum_size = Vector2(TILE_PX * GRID_SIZE, TILE_PX * GRID_SIZE)
	if terrain.is_empty():
		fill_all(0)

func set_enabled(v: bool) -> void:
	_enabled = v

func set_brush(t: int) -> void:
	selected_terrain = clampi(t, 0, 3)

# 外部から現在の terrain を注入。row-major(terrain[y][x])の 20×20 配列。
func set_terrain(t: Array) -> void:
	if t.size() != GRID_SIZE:
		return
	for row in t:
		if not (row is Array) or row.size() != GRID_SIZE:
			return
	terrain = t
	queue_redraw()

func get_terrain() -> Array:
	return terrain

func fill_all(v: int) -> void:
	terrain = []
	for _y in GRID_SIZE:
		var row: Array = []
		for _x in GRID_SIZE:
			row.append(v)
		terrain.append(row)
	queue_redraw()

func _draw() -> void:
	for y in GRID_SIZE:
		for x in GRID_SIZE:
			var t: int = int(terrain[y][x])
			draw_rect(Rect2(x * TILE_PX, y * TILE_PX, TILE_PX, TILE_PX), _color_for(t), true)
	for i in range(GRID_SIZE + 1):
		draw_line(Vector2(i * TILE_PX, 0), Vector2(i * TILE_PX, GRID_SIZE * TILE_PX), COLOR_GRID, 1.0)
		draw_line(Vector2(0, i * TILE_PX), Vector2(GRID_SIZE * TILE_PX, i * TILE_PX), COLOR_GRID, 1.0)
	# 外枠
	draw_rect(Rect2(0, 0, GRID_SIZE * TILE_PX, GRID_SIZE * TILE_PX), Color(0.23, 0.25, 0.30, 1.0), false, 1.5)

func _color_for(t: int) -> Color:
	match t:
		1: return COLOR_WATER
		2: return COLOR_FOREST
		3: return COLOR_ROCK
		_: return COLOR_GRASS

func _gui_input(event: InputEvent) -> void:
	if not _enabled:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_painting = event.pressed
			if event.pressed:
				_paint_at(event.position)
	elif event is InputEventMouseMotion and _is_painting:
		_paint_at(event.position)

func _paint_at(local: Vector2) -> void:
	var x: int = int(local.x / TILE_PX)
	var y: int = int(local.y / TILE_PX)
	if x < 0 or y < 0 or x >= GRID_SIZE or y >= GRID_SIZE:
		return
	if int(terrain[y][x]) != selected_terrain:
		terrain[y][x] = selected_terrain
		tile_painted.emit(x, y)
		queue_redraw()
