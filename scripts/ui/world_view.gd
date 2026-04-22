class_name WorldView
extends Node2D

signal agent_clicked(agent_id: int)
signal zoom_requested(rect_local: Rect2)

const TILE_SIZE: int = 32
const BADGE_RADIUS: int = 13
const BADGE_FONT_SIZE: int = 16
const MINIMAP_SCALE: float = 0.22
const MINIMAP_MARGIN: int = 8
const SPEECH_FADE_TICKS: int = 3
const SPEECH_MAX_CHARS: int = 10
const SPEECH_BUBBLE_FONT_SIZE: int = 9
const VISION_RADIUS: int = 3
const DRAG_THRESHOLD: float = 5.0
const SLOT_DOT_RADIUS: float = 2.0
const SLOT_DOT_SPACING: float = 5.0

var world: World
var agents: Array = []
var resources: ResourceField
var badge_font: SystemFont
var speech_font: SystemFont
var current_tick: int = 0
var selected_agent_id: int = -1
var bubbles_visible: bool = true
var arrows_visible: bool = true

var _drag_start: Vector2 = Vector2.ZERO
var _drag_current: Vector2 = Vector2.ZERO
var _is_pressing: bool = false

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
	speech_font = SystemFont.new()
	speech_font.font_names = PackedStringArray([
		"Hiragino Kaku Gothic Pro",
		"Hiragino Sans",
		"Noto Sans CJK JP",
		"Yu Gothic",
		"Meiryo",
	])
	speech_font.font_weight = 500

func _unhandled_input(event: InputEvent) -> void:
	if world == null or not visible:
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)

func _handle_mouse_button(mb: InputEventMouseButton) -> void:
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var local := to_local(mb.global_position)
	var extent: int = world.size * TILE_SIZE
	if mb.pressed:
		# 開始点がワールド外なら無視
		if local.x < 0 or local.y < 0 or local.x >= extent or local.y >= extent:
			return
		_drag_start = local
		_drag_current = local
		_is_pressing = true
		return
	# 離したとき
	if not _is_pressing:
		return
	_is_pressing = false
	var dist: float = (local - _drag_start).length()
	if dist < DRAG_THRESHOLD:
		# クリック扱い(エージェント選択)
		var cell := Vector2i(int(_drag_start.x / TILE_SIZE), int(_drag_start.y / TILE_SIZE))
		for agent in agents:
			if agent.grid_pos == cell:
				agent_clicked.emit(agent.id)
				get_viewport().set_input_as_handled()
				break
		queue_redraw()
		return
	# ドラッグ扱い(エリアズーム)
	var rect := Rect2(_drag_start, Vector2.ZERO).expand(local)
	# ワールド範囲にクランプ
	var extent_f := float(extent)
	rect.position.x = clamp(rect.position.x, 0.0, extent_f)
	rect.position.y = clamp(rect.position.y, 0.0, extent_f)
	var br: Vector2 = rect.end
	br.x = clamp(br.x, 0.0, extent_f)
	br.y = clamp(br.y, 0.0, extent_f)
	rect = Rect2(rect.position, br - rect.position)
	if rect.size.x < 1 or rect.size.y < 1:
		queue_redraw()
		return
	zoom_requested.emit(rect)
	get_viewport().set_input_as_handled()
	queue_redraw()

func _handle_mouse_motion(mm: InputEventMouseMotion) -> void:
	if not _is_pressing:
		return
	_drag_current = to_local(mm.global_position)
	queue_redraw()

func set_bubbles_visible(v: bool) -> void:
	bubbles_visible = v
	queue_redraw()

func set_arrows_visible(v: bool) -> void:
	arrows_visible = v
	queue_redraw()

func set_world_and_agents(w: World, a: Array) -> void:
	world = w
	agents = a
	queue_redraw()

func set_resources(r: ResourceField) -> void:
	resources = r
	queue_redraw()

func set_current_tick(t: int) -> void:
	if t != current_tick:
		current_tick = t
		queue_redraw()

