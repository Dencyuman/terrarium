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
# map paint 用:
# - has_custom_terrain = true なら terrain は手動指定、保存時に terrain_json に書き込む
# - false なら保存時 terrain_json を空にして seed 生成にフォールバック
var has_custom_terrain: bool = false
var _map_canvas = null
# EnvPanel で編集する環境パラメータ(過酷さ)。config 由来の既定値から始まり、
# ユーザーが変更したら base_config にマージして保存される。
const ENV_SPECS := [
	# [path, label, suffix, min, max, step, hint]
	[["costs", "eat_hunger_restore"],        "食料1回の回復量",      "", 1.0, 100.0, 1.0,      "大きいほど楽"],
	[["costs", "tick_base_hunger"],          "tick あたり基礎代謝",  "", 0.0, 10.0, 1.0,       "大きいほど過酷"],
	[["costs", "starving_health_drain"],     "飢餓時 HP ドレイン",    "", 0.0, 50.0, 1.0,       "大きいほど過酷"],
	[["costs", "move_hunger"],               "move の hunger コスト(草/森)","", 0.0, 10.0, 1.0,   "大きいほど過酷"],
	[["costs", "rock_move_hunger"],          "move の hunger コスト(岩)","",    0.0, 20.0, 1.0,   "岩上の移動コスト。草/森より高いのが想定"],
	[["resources", "initial_spawn", "grass"],  "草地 食料スポーン率", "", 0.0, 1.0, 0.01,     "0..1"],
	[["resources", "initial_spawn", "forest"], "森 食料スポーン率",   "", 0.0, 1.0, 0.01,     "0..1 (草地より高いのが想定)"],
	[["resources", "regen_per_tick", "grass"], "草地 食料再生/tick",  "", 0.0, 0.1, 0.001,    "0..0.1"],
	[["resources", "regen_per_tick", "forest"],"森 食料再生/tick",    "", 0.0, 0.1, 0.001,    "0..0.1 (草地より高いのが想定)"],
]
var _env_fields: Dictionary = {}   # path_key("a.b.c") -> SpinBox

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

	_map_canvas = get_node_or_null(^"UI/MapPanel/MapCanvas")
	_wire_palette()
	_wire_fill_row()
	var size_field := get_node_or_null(^"UI/MetaPanel/SizeField") as SpinBox
	if size_field != null:
		size_field.value_changed.connect(_on_size_changed)
	_build_env_panel()

	terrarium_id = GameContext.selected_terrarium_id if GameContext else -1
	if terrarium_id > 0 and store != null:
		_load_existing(terrarium_id)
	else:
		_load_template()
	_rebuild_cast_list()
	_apply_readonly_if_needed()
	_map_canvas.tile_painted.connect(_on_tile_painted)

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
	var size_loaded: int = clampi(int(row.get("world_size", 20)), 3, 20)
	(get_node_or_null(^"UI/MetaPanel/SizeField") as SpinBox).value = float(size_loaded)
	if _map_canvas != null:
		_map_canvas.set_grid_size(size_loaded)
	var cfg = JSON.parse_string(str(row.get("config_json", "{}")))
	base_config = cfg if cfg is Dictionary else {}
	var cast_raw = JSON.parse_string(str(row.get("cast_json", "[]")))
	cast_data = []
	if cast_raw is Array:
		for a in cast_raw:
			if a is Dictionary:
				cast_data.append(a.duplicate(true))
	# terrain: 空文字なら未指定扱い、存在するなら canvas に反映
	var terr_s: String = str(row.get("terrain_json", ""))
	if terr_s != "":
		var parsed = JSON.parse_string(terr_s)
		if parsed is Array and _map_canvas != null:
			_map_canvas.set_terrain(parsed)
			has_custom_terrain = true
	_refresh_env_panel_values()
	_update_constraint_label()

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
	var template_size: int = clampi(int(base_config.get("world", {}).get("size", 20)), 3, 20)
	(get_node_or_null(^"UI/MetaPanel/SizeField") as SpinBox).value = float(template_size)
	if _map_canvas != null:
		_map_canvas.set_grid_size(template_size)
	_refresh_env_panel_values()
	_update_constraint_label()

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
	var size_f := get_node_or_null(^"UI/MetaPanel/SizeField") as SpinBox
	if size_f != null: size_f.editable = false
	# map canvas も入力停止、パレット / fill ボタン群も disabled
	if _map_canvas != null:
		_map_canvas.set_enabled(false)
	for btn_name in ["Grass", "Water", "Forest", "Rock"]:
		var b := get_node_or_null("UI/MapPanel/Palette/" + btn_name) as Button
		if b != null: b.disabled = true
	for btn_name in ["FillGrass", "FillWater", "GenFromSeed", "ClearMap"]:
		var b := get_node_or_null("UI/MapPanel/FillRow/" + btn_name) as Button
		if b != null: b.disabled = true

