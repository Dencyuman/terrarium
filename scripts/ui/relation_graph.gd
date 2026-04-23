class_name RelationGraphView
extends Node2D

signal agent_clicked(agent_id: int)

const VIEW_WIDTH: int = 720
const VIEW_HEIGHT: int = 720
const NODE_RADIUS: int = 20
const LABEL_FONT_SIZE: int = 13
const EDGE_LABEL_FONT_SIZE: int = 10
const EDGE_LABEL_MAX_CHARS: int = 18
const EDGE_MIN_WEIGHT: int = 3   # 弱いエッジは非表示

var agents: Array = []
var selected_agent_id: int = -1
# 死者を circle 上に表示するか。false にすると死者は完全に隠れ、生者のみで円配置し直す。
var include_dead: bool = true
var font_bold: SystemFont
var font_regular: SystemFont
var _dead_checkbox: CheckBox

func _ready() -> void:
	font_bold = SystemFont.new()
	font_bold.font_names = PackedStringArray([
		"Hiragino Kaku Gothic Pro", "Hiragino Sans", "Noto Sans CJK JP", "Yu Gothic", "Meiryo",
	])
	font_bold.font_weight = 700
	font_regular = SystemFont.new()
	font_regular.font_names = font_bold.font_names
	font_regular.font_weight = 500
	_dead_checkbox = CheckBox.new()
	_dead_checkbox.text = "死者を含める"
	_dead_checkbox.button_pressed = include_dead
	_dead_checkbox.position = Vector2(VIEW_WIDTH - 150, 24)
	_dead_checkbox.add_theme_font_size_override("font_size", 11)
	_dead_checkbox.toggled.connect(_on_include_dead_toggled)
	add_child(_dead_checkbox)

func _on_include_dead_toggled(enabled: bool) -> void:
	if enabled == include_dead:
		return
	include_dead = enabled
	queue_redraw()

# 実際に円上に描画する対象 agents。include_dead=false なら生者のみ。
func _display_agents() -> Array:
	if include_dead:
		return agents
	var out: Array = []
	for a in agents:
		if a.is_alive():
			out.append(a)
	return out

func set_agents(a: Array) -> void:
	agents = a
	queue_redraw()

func set_selected_agent(id: int) -> void:
	if id != selected_agent_id:
		selected_agent_id = id
		queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var disp: Array = _display_agents()
	if disp.is_empty():
		return
	var local := to_local(mb.global_position)
	if local.x < 0 or local.y < 0 or local.x >= VIEW_WIDTH or local.y >= VIEW_HEIGHT:
		return
	var positions := _compute_positions()
	for i in disp.size():
		var pos: Vector2 = positions[i]
		if local.distance_to(pos) <= NODE_RADIUS + 2:
			agent_clicked.emit(disp[i].id)
			get_viewport().set_input_as_handled()
			return

func _draw() -> void:
	_draw_frame()
	_draw_header()
	var positions := _compute_positions()
	var related_ids: Dictionary = _compute_related_ids()
	_draw_edges(positions, related_ids)
	_draw_nodes(positions, related_ids)
	_draw_legend()

func _draw_frame() -> void:
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.137, 0.153, 0.184, 1), true)
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.208, 0.227, 0.263, 1), false, 1.0)

func _draw_header() -> void:
	var header_color := Color(0.902, 0.894, 0.871, 1)
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	draw_string(font_bold, Vector2(20, 32), "関係性グラフ", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, header_color)
	var sub_text: String
	if selected_agent_id < 0:
		sub_text = "ノードをクリックでそのエージェントを選択 → interactions が線上に表示される"
	else:
		var selected_name := _agent_name(selected_agent_id)
		sub_text = "選択中: %s  ·  再度クリックで解除。線中央に %s の他者への記憶が並ぶ" % [selected_name, selected_name]
	draw_string(font_bold, Vector2(20, 54), sub_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)

func _agent_name(id: int) -> String:
	for a in agents:
		if a.id == id:
			return a.agent_name
	return "?"

func _compute_positions() -> Array:
	var center := Vector2(VIEW_WIDTH / 2.0, VIEW_HEIGHT / 2.0 + 20)
	var radius := min(VIEW_WIDTH, VIEW_HEIGHT) * 0.34
	var disp: Array = _display_agents()
	var count := disp.size()
	var positions: Array = []
	for i in count:
		var angle := TAU * float(i) / float(max(1, count)) - PI / 2.0
		positions.append(center + Vector2(cos(angle) * radius, sin(angle) * radius))
	return positions

