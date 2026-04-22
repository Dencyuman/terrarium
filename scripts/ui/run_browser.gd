extends Node2D

# 過去 run の全一覧。新しい順。click で RunTimeline へ遷移。

var store: TerrariumStore

func _ready() -> void:
	store = TerrariumStore.new()
	if not store.open():
		push_error("[RunBrowser] TerrariumStore open failed")
	var back := get_node_or_null(^"UI/BackBtn") as Button
	if back != null:
		back.pressed.connect(_on_back_pressed)
	_populate()

func _exit_tree() -> void:
	if store != null:
		store.close()

func _populate() -> void:
	var list := get_node_or_null(^"UI/ListPanel/Scroll/List") as VBoxContainer
	var empty := get_node_or_null(^"UI/ListPanel/EmptyState") as Label
	if list == null:
		return
	for c in list.get_children():
		c.queue_free()
	var rows: Array = store.list_all_runs() if store != null else []
	if empty != null:
		empty.visible = rows.is_empty()
	for row in rows:
		list.add_child(_make_run_row(row))

func _make_run_row(row: Dictionary) -> Control:
	var card := Panel.new()
	card.custom_minimum_size = Vector2(1300, 44)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.137, 0.153, 0.184, 1)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.239, 0.259, 0.298, 1)
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3
	sb.corner_radius_bottom_right = 3
	card.add_theme_stylebox_override("panel", sb)

	var run_id: int = int(row.get("id", -1))
	var t_title: String = str(row.get("terrarium_title", "?"))
	var started: String = str(row.get("started_at", ""))
	var tick: int = int(row.get("final_tick", 0))
	var alive: int = int(row.get("final_alive", 0))
	var total: int = int(row.get("final_total", 0))
	var provider: String = str(row.get("provider", ""))
	var model: String = str(row.get("model", ""))
	var cost: float = float(row.get("cost_usd", 0.0))
	var in_tok: int = int(row.get("input_tokens", 0))
	var out_tok: int = int(row.get("output_tokens", 0))
	var ended: String = str(row.get("ended_at", ""))
	var running: bool = ended == ""

	_add_lbl(card, "r%d · %s" % [run_id, t_title], 16, 12, 244, 20, 12, Color(0.902, 0.894, 0.871, 1))
	_add_lbl(card, _short_time(started), 276, 12, 184, 20, 11, Color(0.820, 0.808, 0.784, 1))
	_add_lbl(card, "%d" % tick, 476, 12, 84, 20, 11, Color(0.820, 0.808, 0.784, 1), HORIZONTAL_ALIGNMENT_RIGHT)
	_add_lbl(card, "%d / %d" % [alive, total], 580, 12, 120, 20, 11, Color(0.820, 0.808, 0.784, 1), HORIZONTAL_ALIGNMENT_RIGHT)
	_add_lbl(card, "%s · %s" % [provider, model], 720, 12, 240, 20, 11, Color(0.541, 0.525, 0.502, 1))
	_add_lbl(card, "$%.4f" % cost, 980, 12, 120, 20, 11, Color(0.820, 0.808, 0.784, 1), HORIZONTAL_ALIGNMENT_RIGHT)
	_add_lbl(card, "%.1fk / %.1fk" % [float(in_tok)/1000.0, float(out_tok)/1000.0], 1120, 12, 130, 20, 10, Color(0.541, 0.525, 0.502, 1), HORIZONTAL_ALIGNMENT_RIGHT)

	if running:
		var badge := Label.new()
		badge.text = "中断"
		badge.add_theme_font_size_override("font_size", 9)
		badge.add_theme_color_override("font_color", Color(0.88, 0.72, 0.38, 1))
		badge.position = Vector2(244, 14)
		badge.size = Vector2(32, 16)
		card.add_child(badge)

	var btn := Button.new()
	btn.text = "詳細"
	btn.position = Vector2(1254, 8)
	btn.size = Vector2(44, 28)
	btn.pressed.connect(_on_detail_pressed.bind(run_id))
	card.add_child(btn)
	return card

func _add_lbl(parent: Control, text: String, x: int, y: int, w: int, h: int, fs: int, col: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	l.position = Vector2(x, y)
	l.size = Vector2(w, h)
	l.horizontal_alignment = align
	parent.add_child(l)

func _short_time(iso: String) -> String:
	# "2026-04-23T03:51:31" → "04-23 03:51"
	if iso.length() < 16:
		return iso
	return iso.substr(5, 5) + " " + iso.substr(11, 5)

func _on_detail_pressed(run_id: int) -> void:
	GameContext.selected_run_id = run_id
	get_tree().change_scene_to_file("res://scenes/RunTimeline.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/TopPage.tscn")