# --- map paint wiring ---

func _wire_palette() -> void:
	var names := ["Grass", "Water", "Forest", "Rock"]
	for i in range(names.size()):
		var btn := get_node_or_null("UI/MapPanel/Palette/" + names[i]) as Button
		if btn == null:
			continue
		btn.pressed.connect(_on_palette_pressed.bind(i, names))

func _on_palette_pressed(idx: int, names: Array) -> void:
	if _map_canvas != null:
		_map_canvas.set_brush(idx)
	# トグルグループ的に選択表示(他を外す)
	for i in range(names.size()):
		var b := get_node_or_null("UI/MapPanel/Palette/" + names[i]) as Button
		if b != null:
			b.button_pressed = (i == idx)
	_update_terrain_info(idx)

# 選択中テレインの物理的な性質をラベルに反映。config 値を読んで具体数値を表示する。
func _update_terrain_info(idx: int) -> void:
	var info := get_node_or_null(^"UI/MapPanel/TerrainInfo") as Label
	if info == null:
		return
	var spawn_grass: float = float(_get_nested(base_config, ["resources", "initial_spawn", "grass"], 0.06))
	var spawn_forest: float = float(_get_nested(base_config, ["resources", "initial_spawn", "forest"], 0.12))
	var regen_grass: float = float(_get_nested(base_config, ["resources", "regen_per_tick", "grass"], 0.003))
	var regen_forest: float = float(_get_nested(base_config, ["resources", "regen_per_tick", "forest"], 0.008))
	var move_hunger: int = int(_get_nested(base_config, ["costs", "move_hunger"], 2))
	var rock_hunger: int = int(_get_nested(base_config, ["costs", "rock_move_hunger"], 4))
	match idx:
		0:
			info.text = "草 (grass): move hunger -%d / 食料 spawn %.2f・regen %.3f/tick / 通行可" % [move_hunger, spawn_grass, regen_grass]
		1:
			info.text = "水 (water): 通行不可(move は impassable で silent fail)。食料は発生しない。"
		2:
			info.text = "森 (forest): move hunger -%d / 食料 spawn %.2f・regen %.3f/tick / 通行可(草より食料豊富)" % [move_hunger, spawn_forest, regen_forest]
		3:
			info.text = "岩 (rock): move hunger -%d(草/森より高い)/ 食料は発生しない / 通行可" % [rock_hunger]
		_:
			info.text = ""

func _wire_fill_row() -> void:
	var g := get_node_or_null(^"UI/MapPanel/FillRow/FillGrass") as Button
	var w := get_node_or_null(^"UI/MapPanel/FillRow/FillWater") as Button
	var s := get_node_or_null(^"UI/MapPanel/FillRow/GenFromSeed") as Button
	var c := get_node_or_null(^"UI/MapPanel/FillRow/ClearMap") as Button
	if g != null: g.pressed.connect(func():
		_map_canvas.fill_all(0)
		has_custom_terrain = true
	)
	if w != null: w.pressed.connect(func():
		_map_canvas.fill_all(1)
		has_custom_terrain = true
	)
	if s != null: s.pressed.connect(_on_gen_from_seed_pressed)
	if c != null: c.pressed.connect(func():
		_map_canvas.fill_all(0)
		has_custom_terrain = false
	)

# 現在の seed / size を使って Perlin ベースで地形を生成してキャンバスに表示する。
# これを押した時点で has_custom_terrain = true(変更されたものとして保存される)。
func _on_gen_from_seed_pressed() -> void:
	var seed_v := int((get_node_or_null(^"UI/MetaPanel/SeedField") as SpinBox).value)
	var w := World.new(20, seed_v)
	_map_canvas.set_terrain(w.terrain.duplicate(true))
	has_custom_terrain = true

func _on_tile_painted(_x: int, _y: int) -> void:
	has_custom_terrain = true

# --- env panel ---

func _build_env_panel() -> void:
	var grid := get_node_or_null(^"UI/EnvPanel/Grid") as GridContainer
	if grid == null:
		return
	for child in grid.get_children():
		child.queue_free()
	for spec in ENV_SPECS:
		var path: Array = spec[0]
		var label_text: String = spec[1]
		var minv: float = spec[3]
		var maxv: float = spec[4]
		var step: float = spec[5]
		var hint: String = spec[6]
		var lbl := Label.new()
		lbl.text = label_text
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", Color(0.820, 0.808, 0.784, 1))
		lbl.custom_minimum_size = Vector2(160, 28)
		grid.add_child(lbl)
		var spin := SpinBox.new()
		spin.min_value = minv
		spin.max_value = maxv
		spin.step = step
		spin.value = float(_get_nested(base_config, path, minv))
		spin.custom_minimum_size = Vector2(120, 28)
		spin.editable = editable
		var key := _path_key(path)
		_env_fields[key] = spin
		spin.value_changed.connect(func(v): _set_nested(base_config, path, v))
		grid.add_child(spin)
		# hint は 2 列目(label pair 内)だが GridContainer 4 列構成なので 3, 4 列目にヒント用空 Label(省略可)
		if hint != "":
			var hint_lbl := Label.new()
			hint_lbl.text = hint
			hint_lbl.add_theme_font_size_override("font_size", 9)
			hint_lbl.add_theme_color_override("font_color", Color(0.541, 0.525, 0.502, 1))
			hint_lbl.custom_minimum_size = Vector2(160, 28)
			grid.add_child(hint_lbl)
		else:
			grid.add_child(Control.new())
		grid.add_child(Control.new())  # 4 列目の spacer