func _index_of_id(target_id: int) -> int:
	var disp: Array = _display_agents()
	for i in disp.size():
		if disp[i].id == target_id:
			return i
	return -1

# 選択中エージェントが relation を持つ相手の id set(自身含む)
func _compute_related_ids() -> Dictionary:
	var out: Dictionary = {}
	if selected_agent_id < 0:
		return out
	out[selected_agent_id] = true
	var sel: Agent = null
	for a in agents:
		if a.id == selected_agent_id:
			sel = a
			break
	if sel == null:
		return out
	for oid in sel.relations.keys():
		out[int(oid)] = true
	return out

func _draw_edges(positions: Array, related_ids: Dictionary) -> void:
	var disp: Array = _display_agents()
	var drawn: Dictionary = {}
	for i in disp.size():
		var a: Agent = disp[i]
		for other_id in a.relations.keys():
			var j: int = _index_of_id(other_id)
			if j < 0 or j == i:
				continue
			var key_str := "%d_%d" % [min(i, j), max(i, j)]
			if drawn.has(key_str):
				continue
			drawn[key_str] = true
			var a_aff: int = int(a.relations[other_id].get("affection", 0))
			var b: Agent = disp[j]
			var b_aff: int = 0
			if b.relations.has(a.id):
				b_aff = int(b.relations[a.id].get("affection", 0))
			var weight: int = max(absi(a_aff), absi(b_aff))
			# 通常モード: 閾値未満はスキップ
			# 選択モード: 選択中 agent が関与するエッジは閾値無視、それ以外はスキップ
			var involves_selected: bool = selected_agent_id >= 0 and (a.id == selected_agent_id or b.id == selected_agent_id)
			if selected_agent_id >= 0:
				if not involves_selected:
					continue
			else:
				if weight < EDGE_MIN_WEIGHT:
					continue
			var combined: int = a_aff + b_aff
			var alpha: float = clamp(float(weight) / 80.0, 0.15, 0.85)
			if selected_agent_id >= 0 and involves_selected:
				alpha = clamp(alpha + 0.2, 0.3, 1.0)
			var color: Color
			if combined >= 0:
				color = Color(0.42, 0.81, 0.69, alpha)
			else:
				color = Color(0.88, 0.44, 0.44, alpha)
			var width: float = clamp(float(weight) / 25.0, 1.0, 5.0)
			draw_line(positions[i], positions[j], color, width)
			# エッジラベル(選択中かつそのエッジの片方が選択 agent なら、選択 agent 視点の interactions 最新 1 件)
			if selected_agent_id >= 0 and involves_selected:
				var me: Agent = a if a.id == selected_agent_id else b
				var other: Agent = b if a.id == selected_agent_id else a
				_draw_edge_label(positions[i], positions[j], me, other)

func _draw_edge_label(p1: Vector2, p2: Vector2, me: Agent, other: Agent) -> void:
	var rel: Dictionary = me.relations.get(other.id, {})
	var inter: Array = rel.get("interactions", [])
	if inter.is_empty():
		return
	var label: String = str(inter[inter.size() - 1])
	# 「tN 私が 霞 を抱擁した」のうち本文だけ残す
	var space := label.find(" ")
	if space > 0:
		label = label.substr(space + 1)
	if label.length() > EDGE_LABEL_MAX_CHARS:
		label = label.substr(0, EDGE_LABEL_MAX_CHARS) + "…"
	var mid := (p1 + p2) * 0.5
	var sz: Vector2 = font_regular.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, EDGE_LABEL_FONT_SIZE)
	var bg_rect := Rect2(mid.x - sz.x / 2 - 4, mid.y - sz.y / 2 - 2, sz.x + 8, sz.y + 4)
	draw_rect(bg_rect, Color(0.08, 0.09, 0.11, 0.92), true)
	draw_rect(bg_rect, Color(0.35, 0.37, 0.42, 0.8), false, 0.8)
	var ascent: float = font_regular.get_ascent(EDGE_LABEL_FONT_SIZE)
	var descent: float = font_regular.get_descent(EDGE_LABEL_FONT_SIZE)
	var baseline := Vector2(mid.x - sz.x / 2, mid.y + (ascent - descent) / 2)
	draw_string(font_regular, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1, EDGE_LABEL_FONT_SIZE, Color(0.92, 0.90, 0.86, 0.95))

