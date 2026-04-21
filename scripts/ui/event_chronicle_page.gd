class_name EventChroniclePageView
extends Node2D

const VIEW_WIDTH: int = 836
const VIEW_HEIGHT: int = 764

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
	_draw_filter_tabs()
	_draw_empty_state()
	_draw_phase_map()

func _draw_header() -> void:
	var header_color := Color(0.902, 0.894, 0.871, 1)
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	draw_string(font_bold, Vector2(20, 32), "年代記", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, header_color)
	draw_string(font_bold, Vector2(20, 54), "tick 順に蓄積される重大イベントの全画面ビュー",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)

func _draw_filter_tabs() -> void:
	var labels := ["全て", "誕生", "死亡", "戦闘", "共有", "教育"]
	var lx := 20.0
	var ly := 80.0
	for i in labels.size():
		var w := 60.0 if i == 0 else 72.0
		var rect := Rect2(lx, ly, w, 28)
		var is_first := i == 0
		var bg := Color(0.176, 0.196, 0.231, 1) if is_first else Color(0.10, 0.12, 0.16, 0.5)
		draw_rect(rect, bg, true)
		draw_rect(rect, Color(0.208, 0.227, 0.263, 1), false, 1.0)
		var text_color := Color(0.902, 0.894, 0.871, 1) if is_first else Color(0.541, 0.525, 0.502, 1)
		draw_string(font_bold, Vector2(lx + 14, ly + 19), labels[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, text_color)
		lx += w + 6

func _draw_empty_state() -> void:
	var center := Vector2(VIEW_WIDTH / 2.0, 280)
	var title_color := Color(0.541, 0.525, 0.502, 1)
	var sub_color := Color(0.40, 0.39, 0.36, 1)
	var title := "まだイベントは発生していません"
	var title_w: float = font_bold.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, 14).x
	draw_string(font_bold, Vector2(center.x - title_w / 2.0, center.y),
		title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, title_color)
	var sub := "シミュレーション開始後、ここに tick 順で重大イベントが記録されます"
	var sub_w: float = font_bold.get_string_size(sub, HORIZONTAL_ALIGNMENT_CENTER, -1, 11).x
	draw_string(font_bold, Vector2(center.x - sub_w / 2.0, center.y + 22),
		sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)

func _draw_phase_map() -> void:
	var lx := 60.0
	var ly := 400.0
	var header_color := Color(0.902, 0.894, 0.871, 1)
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	var body := Color(0.74, 0.73, 0.70, 1)
	draw_string(font_bold, Vector2(lx, ly), "実装マップ", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, header_color)
	var rows := [
		["💢", "戦闘 (attack)", "Phase 4", Color(0.88, 0.44, 0.44, 1)],
		["💫", "誕生 (reproduce_with 結果)", "Phase 5", Color(0.98, 0.82, 0.28, 1)],
		["🕊", "死亡 (老衰 / 飢餓 / 致命打)", "Phase 5", Color(0.70, 0.70, 0.70, 1)],
		["🎓", "教育 (teach による記憶転送)", "Phase 6", Color(0.42, 0.81, 0.69, 1)],
		["📜", "共有オブジェクト (create_shared_object / modify_object)", "Phase 7", Color(0.88, 0.72, 0.38, 1)],
	]
	for i in rows.size():
		var y: float = ly + 28 + i * 30
		var icon: String = rows[i][0]
		var label: String = rows[i][1]
		var phase: String = rows[i][2]
		var color: Color = rows[i][3]
		draw_string(font_bold, Vector2(lx, y), icon, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, color)
		draw_string(font_bold, Vector2(lx + 28, y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, body)
		draw_string(font_bold, Vector2(lx + 440, y), phase,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, sub_color)