func _refresh_env_panel_values() -> void:
	# base_config が外部から差し替えられた場合(既存テラリウムをロード等)に呼ぶ。
	for spec in ENV_SPECS:
		var path: Array = spec[0]
		var key := _path_key(path)
		var spin: SpinBox = _env_fields.get(key, null)
		if spin == null:
			continue
		var default_min: float = float(spec[3])
		spin.value = float(_get_nested(base_config, path, default_min))

func _get_nested(d: Dictionary, path: Array, default_val) -> Variant:
	var cur: Variant = d
	for k in path:
		if not (cur is Dictionary) or not cur.has(k):
			return default_val
		cur = cur[k]
	return cur

func _set_nested(d: Dictionary, path: Array, v) -> void:
	var cur: Dictionary = d
	for i in range(path.size() - 1):
		var k = path[i]
		if not cur.has(k) or not (cur[k] is Dictionary):
			cur[k] = {}
		cur = cur[k]
	cur[path[-1]] = v

func _path_key(path: Array) -> String:
	return ".".join(path)

# --- size / constraint ---

func _on_size_changed(v: float) -> void:
	var n: int = int(v)
	if _map_canvas != null:
		_map_canvas.set_grid_size(n)
	_update_constraint_label()

func _current_size() -> int:
	var f := get_node_or_null(^"UI/MetaPanel/SizeField") as SpinBox
	return int(f.value) if f != null else 20

func _constraint_ok(n_size: int, n_cast: int) -> bool:
	# マップ面積 ≥ エージェント数 × 4(= 1 人あたり 4 タイル確保)
	# エージェント数の下限 2、上限 20 も合わせて判定する。
	if n_cast < 2 or n_cast > 20:
		return false
	if n_size < 3 or n_size > 20:
		return false
	return (n_size * n_size) >= (n_cast * 4)

func _update_constraint_label() -> void:
	var lbl := get_node_or_null(^"UI/MetaPanel/ConstraintLabel") as Label
	if lbl == null:
		return
	var n_size: int = _current_size()
	var n_cast: int = cast_data.size()
	var ok: bool = _constraint_ok(n_size, n_cast)
	var area: int = n_size * n_size
	var need: int = n_cast * 4
	if ok:
		lbl.text = "制約 OK: map %d² = %d タイル  ≥  %d 人 × 4 = %d" % [n_size, area, n_cast, need]
		lbl.add_theme_color_override("font_color", Color(0.431, 0.855, 0.541, 1))
	else:
		var reason: String
		if n_cast < 2:
			reason = "エージェント数は最低 2 人"
		elif n_cast > 20:
			reason = "エージェント数は最大 20 人"
		elif area < need:
			reason = "map %d² = %d < %d 人 × 4 = %d(タイル不足)" % [n_size, area, n_cast, need]
		else:
			reason = "サイズ範囲エラー"
		lbl.text = "制約 NG: %s" % reason
		lbl.add_theme_color_override("font_color", Color(0.88, 0.44, 0.44, 1))
	# 保存可否も同期
	var save_btn := get_node_or_null(^"UI/SaveBtn") as Button
	if save_btn != null and editable:
		save_btn.disabled = not ok

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
	row.custom_minimum_size = Vector2(720, 60)
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
	idx_lbl.position = Vector2(8, 20)
	idx_lbl.size = Vector2(22, 20)
	row.add_child(idx_lbl)

	var name_field := LineEdit.new()
	name_field.text = str(a.get("name", ""))
	name_field.placeholder_text = "名前"
	name_field.position = Vector2(34, 16)
	name_field.size = Vector2(76, 28)
	name_field.editable = editable
	name_field.text_changed.connect(func(t): cast_data[idx]["name"] = t)
	row.add_child(name_field)

	var romaji_field := LineEdit.new()
	romaji_field.text = str(a.get("romaji", ""))
	romaji_field.placeholder_text = "romaji"
	romaji_field.position = Vector2(114, 16)
	romaji_field.size = Vector2(86, 28)
	romaji_field.editable = editable
	romaji_field.text_changed.connect(func(t): cast_data[idx]["romaji"] = t)
	row.add_child(romaji_field)

	var gender_opt := OptionButton.new()
	gender_opt.add_item("女 ♀", 0)
	gender_opt.add_item("男 ♂", 1)
	gender_opt.selected = 0 if str(a.get("gender", "female")) == "female" else 1
	gender_opt.position = Vector2(204, 16)
	gender_opt.size = Vector2(66, 28)
	gender_opt.disabled = not editable
	gender_opt.item_selected.connect(func(i): cast_data[idx]["gender"] = ("female" if i == 0 else "male"))
	row.add_child(gender_opt)

	var slider_w: int = 112
	_add_slider(row, idx, "cooperative", "協調", int(a.get("cooperative", 50)), 278, slider_w)
	_add_slider(row, idx, "aggressive",  "攻撃", int(a.get("aggressive",  50)), 402, slider_w)
	_add_slider(row, idx, "curious",     "好奇", int(a.get("curious",     50)), 526, slider_w)

	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.tooltip_text = "削除"
	del_btn.position = Vector2(660, 16)
	del_btn.size = Vector2(38, 28)
	del_btn.disabled = not editable
	del_btn.pressed.connect(_on_delete_cast.bind(idx))
	row.add_child(del_btn)
	return row