func _draw_nodes(positions: Array, related_ids: Dictionary) -> void:
	var disp: Array = _display_agents()
	for i in disp.size():
		var pos: Vector2 = positions[i]
		var agent: Agent = disp[i]
		var is_selected: bool = agent.id == selected_agent_id
		var is_related: bool = related_ids.has(agent.id)
		# 選択モードで関係なし → dim
		var dim: float = 1.0
		if selected_agent_id >= 0 and not is_related:
			dim = 0.2
		if agent.is_alive():
			var color: Color = agent.badge_color()
			color.a *= dim
			draw_circle(pos + Vector2(0, 2), NODE_RADIUS, Color(0, 0, 0, 0.35 * dim))
			draw_circle(pos, NODE_RADIUS, color)
			if is_selected:
				draw_arc(pos, NODE_RADIUS + 5, 0, TAU, 48, Color(0.98, 0.82, 0.28, 1.0), 2.5)
				draw_arc(pos, NODE_RADIUS, 0, TAU, 48, Color(1, 1, 1, 1.0), 2.0)
			else:
				draw_arc(pos, NODE_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.8 * dim), 1.5)
			_draw_node_label(agent.agent_name, pos, Color(1, 1, 1, 0.95 * dim))
		else:
			# 死者: world_view / family_tree と同様に グレー + ✕ で描画。
			var base := Color(0.32, 0.32, 0.34, 0.85 * dim)
			draw_circle(pos + Vector2(0, 2), NODE_RADIUS, Color(0, 0, 0, 0.25 * dim))
			draw_circle(pos, NODE_RADIUS, base)
			draw_arc(pos, NODE_RADIUS, 0, TAU, 48, Color(0.10, 0.12, 0.16, 0.7 * dim), 1.0)
			_draw_node_label(agent.agent_name, pos, Color(0.75, 0.72, 0.68, 0.70 * dim))
			var r: float = NODE_RADIUS - 4
			var x_color := Color(0.88, 0.88, 0.88, 0.70 * dim)
			draw_line(pos + Vector2(-r, -r), pos + Vector2(r, r), x_color, 1.5)
			draw_line(pos + Vector2(-r, r), pos + Vector2(r, -r), x_color, 1.5)
			if is_selected:
				draw_arc(pos, NODE_RADIUS + 5, 0, TAU, 48, Color(0.98, 0.82, 0.28, 1.0), 2.5)

func _draw_node_label(text: String, pos: Vector2, color: Color) -> void:
	var text_size: Vector2 = font_bold.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, LABEL_FONT_SIZE)
	var ascent: float = font_bold.get_ascent(LABEL_FONT_SIZE)
	var descent: float = font_bold.get_descent(LABEL_FONT_SIZE)
	var baseline := Vector2(
		pos.x - text_size.x / 2.0,
		pos.y + (ascent - descent) / 2.0
	)
	draw_string(font_bold, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, color)

func _draw_legend() -> void:
	var lx := 20.0
	var ly := VIEW_HEIGHT - 90.0
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	var body_color := Color(0.74, 0.73, 0.70, 1)
	draw_string(font_bold, Vector2(lx, ly), "凡例", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)
	var lyy := ly + 20
	draw_line(Vector2(lx, lyy), Vector2(lx + 30, lyy), Color(0.42, 0.81, 0.69, 0.85), 3.0)
	draw_string(font_bold, Vector2(lx + 42, lyy + 4), "好意(affection 和 > 0)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, body_color)
	lyy += 16
	draw_line(Vector2(lx, lyy), Vector2(lx + 30, lyy), Color(0.88, 0.44, 0.44, 0.85), 3.0)
	draw_string(font_bold, Vector2(lx + 42, lyy + 4), "敵対(affection 和 < 0)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, body_color)
	lyy += 16
	draw_line(Vector2(lx, lyy), Vector2(lx + 30, lyy), Color(0.6, 0.6, 0.6, 0.5), 1.2)
	draw_string(font_bold, Vector2(lx + 42, lyy + 4), "弱い関係(|aff| 3〜30)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, body_color)
	lyy += 16
	draw_line(Vector2(lx, lyy), Vector2(lx + 30, lyy), Color(0.6, 0.6, 0.6, 0.9), 4.5)
	draw_string(font_bold, Vector2(lx + 42, lyy + 4), "強い関係(|aff| 80+)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, body_color)
