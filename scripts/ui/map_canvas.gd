class_name MapCanvas
extends Control

# エディタ用 20×20 タイルペイント。マウス左でペイント / ドラッグで連続塗り。
# ペイント対象の terrain は {0: grass, 1: water, 2: forest, 3: rock}。
# 保存時はこの配列を row-major(terrain[y][x] = int)でシリアライズする。

signal tile_painted(x: int, y: int)

# キャンバスの描画エリアは常に 400x400px 固定。グリッドサイズに応じて
# タイルサイズを動的計算する(3x3 なら 133px/tile、20x20 なら 20px/tile)。
const CANVAS_PX: int = 400

var grid_size: int = 20
var terrain: Array = []
var selected_terrain: int = 0
var _is_painting: bool = false
var _enabled: bool = true

func _tile_px() -> float:
	return float(CANVAS_PX) / float(max(1, grid_size))

const COLOR_GRASS  := Color(0.37, 0.56, 0.33, 1.0)
const COLOR_WATER  := Color(0.28, 0.46, 0.72, 1.0)
const COLOR_FOREST := Color(0.18, 0.38, 0.22, 1.0)
const COLOR_ROCK   := Color(0.54, 0.51, 0.47, 1.0)
const COLOR_GRID   := Color(0.08, 0.10, 0.13, 0.55)

func _ready() -> void:
	custom_minimum_size = Vector2(CANVAS_PX, CANVAS_PX)
	if terrain.is_empty():
		fill_all(0)

func set_enabled(v: bool) -> void:
	_enabled = v

func set_brush(t: int) -> void:
	selected_terrain = clampi(t, 0, 3)

# 外部から現在の terrain を注入。row-major(terrain[y][x])の N×N 配列。
# 寸法は grid_size を自動的に追従させる(3..20 を許容)。
func set_terrain(t: Array) -> void:
	var n: int = t.size()
	if n < 3 or n > 20:
		return
	for row in t:
		if not (row is Array) or row.size() != n:
			return
	grid_size = n
	terrain = t
	queue_redraw()

func get_terrain() -> Array:
	return terrain

# グリッドサイズを切り替える。既存 terrain 値をできるだけ保持、不足分は草で埋める。
func set_grid_size(n: int) -> void:
	n = clampi(n, 3, 20)
	if n == grid_size and not terrain.is_empty():
		return
	var new_t: Array = []
	for y in n:
		var row: Array = []
		for x in n:
			var v: int = 0
			if y < terrain.size() and x < terrain[y].size():
				v = int(terrain[y][x])
			row.append(v)
		new_t.append(row)
	grid_size = n
	terrain = new_t
	queue_redraw()

func fill_all(v: int) -> void:
	terrain = []
	for _y in grid_size:
		var row: Array = []
		for _x in grid_size:
			row.append(v)
		terrain.append(row)
	queue_redraw()

func _draw() -> void:
	var tp: float = _tile_px()
	for y in grid_size:
		for x in grid_size:
			var t: int = int(terrain[y][x])
			draw_rect(Rect2(x * tp, y * tp, tp, tp), _color_for(t), true)
	for i in range(grid_size + 1):
		draw_line(Vector2(i * tp, 0), Vector2(i * tp, grid_size * tp), COLOR_GRID, 1.0)
		draw_line(Vector2(0, i * tp), Vector2(grid_size * tp, i * tp), COLOR_GRID, 1.0)
	# 外枠
	draw_rect(Rect2(0, 0, grid_size * tp, grid_size * tp), Color(0.23, 0.25, 0.30, 1.0), false, 1.5)

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
	var tp: float = _tile_px()
	var x: int = int(local.x / tp)
	var y: int = int(local.y / tp)
	if x < 0 or y < 0 or x >= grid_size or y >= grid_size:
		return
	if int(terrain[y][x]) != selected_terrain:
		terrain[y][x] = selected_terrain
		tile_painted.emit(x, y)
		queue_redraw()
