extends Node2D

# テラリウム一覧トップページ。
# - 既存のテラリウムをカード表示(タイトル、キャスト数、seed、run 回数、編集可否)
# - カードクリック → Sim 起動、✎ → Editor、✕ → 削除
# - ヘッダー [新規作成] → Editor で新規テラリウム作成

var store: TerrariumStore

func _ready() -> void:
	store = TerrariumStore.new()
	if not store.open():
		push_error("[TopPage] TerrariumStore open failed")
	var new_btn := get_node_or_null(^"UI/NewBtn") as Button
	if new_btn != null:
		new_btn.pressed.connect(_on_new_pressed)
	_refresh_list()

func _exit_tree() -> void:
	if store != null:
		store.close()

func _refresh_list() -> void:
	var list := get_node_or_null(^"UI/ListPanel/Scroll/List") as VBoxContainer
	var empty := get_node_or_null(^"UI/ListPanel/EmptyState") as Label
	if list == null:
		return
	for child in list.get_children():
		child.queue_free()
	var rows: Array = store.list_terrariums() if store != null else []
	if empty != null:
		empty.visible = rows.is_empty()
	for row in rows:
		list.add_child(_make_card(row))

func _make_card(row: Dictionary) -> Control:
	var card := Panel.new()
	card.custom_minimum_size = Vector2(1300, 80)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.137, 0.153, 0.184, 1)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.239, 0.259, 0.298, 1)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	card.add_theme_stylebox_override("panel", sb)

	var title_lbl := Label.new()
	title_lbl.text = str(row.get("title", "untitled"))
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", Color(0.902, 0.894, 0.871, 1))
	title_lbl.position = Vector2(20, 12)
	title_lbl.size = Vector2(500, 26)
	card.add_child(title_lbl)

	var cast_count: int = _count_cast(row)
	var run_count: int = int(row.get("run_count", 0))
	var editable: bool = bool(row.get("is_editable", true))
	var meta_text: String = "キャスト %d 人  ·  world %d×%d  ·  seed 0x%08X  ·  tick/day %d  ·  run %d 回" % [
		cast_count,
		int(row.get("world_size", 20)),
		int(row.get("world_size", 20)),
		int(row.get("world_seed", 0)),
		int(row.get("tick_per_day", 10)),
		run_count,
	]
	var meta_lbl := Label.new()
	meta_lbl.text = meta_text
	meta_lbl.add_theme_font_size_override("font_size", 11)
	meta_lbl.add_theme_color_override("font_color", Color(0.541, 0.525, 0.502, 1))
	meta_lbl.position = Vector2(22, 42)
	meta_lbl.size = Vector2(900, 20)
	card.add_child(meta_lbl)

	var badge := Label.new()
	badge.text = "編集可" if editable else "動作済み(編集不可)"
	badge.add_theme_font_size_override("font_size", 10)
	if editable:
		badge.add_theme_color_override("font_color", Color(0.431, 0.855, 0.541, 1))
	else:
		badge.add_theme_color_override("font_color", Color(0.88, 0.72, 0.38, 1))
	badge.position = Vector2(940, 42)
	badge.size = Vector2(200, 20)
	card.add_child(badge)

	var run_btn := Button.new()
	run_btn.text = "▶ 起動"
	run_btn.position = Vector2(1100, 22)
	run_btn.size = Vector2(80, 36)
	run_btn.pressed.connect(_on_run_pressed.bind(int(row["id"])))
	card.add_child(run_btn)

	var edit_btn := Button.new()
	edit_btn.text = "✎" if editable else "👁"
	edit_btn.tooltip_text = "編集" if editable else "閲覧のみ"
	edit_btn.position = Vector2(1190, 22)
	edit_btn.size = Vector2(40, 36)
	edit_btn.pressed.connect(_on_edit_pressed.bind(int(row["id"])))
	card.add_child(edit_btn)

	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.tooltip_text = "削除(編集可能な場合のみ)" if editable else "動作済みは削除不可"
	del_btn.disabled = not editable
	del_btn.position = Vector2(1240, 22)
	del_btn.size = Vector2(40, 36)
	del_btn.pressed.connect(_on_delete_pressed.bind(int(row["id"])))
	card.add_child(del_btn)

	return card

func _count_cast(row: Dictionary) -> int:
	# cast_json はこの select では入ってないので、必要なら別クエリ。
	# list_terrariums の SELECT は * ではないため、ここで cast_json を取るには単発 get_terrarium。
	var tid: int = int(row.get("id", -1))
	if tid < 0 or store == null:
		return 0
	var full: Dictionary = store.get_terrarium(tid)
	var cast_raw = JSON.parse_string(str(full.get("cast_json", "[]")))
	if cast_raw is Array:
		return cast_raw.size()
	return 0

func _on_new_pressed() -> void:
	GameContext.selected_terrarium_id = -1
	get_tree().change_scene_to_file("res://scenes/Editor.tscn")

func _on_edit_pressed(terrarium_id: int) -> void:
	GameContext.selected_terrarium_id = terrarium_id
	get_tree().change_scene_to_file("res://scenes/Editor.tscn")

func _on_run_pressed(terrarium_id: int) -> void:
	GameContext.selected_terrarium_id = terrarium_id
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_delete_pressed(terrarium_id: int) -> void:
	if store == null:
		return
	if store.delete_terrarium(terrarium_id):
		_refresh_list()
