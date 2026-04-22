class_name FamilyTreeView
extends Node2D

const VIEW_WIDTH: int = 720
const VIEW_HEIGHT: int = 720
const NODE_RADIUS: int = 18
const LABEL_FONT_SIZE: int = 12

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
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.137, 0.153, 0.184, 1), true)
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.208, 0.227, 0.263, 1), false, 1.0)
	_draw_header()
	_draw_generation_row()
	_draw_future_generations()
	_draw_legend()

func _draw_header() -> void:
	var header_color := Color(0.902, 0.894, 0.871, 1)
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	draw_string(font_bold, Vector2(20, 32), "家系図", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, header_color)
	draw_string(font_bold, Vector2(20, 54), "縦軸=世代(上が古い)。親子線は reproduce_with + 誕生ログから Phase 5+ で生成",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)

func _draw_generation_row() -> void:
	# G1 (現在の 20 体) を中央横一行に並べる
	var gen_y := 130.0
	var margin := 40.0
	var count := agents.size()
	if count == 0:
		return
	var row_w := VIEW_WIDTH - margin * 2
	var step := row_w / float(count - 1 if count > 1 else 1)
	# 世代ラベル
	var gen_color := Color(0.980, 0.820, 0.280, 1)
	draw_string(font_bold, Vector2(20, gen_y + 5), "G1", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, gen_color)
	# 横のベースライン
	draw_line(Vector2(margin, gen_y), Vector2(margin + row_w, gen_y), Color(0.30, 0.32, 0.36, 0.6), 1.0)
	for i in count:
		var x := margin + step * float(i)
		var pos := Vector2(x, gen_y)
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

func _draw_future_generations() -> void:
	var sub := Color(0.541, 0.525, 0.502, 1)
	var dash := Color(0.30, 0.32, 0.36, 0.6)
	var ys := [280, 400, 520, 640]
	var labels := ["G2", "G3", "G4", "G5+"]
	for i in ys.size():
		var y = ys[i]
		# 点線ベースライン
		var x := 40.0
		while x < VIEW_WIDTH - 40:
			draw_line(Vector2(x, y), Vector2(x + 6, y), dash, 1.0)
			x += 12
		draw_string(font_bold, Vector2(20, y + 5), labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, sub)
	var note := "将来の世代は reproduce_with の合意と誕生イベントから動的に描画される(Phase 5+)"
	draw_string(font_bold, Vector2(20, VIEW_HEIGHT - 120), note,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub)

func _draw_legend() -> void:
	var lx := 20.0
	var ly := VIEW_HEIGHT - 80.0
	var sub := Color(0.541, 0.525, 0.502, 1)
	var body := Color(0.74, 0.73, 0.70, 1)
	draw_string(font_bold, Vector2(lx, ly), "凡例", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub)
	var lines := [
		"— 縦線: 親→子の血縁",
		"— 横線: reproduce_with の番",
		"—  † : 死亡者(半透明)",
	]
	for i in lines.size():
		draw_string(font_bold, Vector2(lx, ly + 18 + i * 16), lines[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, body)
