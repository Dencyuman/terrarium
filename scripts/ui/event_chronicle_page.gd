class_name EventChroniclePageView
extends Node2D

# 年代記フルページ: 蓄積された重大イベント全件を tick 順で表示。
# 右下コンパクトパネルの「見やすい全件版」という位置付け。
# フィルタは main.gd 側と連動(main が active filter とエントリ全件を push してくる)。

signal filter_requested(kind: String)

const VIEW_WIDTH: int = 720
const VIEW_HEIGHT: int = 720
const FILTER_KINDS: Array = ["all", "birth", "death", "attack", "embrace", "give", "teach"]
const FILTER_LABELS: Array = ["全て", "誕生", "死亡", "戦闘", "抱擁", "分与", "教育"]
const FILTER_ROW_Y: float = 76.0

var agents: Array = []
var entries: Array = []
var active_filter: String = "all"
var font_bold: SystemFont

# 描画済みフィルタボタンの当たり判定 {kind: Rect2}
var _filter_rects: Dictionary = {}
# 本文 RichTextLabel(一度だけ _ready で生成)
var _body: RichTextLabel

func _ready() -> void:
	font_bold = SystemFont.new()
	font_bold.font_names = PackedStringArray([
		"Hiragino Kaku Gothic Pro", "Hiragino Sans", "Noto Sans CJK JP", "Yu Gothic", "Meiryo",
	])
	font_bold.font_weight = 700
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true
	_body.scroll_following = true
	_body.position = Vector2(20, 120)
	_body.size = Vector2(VIEW_WIDTH - 40, VIEW_HEIGHT - 140)
	_body.add_theme_font_size_override("normal_font_size", 11)
	_body.add_theme_color_override("default_color", Color(0.820, 0.808, 0.784, 1))
	add_child(_body)

func set_agents(a: Array) -> void:
	agents = a

func set_entries(all_entries: Array, filter_kind: String) -> void:
	entries = all_entries
	active_filter = filter_kind
	_refresh_body()
	queue_redraw()

func _refresh_body() -> void:
	if _body == null:
		return
	var filtered: Array = _apply_filter(entries, active_filter)
	if filtered.is_empty():
		_body.text = "[color=#6a6660]まだ該当イベントはありません[/color]"
		return
	var lines: Array[String] = []
	for e in filtered:
		lines.append(_line(e))
	_body.text = "\n".join(lines)

func _apply_filter(es: Array, kind: String) -> Array:
	if kind == "all":
		return es
	var out: Array = []
	for e in es:
		if str(e.get("kind", "")) == kind:
			out.append(e)
	return out

func _line(e: Dictionary) -> String:
	var kind: String = str(e.get("kind", ""))
	var icon: String
	var color: String
	match kind:
		"birth":
			icon = "💫"; color = "#d893b8"
		"reproduce_fail":
			icon = "·"; color = "#8a8680"
		"death":
			icon = "🕊"; color = "#c0b8a8"
		"attack":
			icon = "💢"; color = "#e07070"
		"give":
			icon = "📤"; color = "#6acfb0"
		"embrace":
			icon = "💕"; color = "#e0a0c0"
		"teach":
			icon = "🎓"; color = "#6ebfc0"
		_:
			icon = "·"; color = "#8a8680"
	var tick_str := "[color=#6a6660]t%04d[/color]" % int(e.get("tick", 0))
	return "%s  [color=%s]%s[/color] %s" % [tick_str, color, icon, str(e.get("text", ""))]

func _draw() -> void:
	_draw_frame()
	_draw_header()
	_draw_filter_tabs()

func _draw_frame() -> void:
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.137, 0.153, 0.184, 1), true)
	draw_rect(Rect2(0, 0, VIEW_WIDTH, VIEW_HEIGHT), Color(0.208, 0.227, 0.263, 1), false, 1.0)

func _draw_header() -> void:
	var header_color := Color(0.902, 0.894, 0.871, 1)
	var sub_color := Color(0.541, 0.525, 0.502, 1)
	draw_string(font_bold, Vector2(20, 32), "年代記", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, header_color)
	var filtered: Array = _apply_filter(entries, active_filter)
	var sub_text := "tick 順の全イベント  ·  %d 件表示 (全 %d 件)" % [filtered.size(), entries.size()]
	draw_string(font_bold, Vector2(20, 54), sub_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, sub_color)

func _draw_filter_tabs() -> void:
	_filter_rects.clear()
	var lx := 20.0
	var ly := FILTER_ROW_Y
	for i in FILTER_KINDS.size():
		var kind: String = FILTER_KINDS[i]
		var label: String = FILTER_LABELS[i]
		var w: float = 60.0 if kind == "all" else 64.0
		var rect := Rect2(lx, ly, w, 28)
		var is_active: bool = (kind == active_filter)
		var bg: Color = Color(0.176, 0.196, 0.231, 1) if is_active else Color(0.10, 0.12, 0.16, 0.5)
		draw_rect(rect, bg, true)
		draw_rect(rect, Color(0.208, 0.227, 0.263, 1), false, 1.0)
		var text_color: Color = Color(0.902, 0.894, 0.871, 1) if is_active else Color(0.541, 0.525, 0.502, 1)
		var text_w: float = font_bold.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, 11).x
		draw_string(font_bold, Vector2(lx + (w - text_w) / 2.0, ly + 19),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, text_color)
		_filter_rects[kind] = rect
		lx += w + 6

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var local := to_local(mb.global_position)
	if local.x < 0 or local.y < 0 or local.x >= VIEW_WIDTH or local.y >= VIEW_HEIGHT:
		return
	for kind in _filter_rects.keys():
		var r: Rect2 = _filter_rects[kind]
		if r.has_point(local):
			filter_requested.emit(str(kind))
			get_viewport().set_input_as_handled()
			return