func _add_slider(parent: Control, cast_idx: int, key: String, label: String, value: int, x: int, w: int = 112) -> void:
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.541, 0.525, 0.502, 1))
	lbl.position = Vector2(x, 6)
	lbl.size = Vector2(30, 16)
	parent.add_child(lbl)

	var val_lbl := Label.new()
	val_lbl.text = str(value)
	val_lbl.add_theme_font_size_override("font_size", 11)
	val_lbl.add_theme_color_override("font_color", Color(0.820, 0.808, 0.784, 1))
	val_lbl.position = Vector2(x + w - 28, 6)
	val_lbl.size = Vector2(28, 16)
	parent.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = value
	slider.position = Vector2(x, 26)
	slider.size = Vector2(w, 22)
	slider.editable = editable
	slider.value_changed.connect(func(v):
		cast_data[cast_idx][key] = int(v)
		val_lbl.text = str(int(v))
	)
	parent.add_child(slider)

func _on_delete_cast(idx: int) -> void:
	if idx < 0 or idx >= cast_data.size():
		return
	if cast_data.size() <= 2:
		# 最小 2 人制約のため削除拒否(UI 上で即フィードバック)
		_flash_constraint("エージェント数は最低 2 人必要です")
		return
	cast_data.remove_at(idx)
	_rebuild_cast_list()
	_update_constraint_label()

func _on_add_cast_pressed() -> void:
	if cast_data.size() >= 20:
		_flash_constraint("エージェント数は最大 20 人です")
		return
	# 追加後に constraint が通るかも事前チェック(map² < (cast+1)*4 なら拒否)
	var next_count: int = cast_data.size() + 1
	if not _constraint_ok(_current_size(), next_count):
		_flash_constraint("追加するとマップサイズ² < %d 人×4 になるため不可(マップを大きくしてください)" % next_count)
		return
	cast_data.append({
		"name": "",
		"romaji": "",
		"gender": "female",
		"cooperative": 50,
		"aggressive": 50,
		"curious": 50,
	})
	_rebuild_cast_list()
	_update_constraint_label()

func _flash_constraint(msg: String) -> void:
	var lbl := get_node_or_null(^"UI/MetaPanel/ConstraintLabel") as Label
	if lbl == null:
		return
	lbl.text = "制約 NG: %s" % msg
	lbl.add_theme_color_override("font_color", Color(0.88, 0.44, 0.44, 1))

# --- save / cancel ---

func _on_save_pressed() -> void:
	if not editable:
		return
	var n_size: int = _current_size()
	var n_cast: int = cast_data.size()
	if not _constraint_ok(n_size, n_cast):
		_update_constraint_label()
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
	base_config["world"]["size"] = n_size
	base_config["world"]["tick_per_day"] = tpd
	# LLM provider / モデル / API key はテラリウムに埋め込まず、ランタイムで
	# config.json + config.local.json から都度注入する。これで 1 つのテラリウム
	# を複数 LLM で走らせて比較できる。
	base_config.erase("llm")
	# terrain: has_custom_terrain が立っていれば canvas の内容を保存、
	# 立っていなければ空文字にして Sim 側で seed 生成させる。
	var terrain_str: String = ""
	if has_custom_terrain and _map_canvas != null:
		terrain_str = JSON.stringify(_map_canvas.get_terrain())
	var data := {
		"title": title,
		"description": desc,
		"world_size": n_size,
		"world_seed": seed_v,
		"tick_per_day": tpd,
		"terrain_json": terrain_str,
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