func set_selected_agent(id: int) -> void:
	if id != selected_agent_id:
		selected_agent_id = id
		queue_redraw()

func _draw() -> void:
	if world == null:
		return
	_draw_tiles()
	_draw_vision_highlight()
	_draw_grid()
	_draw_food()
	_draw_world_frame()
	_draw_agents()
	_draw_speech_bubbles()
	_draw_selection_preview()

func _draw_selection_preview() -> void:
	if not _is_pressing:
		return
	var dist: float = (_drag_current - _drag_start).length()
	if dist < DRAG_THRESHOLD:
		return
	var extent: int = world.size * TILE_SIZE
	var p1 := Vector2(clamp(_drag_start.x, 0, extent), clamp(_drag_start.y, 0, extent))
	var p2 := Vector2(clamp(_drag_current.x, 0, extent), clamp(_drag_current.y, 0, extent))
	var rect := Rect2(p1, Vector2.ZERO).expand(p2)
	draw_rect(rect, Color(0.42, 0.81, 0.69, 0.15), true)
	draw_rect(rect, Color(0.42, 0.81, 0.69, 0.75), false, 1.5)

func _draw_food() -> void:
	if resources == null:
		return
	var color := Color(0.88, 0.30, 0.26, 1)
	var shadow := Color(0, 0, 0, 0.35)
	for y in world.size:
		for x in world.size:
			if not resources.has_food(x, y):
				continue
			var center := Vector2(
				x * TILE_SIZE + TILE_SIZE / 2.0,
				y * TILE_SIZE + TILE_SIZE / 2.0
			)
			draw_circle(center + Vector2(0.5, 1.5), 3.5, shadow)
			draw_circle(center, 3.5, color)
			draw_arc(center, 3.5, 0, TAU, 16, Color(1, 1, 1, 0.5), 0.8)

func _draw_tiles() -> void:
	for y in world.size:
		for x in world.size:
			var t: int = world.get_terrain(x, y)
			var rect := Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
			draw_rect(rect, TERRAIN_COLORS[t], true)

func _draw_vision_highlight() -> void:
	if selected_agent_id < 0:
		return
	var agent := _get_agent_by_id(selected_agent_id)
	if agent == null:
		return
	var center_x := agent.grid_pos.x
	var center_y := agent.grid_pos.y
	var fill := Color(0.42, 0.81, 0.69, 0.12)
	var edge := Color(0.42, 0.81, 0.69, 0.45)
	# 半径 r 内の各マスを半透明で塗る
	for dy in range(-VISION_RADIUS, VISION_RADIUS + 1):
		for dx in range(-VISION_RADIUS, VISION_RADIUS + 1):
			var x: int = center_x + dx
			var y: int = center_y + dy
			if x < 0 or y < 0 or x >= world.size or y >= world.size:
				continue
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), fill, true)
	# 外周を囲む矩形ライン(クリップしない)
	var min_x: int = max(0, center_x - VISION_RADIUS)
	var min_y: int = max(0, center_y - VISION_RADIUS)
	var max_x: int = min(world.size - 1, center_x + VISION_RADIUS)
	var max_y: int = min(world.size - 1, center_y + VISION_RADIUS)
	var rect := Rect2(
		min_x * TILE_SIZE,
		min_y * TILE_SIZE,
		(max_x - min_x + 1) * TILE_SIZE,
		(max_y - min_y + 1) * TILE_SIZE
	)
	draw_rect(rect, edge, false, 1.5)

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
		_draw_inventory_dots(agent, center)

