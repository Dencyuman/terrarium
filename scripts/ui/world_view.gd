class_name WorldView
extends Node2D

const TILE_SIZE: int = 32
const BADGE_RADIUS: int = 13
const BADGE_FONT_SIZE: int = 16
const MINIMAP_SCALE: float = 0.22   # 20*32 * 0.22 = 140.8 → ミニマップ 141px 程度
const MINIMAP_MARGIN: int = 8

var world: World
var agents: Array = []
var badge_font: SystemFont

# ダーク chrome 上で世界が発光して見えるよう、自然色は維持しつつ彩度をやや調整。
const TERRAIN_COLORS := {
	0: Color(0.46, 0.64, 0.35),  # GRASS
	1: Color(0.28, 0.52, 0.70),  # WATER
	2: Color(0.22, 0.42, 0.28),  # FOREST
	3: Color(0.55, 0.53, 0.50),  # ROCK
}

const TERRAIN_COLORS_DIM := {
	0: Color(0.30, 0.43, 0.24),
	1: Color(0.19, 0.36, 0.48),
	2: Color(0.14, 0.28, 0.19),
	3: Color(0.36, 0.35, 0.33),
}

func _ready() -> void:
	badge_font = SystemFont.new()
	badge_font.font_names = PackedStringArray([
		"Hiragino Kaku Gothic Pro",
		"Hiragino Sans",
		"Noto Sans CJK JP",
		"Yu Gothic",
		"Meiryo",
	])
	badge_font.font_weight = 700

func set_world_and_agents(w: World, a: Array) -> void:
	world = w
	agents = a
	queue_redraw()

func _draw() -> void:
	if world == null:
		return
	_draw_tiles()
	_draw_grid()
	_draw_world_frame()
	_draw_agents()
	_draw_minimap()

func _draw_tiles() -> void:
	for y in world.size:
		for x in world.size:
			var t: int = world.get_terrain(x, y)
			var rect := Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
			draw_rect(rect, TERRAIN_COLORS[t], true)

func _draw_grid() -> void:
	var line_color := Color(0, 0, 0, 0.08)
	var extent: int = world.size * TILE_SIZE
	for i in world.size + 1:
		draw_line(Vector2(i * TILE_SIZE, 0), Vector2(i * TILE_SIZE, extent), line_color, 1.0)
		draw_line(Vector2(0, i * TILE_SIZE), Vector2(extent, i * TILE_SIZE), line_color, 1.0)

func _draw_world_frame() -> void:
	var extent: int = world.size * TILE_SIZE
	# ダーク bg 上で世界を持ち上げる外枠(薄いティール系ライン)
	draw_rect(Rect2(-2, -2, extent + 4, extent + 4), Color(0.42, 0.81, 0.69, 0.35), false, 2.0)

func _draw_agents() -> void:
	for agent in agents:
		var center := Vector2(
			agent.grid_pos.x * TILE_SIZE + TILE_SIZE / 2.0,
			agent.grid_pos.y * TILE_SIZE + TILE_SIZE / 2.0
		)
		var color: Color = agent.badge_color()
		draw_circle(center + Vector2(0, 2), BADGE_RADIUS, Color(0, 0, 0, 0.40))
		draw_circle(center, BADGE_RADIUS, color)
		draw_arc(center, BADGE_RADIUS, 0, TAU, 48, Color(0.10, 0.12, 0.16, 0.9), 2.0)
		draw_arc(center, BADGE_RADIUS - 1, 0, TAU, 48, Color(1, 1, 1, 0.75), 1.0)
		_draw_badge_label(agent.agent_name, center)

func _draw_badge_label(text: String, center: Vector2) -> void:
	var text_size: Vector2 = badge_font.get_string_size(
		text,
		HORIZONTAL_ALIGNMENT_CENTER,
		-1,
		BADGE_FONT_SIZE
	)
	var ascent: float = badge_font.get_ascent(BADGE_FONT_SIZE)
	var descent: float = badge_font.get_descent(BADGE_FONT_SIZE)
	var baseline := Vector2(
		center.x - text_size.x / 2.0,
		center.y + (ascent - descent) / 2.0
	)
	draw_string(
		badge_font,
		baseline,
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		BADGE_FONT_SIZE,
		Color(1, 1, 1, 0.98)
	)

func _draw_minimap() -> void:
	var extent: int = world.size * TILE_SIZE
	var mm_size: float = extent * MINIMAP_SCALE
	var mm_origin := Vector2(extent - mm_size - MINIMAP_MARGIN, MINIMAP_MARGIN)
	# 背景
	draw_rect(Rect2(mm_origin - Vector2(4, 4), Vector2(mm_size + 8, mm_size + 8)),
		Color(0.10, 0.12, 0.16, 0.85), true)
	draw_rect(Rect2(mm_origin - Vector2(4, 4), Vector2(mm_size + 8, mm_size + 8)),
		Color(0.42, 0.81, 0.69, 0.5), false, 1.0)
	# タイル(シンプル化: 1 セルあたり 1 矩形)
	var cell := mm_size / float(world.size)
	for y in world.size:
		for x in world.size:
			var t: int = world.get_terrain(x, y)
			var r := Rect2(
				mm_origin + Vector2(x * cell, y * cell),
				Vector2(cell + 0.5, cell + 0.5)
			)
			draw_rect(r, TERRAIN_COLORS_DIM[t], true)
	# エージェントドット
	for agent in agents:
		var p := mm_origin + Vector2(
			(agent.grid_pos.x + 0.5) * cell,
			(agent.grid_pos.y + 0.5) * cell
		)
		draw_circle(p, max(1.2, cell * 0.35), agent.badge_color())
	# 現在ビューポート枠(v0.1 では常にワールド全体なので枠いっぱい)
	draw_rect(Rect2(mm_origin, Vector2(mm_size, mm_size)),
		Color(0.98, 0.82, 0.28, 0.8), false, 1.5)
