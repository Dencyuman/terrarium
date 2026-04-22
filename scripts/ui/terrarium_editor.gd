extends Node2D

# テラリウム作成 / 編集画面。
# GameContext.selected_terrarium_id が
#   -1          → 新規作成(data/config.json + names.json を雛形として読み込む)
#   >0 で編集可 → 既存編集
#   >0 で動作済み → 閲覧専用(全入力欄 disabled、保存ボタン非表示)

var store: TerrariumStore
var terrarium_id: int = -1
var editable: bool = true

var base_config: Dictionary = {}    # LLM / costs / resources / relations / agents など丸ごと
var cast_data: Array = []           # Array[Dictionary], 各要素 = {name, romaji, gender, cooperative, aggressive, curious}

func _ready() -> void:
	randomize()
	store = TerrariumStore.new()
	if not store.open():
		push_error("[Editor] TerrariumStore open failed")

	var save_btn := get_node_or_null(^"UI/SaveBtn") as Button
	var back_btn := get_node_or_null(^"UI/BackBtn") as Button
	var add_btn := get_node_or_null(^"UI/CastPanel/AddCastBtn") as Button
	var rnd_btn := get_node_or_null(^"UI/MetaPanel/SeedRandomBtn") as Button
	if save_btn != null: save_btn.pressed.connect(_on_save_pressed)
	if back_btn != null: back_btn.pressed.connect(_on_back_pressed)
	if add_btn != null:  add_btn.pressed.connect(_on_add_cast_pressed)
	if rnd_btn != null:  rnd_btn.pressed.connect(_on_random_seed_pressed)

	terrarium_id = GameContext.selected_terrarium_id if GameContext else -1
	if terrarium_id > 0 and store != null:
		_load_existing(terrarium_id)
	else:
		_load_template()
	_rebuild_cast_list()
	_apply_readonly_if_needed()

func _exit_tree() -> void:
	if store != null:
		store.close()

# --- load paths ---

func _load_existing(id: int) -> void:
	var row: Dictionary = store.get_terrarium(id)
	if row.is_empty():
		_load_template()
		return
	editable = store.is_terrarium_editable(id)
	(get_node_or_null(^"UI/MetaPanel/TitleField") as LineEdit).text = str(row.get("title", ""))
	(get_node_or_null(^"UI/MetaPanel/DescField") as LineEdit).text = str(row.get("description", ""))
	(get_node_or_null(^"UI/MetaPanel/SeedField") as SpinBox).value = float(int(row.get("world_seed", 0)))
	(get_node_or_null(^"UI/MetaPanel/TickPerDayField") as SpinBox).value = float(int(row.get("tick_per_day", 10)))
	var cfg = JSON.parse_string(str(row.get("config_json", "{}")))
	base_config = cfg if cfg is Dictionary else {}
	var cast_raw = JSON.parse_string(str(row.get("cast_json", "[]")))
	cast_data = []
	if cast_raw is Array:
		for a in cast_raw:
			if a is Dictionary:
				cast_data.append(a.duplicate(true))

func _load_template() -> void:
	editable = true
	var cfg_path := "res://data/config.json"
	var names_path := "res://data/names.json"
	var f := FileAccess.open(cfg_path, FileAccess.READ)
	if f != null:
		var txt := f.get_as_text()
		var parsed = JSON.parse_string(txt)
		if parsed is Dictionary:
			base_config = parsed
	var f2 := FileAccess.open(names_path, FileAccess.READ)
	if f2 != null:
		var txt2 := f2.get_as_text()
		var parsed2 = JSON.parse_string(txt2)
		if parsed2 is Dictionary and parsed2.has("agents"):
			cast_data = parsed2["agents"]
	(get_node_or_null(^"UI/MetaPanel/TitleField") as LineEdit).text = "new terrarium"
	(get_node_or_null(^"UI/MetaPanel/DescField") as LineEdit).text = ""
	var seed_field := get_node_or_null(^"UI/MetaPanel/SeedField") as SpinBox
	if seed_field != null:
		seed_field.value = float(int(base_config.get("world", {}).get("seed", randi())))
	(get_node_or_null(^"UI/MetaPanel/TickPerDayField") as SpinBox).value = float(int(base_config.get("world", {}).get("tick_per_day", 10)))