func _draw_inventory_dots(agent: Agent, badge_center: Vector2) -> void:
	var cap: int = agent.inventory_capacity
	if cap <= 0:
		return
	var used: int = agent.inventory.size()
	var total_w: float = SLOT_DOT_SPACING * float(cap - 1)
	var start_x: float = badge_center.x - total_w / 2.0
	var y: float = badge_center.y + BADGE_RADIUS + 4.5
	for i in cap:
		var pos := Vector2(start_x + SLOT_DOT_SPACING * float(i), y)
		if i < used:
			draw_circle(pos, SLOT_DOT_RADIUS, Color(0.88, 0.72, 0.30, 0.95))   # 埋まってる = アンバー(食料)
			draw_arc(pos, SLOT_DOT_RADIUS, 0, TAU, 16, Color(0.10, 0.12, 0.16, 0.9), 0.6)
		else:
			draw_circle(pos, SLOT_DOT_RADIUS - 0.5, Color(0.30, 0.32, 0.36, 0.7))   # 空 = 暗灰
			draw_arc(pos, SLOT_DOT_RADIUS - 0.5, 0, TAU, 16, Color(0.50, 0.52, 0.56, 0.5), 0.6)

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

func _draw_speech_bubbles() -> void:
	if agents.is_empty():
		return
	var non_selected: Array = []
	var selected_target: Agent = null
	for agent in agents:
		if agent.last_speech.is_empty():
			continue
		if agent.last_speech_tick < 0:
			continue
		var age: int = current_tick - agent.last_speech_tick
		if age > SPEECH_FADE_TICKS:
			continue
		if agent.id == selected_agent_id:
			selected_target = agent
		else:
			non_selected.append(agent)
	# 1. 矢印(非選択)
	if arrows_visible:
		for agent in non_selected:
			_draw_speech_arrow(agent, false)
	# 2. バブル(非選択)
	if bubbles_visible:
		for agent in non_selected:
			_draw_speech_bubble(agent, false)
	# 3. 選択中の矢印+バブル(最前面)
	if selected_target != null:
		if arrows_visible:
			_draw_speech_arrow(selected_target, true)
		if bubbles_visible:
			_draw_speech_bubble(selected_target, true)

func _get_agent_by_id(id: int) -> Agent:
	for a in agents:
		if a.id == id:
			return a
	return null

func _draw_speech_arrow(speaker: Agent, is_selected: bool) -> void:
	if speaker.last_speech_target_ids.is_empty():
		return
	for tid in speaker.last_speech_target_ids:
		var target := _get_agent_by_id(tid)
		if target == null or not target.is_alive():
			continue
		_draw_arrow_to(speaker, target, is_selected)

func _draw_arrow_to(speaker: Agent, target: Agent, is_selected: bool) -> void:
	var age: int = max(0, current_tick - speaker.last_speech_tick)
	var fade_t: float = 1.0 - float(age) / float(SPEECH_FADE_TICKS + 1)
	fade_t = clamp(fade_t, 0.15, 1.0)
	var alpha: float = (1.0 if is_selected else 0.75) * fade_t
	var color: Color = speaker.badge_color()
	color.a = alpha
	var from := Vector2(
		speaker.grid_pos.x * TILE_SIZE + TILE_SIZE / 2.0,
		speaker.grid_pos.y * TILE_SIZE + TILE_SIZE / 2.0
	)
	var to := Vector2(
		target.grid_pos.x * TILE_SIZE + TILE_SIZE / 2.0,
		target.grid_pos.y * TILE_SIZE + TILE_SIZE / 2.0
	)
	var dir := (to - from).normalized()
	if dir.length_squared() < 0.0001:
		return
	var start := from + dir * BADGE_RADIUS
	var end := to - dir * (BADGE_RADIUS + 3)
	var width: float = 2.5 if is_selected else 1.8
	draw_line(start, end, color, width)
	var head_len: float = 9.0 if is_selected else 7.0
	var left := end - dir.rotated(0.4) * head_len
	var right := end - dir.rotated(-0.4) * head_len
	var pts := PackedVector2Array([end, left, right])
	draw_polygon(pts, PackedColorArray([color, color, color]))

