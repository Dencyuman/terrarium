class_name RelationGraphView
extends Node2D

const VIEW_WIDTH: int = 836
const VIEW_HEIGHT: int = 764
const NODE_RADIUS: int = 20
const LABEL_FONT_SIZE: int = 13

var agents: Array = []
var font_bold: SystemFont

func _ready() -> void:
	font_bold = SystemFont.new()
	font_bold.font_names = PackedStringArray([
		"Hiragino Kaku Gothic Pro",
		"Hiragino Sans",
		"Noto Sans CJK JP",
		"Yu Gothic",
		"Meiryo",
	])
	font_bold.font_weight = 700

func set_agents(a: Array) -> void:
	agents = a
	queue_redraw()

func _draw() -> void:
	_draw_frame()
	_draw_header()
	_draw_edges_placeholder()
	_draw_nodes()
	_draw_legend()

func _draw_frame() -> void:
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.137, 0.153, 0.184, 1), true)
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.208, 0.227, 0.263, 1), false, 1.0)

func _draw_header() -> void:
	var header_color := Color(0.902, 0.894, 0.871, 1)
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	draw_string(font_bold, Vector2(20, 32), "関係性グラフ", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, header_color)
	draw_string(font_bold, Vector2(20, 54), "Force-directed layout (Phase 4+ で好感度/信頼度データと連動)",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)

func _draw_nodes() -> void:
	var center := Vector2(VIEW_WIDTH / 2.0, VIEW_HEIGHT / 2.0 + 20)
	var radius := min(VIEW_WIDTH, VIEW_HEIGHT) * 0.34
	var count := agents.size()
	for i in count:
		var angle := TAU * float(i) / float(count) - PI / 2.0
		var pos := center + Vector2(cos(angle) * radius, sin(angle) * radius)
		var agent: Agent = agents[i]
		var color: Color = agent.badge_color()
		draw_circle(pos + Vector2(0, 2), NODE_RADIUS, Color(0, 0, 0, 0.35))
		draw_circle(pos, NODE_RADIUS, color)
		draw_arc(pos, NODE_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.8), 1.5)
		var ch: String = agent.agent_name
		var text_size: Vector2 = font_bold.get_string_size(ch, HORIZONTAL_ALIGNMENT_CENTER, -1, LABEL_FONT_SIZE)
		var ascent: float = font_bold.get_ascent(LABEL_FONT_SIZE)
		var descent: float = font_bold.get_descent(LABEL_FONT_SIZE)
		var baseline := Vector2(
			pos.x - text_size.x / 2.0,
			pos.y + (ascent - descent) / 2.0
		)
		draw_string(font_bold, baseline, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, Color(1, 1, 1, 0.95))

func _draw_edges_placeholder() -> void:
	# Phase 4+ で実データのエッジが描画される。Phase 1 は「未連動」を可視化。
	var center := Vector2(VIEW_WIDTH / 2.0, VIEW_HEIGHT / 2.0 + 20)
	var edge_color := Color(0.30, 0.32, 0.36, 0.5)
	var count := agents.size()
	if count == 0:
		return
	var radius := min(VIEW_WIDTH, VIEW_HEIGHT) * 0.34
	# 薄い参考線として id 隣接のみをつなぐ(実データではない旨を中央に表示)
	for i in count:
		var a1 := TAU * float(i) / float(count) - PI / 2.0
		var a2 := TAU * float((i + 1) % count) / float(count) - PI / 2.0
		var p1 := center + Vector2(cos(a1) * radius, sin(a1) * radius)
		var p2 := center + Vector2(cos(a2) * radius, sin(a2) * radius)
		draw_line(p1, p2, edge_color, 1.0)
	# 中央ノートに未連動ステータス
	var note := "RELATION DATA NOT YET AVAILABLE"
	var note_size: Vector2 = font_bold.get_string_size(note, HORIZONTAL_ALIGNMENT_CENTER, -1, 12)
	draw_rect(Rect2(center.x - note_size.x / 2.0 - 16, center.y - 18, note_size.x + 32, 36),
		Color(0.10, 0.12, 0.16, 0.85), true)
	draw_rect(Rect2(center.x - note_size.x / 2.0 - 16, center.y - 18, note_size.x + 32, 36),
		Color(0.54, 0.47, 0.32, 0.8), false, 1.0)
	draw_string(font_bold, Vector2(center.x - note_size.x / 2.0, center.y + 5), note,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.88, 0.75, 0.40, 1))

func _draw_legend() -> void:
	var lx := 20.0
	var ly := VIEW_HEIGHT - 70.0
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	var body_color := Color(0.74, 0.73, 0.70, 1)
	draw_string(font_bold, Vector2(lx, ly), "凡例(Phase 4+ 実装時)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)
	var lines := [
		"— 緑/太いエッジ: 友好・信頼",
		"— 赤/鋸歯エッジ: 敵対・恐怖",
		"— 水色/実線: 親子・血縁",
		"— ノード色: 性格優位軸(§3.9.2)",
	]
	for i in lines.size():
		draw_string(font_bold, Vector2(lx, ly + 18 + i * 16), lines[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, body_color)