func _apply_readonly_if_needed() -> void:
	if editable:
		return
	var badge := get_node_or_null(^"UI/ReadOnlyBadge") as Label
	if badge != null: badge.visible = true
	var save_btn := get_node_or_null(^"UI/SaveBtn") as Button
	if save_btn != null: save_btn.visible = false
	var add_btn := get_node_or_null(^"UI/CastPanel/AddCastBtn") as Button
	if add_btn != null: add_btn.disabled = true
	var title_f := get_node_or_null(^"UI/MetaPanel/TitleField") as LineEdit
	var desc_f := get_node_or_null(^"UI/MetaPanel/DescField") as LineEdit
	var seed_f := get_node_or_null(^"UI/MetaPanel/SeedField") as SpinBox
	var tpd_f := get_node_or_null(^"UI/MetaPanel/TickPerDayField") as SpinBox
	var rnd_f := get_node_or_null(^"UI/MetaPanel/SeedRandomBtn") as Button
	if title_f != null: title_f.editable = false
	if desc_f  != null: desc_f.editable = false
	if seed_f  != null: seed_f.editable = false
	if tpd_f   != null: tpd_f.editable = false
	if rnd_f   != null: rnd_f.disabled = true

# --- cast UI ---

func _rebuild_cast_list() -> void:
	var list := get_node_or_null(^"UI/CastPanel/CastScroll/CastList") as VBoxContainer
	if list == null:
		return
	for c in list.get_children():
		c.queue_free()
	for i in range(cast_data.size()):
		list.add_child(_make_cast_row(i))

func _make_cast_row(idx: int) -> Control:
	var a: Dictionary = cast_data[idx]
	var row := Panel.new()
	row.custom_minimum_size = Vector2(1280, 60)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.137, 0.153, 0.184, 1)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.208, 0.227, 0.263, 1)
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3
	sb.corner_radius_bottom_right = 3
	row.add_theme_stylebox_override("panel", sb)

	var idx_lbl := Label.new()
	idx_lbl.text = "%02d" % (idx + 1)
	idx_lbl.add_theme_font_size_override("font_size", 11)
	idx_lbl.add_theme_color_override("font_color", Color(0.541, 0.525, 0.502, 1))
	idx_lbl.position = Vector2(10, 20)
	idx_lbl.size = Vector2(28, 20)
	row.add_child(idx_lbl)

	var name_field := LineEdit.new()
	name_field.text = str(a.get("name", ""))
	name_field.placeholder_text = "名前"
	name_field.position = Vector2(44, 16)
	name_field.size = Vector2(100, 28)
	name_field.editable = editable
	name_field.text_changed.connect(func(t): cast_data[idx]["name"] = t)
	row.add_child(name_field)

	var romaji_field := LineEdit.new()
	romaji_field.text = str(a.get("romaji", ""))
	romaji_field.placeholder_text = "romaji"
	romaji_field.position = Vector2(152, 16)
	romaji_field.size = Vector2(120, 28)
	romaji_field.editable = editable
	romaji_field.text_changed.connect(func(t): cast_data[idx]["romaji"] = t)
	row.add_child(romaji_field)

	var gender_opt := OptionButton.new()
	gender_opt.add_item("女 ♀", 0)
	gender_opt.add_item("男 ♂", 1)
	gender_opt.selected = 0 if str(a.get("gender", "female")) == "female" else 1
	gender_opt.position = Vector2(280, 16)
	gender_opt.size = Vector2(80, 28)
	gender_opt.disabled = not editable
	gender_opt.item_selected.connect(func(i): cast_data[idx]["gender"] = ("female" if i == 0 else "male"))
	row.add_child(gender_opt)

	_add_slider(row, idx, "cooperative", "協調", int(a.get("cooperative", 50)), 370)
	_add_slider(row, idx, "aggressive",  "攻撃", int(a.get("aggressive",  50)), 620)
	_add_slider(row, idx, "curious",     "好奇", int(a.get("curious",     50)), 870)

	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.tooltip_text = "削除"
	del_btn.position = Vector2(1210, 16)
	del_btn.size = Vector2(40, 28)
	del_btn.disabled = not editable
	del_btn.pressed.connect(_on_delete_cast.bind(idx))
	row.add_child(del_btn)
	return row