func _draw_speech_bubble(agent: Agent, is_selected: bool) -> void:
	var age: int = max(0, current_tick - agent.last_speech_tick)
	var fade_t: float = 1.0 - float(age) / float(SPEECH_FADE_TICKS + 1)
	fade_t = clamp(fade_t, 0.2, 1.0)
	var base_alpha: float = (1.0 if is_selected else 0.85) * fade_t
	var text: String = agent.last_speech
	var font_size: int = SPEECH_BUBBLE_FONT_SIZE + (2 if is_selected else 0)
	var pad_x: float = 6.0
	var pad_y: float = 3.0
	var bubble_w: float = 0.0
	var bubble_h: float = 0.0
	var is_multiline: bool = false
	# 選択中は全文 + 適宜改行。非選択は SPEECH_MAX_CHARS で 1 行カット。
	if is_selected:
		var max_text_w: float = 200.0
		var mts: Vector2 = speech_font.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, max_text_w, font_size
		)
		is_multiline = mts.x > 0 and mts.y > speech_font.get_height(font_size) * 1.2
		bubble_w = mts.x + pad_x * 2
		bubble_h = mts.y + pad_y * 2
	else:
		if text.length() > SPEECH_MAX_CHARS:
			text = text.substr(0, SPEECH_MAX_CHARS) + "…"
		var ts: Vector2 = speech_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		bubble_w = ts.x + pad_x * 2
		bubble_h = ts.y + pad_y * 2
	var badge_center := Vector2(
		agent.grid_pos.x * TILE_SIZE + TILE_SIZE / 2.0,
		agent.grid_pos.y * TILE_SIZE + TILE_SIZE / 2.0
	)
	var bubble_center := badge_center + Vector2(0, -(BADGE_RADIUS + 4 + bubble_h / 2))
	var rect := Rect2(bubble_center.x - bubble_w / 2, bubble_center.y - bubble_h / 2, bubble_w, bubble_h)
	# Shadow
	draw_rect(Rect2(rect.position + Vector2(1, 1), rect.size), Color(0, 0, 0, 0.30 * base_alpha), true)
	# Body
	var bg := Color(0.96, 0.94, 0.88, base_alpha) if is_selected else Color(0.90, 0.88, 0.82, base_alpha * 0.95)
	draw_rect(rect, bg, true)
	var border := Color(0.30, 0.28, 0.24, base_alpha) if is_selected else Color(0.40, 0.38, 0.34, base_alpha * 0.75)
	draw_rect(rect, border, false, 1.2 if is_selected else 0.8)
	# Tail
	var tail_cx: float = bubble_center.x
	var tail_top: float = rect.position.y + rect.size.y
	var tail_pts := PackedVector2Array([
		Vector2(tail_cx - 3, tail_top),
		Vector2(tail_cx + 3, tail_top),
		Vector2(tail_cx, tail_top + 5),
	])
	draw_polygon(tail_pts, PackedColorArray([bg, bg, bg]))
	draw_polyline(PackedVector2Array([
		Vector2(tail_cx - 3, tail_top),
		Vector2(tail_cx, tail_top + 5),
		Vector2(tail_cx + 3, tail_top),
	]), border, 0.8)
	# Text
	var text_color := Color(0.15, 0.14, 0.12, base_alpha)
	if is_selected:
		var inner_w: float = rect.size.x - pad_x * 2
		var text_pos := Vector2(rect.position.x + pad_x, rect.position.y + pad_y + speech_font.get_ascent(font_size))
		draw_multiline_string(
			speech_font, text_pos, text,
			HORIZONTAL_ALIGNMENT_LEFT, inner_w, font_size, -1, text_color
		)
	else:
		var ascent: float = speech_font.get_ascent(font_size)
		var descent: float = speech_font.get_descent(font_size)
		var ts: Vector2 = speech_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var tx: float = bubble_center.x - ts.x / 2.0
		var ty: float = bubble_center.y + (ascent - descent) / 2.0
		draw_string(speech_font, Vector2(tx, ty), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)

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
	# 食料ドット(エージェントより下に)
	if resources != null:
		for y in world.size:
			for x in world.size:
				if not resources.has_food(x, y):
					continue
				var fp := mm_origin + Vector2((x + 0.5) * cell, (y + 0.5) * cell)
				draw_circle(fp, max(0.8, cell * 0.2), Color(0.88, 0.30, 0.26, 1))
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