func _add_slider(parent: Control, cast_idx: int, key: String, label: String, value: int, x: int) -> void:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.541, 0.525, 0.502, 1))
	lbl.position = Vector2(x, 6)
	lbl.size = Vector2(40, 16)
	parent.add_child(lbl)

	var val_lbl := Label.new()
	val_lbl.text = str(value)
	val_lbl.add_theme_font_size_override("font_size", 11)
	val_lbl.add_theme_color_override("font_color", Color(0.820, 0.808, 0.784, 1))
	val_lbl.position = Vector2(x + 180, 6)
	val_lbl.size = Vector2(40, 16)
	parent.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = value
	slider.position = Vector2(x, 26)
	slider.size = Vector2(220, 22)
	slider.editable = editable
	slider.value_changed.connect(func(v):
		cast_data[cast_idx][key] = int(v)
		val_lbl.text = str(int(v))
	)
	parent.add_child(slider)

func _on_delete_cast(idx: int) -> void:
	if idx < 0 or idx >= cast_data.size():
		return
	cast_data.remove_at(idx)
	_rebuild_cast_list()

func _on_add_cast_pressed() -> void:
	cast_data.append({
		"name": "",
		"romaji": "",
		"gender": "female",
		"cooperative": 50,
		"aggressive": 50,
		"curious": 50,
	})
	_rebuild_cast_list()

# --- save / cancel ---

func _on_save_pressed() -> void:
	if not editable:
		return
	var title := (get_node_or_null(^"UI/MetaPanel/TitleField") as LineEdit).text.strip_edges()
	if title == "":
		title = "untitled"
	var desc := (get_node_or_null(^"UI/MetaPanel/DescField") as LineEdit).text
	var seed_v := int((get_node_or_null(^"UI/MetaPanel/SeedField") as SpinBox).value)
	var tpd := int((get_node_or_null(^"UI/MetaPanel/TickPerDayField") as SpinBox).value)
	# base_config の world セクションを上書き
	if not base_config.has("world"):
		base_config["world"] = {}
	base_config["world"]["seed"] = seed_v
	base_config["world"]["size"] = 20
	base_config["world"]["tick_per_day"] = tpd
	# LLM provider / モデル / API key はテラリウムに埋め込まず、ランタイムで
	# config.json + config.local.json から都度注入する。これで 1 つのテラリウム
	# を複数 LLM で走らせて比較できる。
	base_config.erase("llm")
	var data := {
		"title": title,
		"description": desc,
		"world_size": 20,
		"world_seed": seed_v,
		"tick_per_day": tpd,
		"terrain_json": "",
		"cast_json": JSON.stringify(cast_data),
		"config_json": JSON.stringify(base_config),
	}
	if terrarium_id > 0:
		store.update_terrarium(terrarium_id, data)
	else:
		terrarium_id = store.create_terrarium(data)
	_goto_top()

func _on_back_pressed() -> void:
	_goto_top()

func _on_random_seed_pressed() -> void:
	var seed_field := get_node_or_null(^"UI/MetaPanel/SeedField") as SpinBox
	if seed_field != null:
		seed_field.value = float(randi())

func _goto_top() -> void:
	GameContext.selected_terrarium_id = -1
	get_tree().change_scene_to_file("res://scenes/TopPage.tscn")
