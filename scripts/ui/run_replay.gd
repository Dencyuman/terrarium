extends Node2D

# ビジュアルリプレイ。tick スライダで世界状態を巻き戻せる。
# 再生中は SpeedSlider の値 (tick/sec) でスライダを自動進行させる。
# 必要な再構成:
#   - World: terrarium.terrain_json があればそれ、無ければ world_seed から Perlin 生成
#   - ResourceField: snapshot.resources_food で食料グリッドを上書き
#   - agents: terrarium.cast_json から生成、snapshot.agents で state を復元

const WORLD_FRAME_SIZE: float = 720.0

var store: TerrariumStore
var run_id: int = -1
var snapshot_ticks: Array = []   # 利用可能な tick のリスト
var world: World
var resources: ResourceField
var agents: Array = []
var world_view: WorldView

var playing: bool = false
var play_accum: float = 0.0

func _ready() -> void:
	store = TerrariumStore.new()
	if not store.open():
		push_error("[RunReplay] TerrariumStore open failed")
	run_id = GameContext.selected_run_id if GameContext else -1
	world_view = get_node_or_null(^"ViewStack/WorldView") as WorldView
	var back := get_node_or_null(^"UI/BackBtn") as Button
	if back != null:
		back.pressed.connect(_on_back_pressed)
	var play := get_node_or_null(^"UI/ControlsPanel/PlayBtn") as Button
	if play != null:
		play.pressed.connect(_on_play_toggled)
	var slider := get_node_or_null(^"UI/ControlsPanel/Slider") as HSlider
	if slider != null:
		slider.value_changed.connect(_on_slider_changed)
	_init_world()
	_load_ticks()
	_update_header()
	if snapshot_ticks.size() > 0:
		_apply_tick(snapshot_ticks[0])

func _exit_tree() -> void:
	if store != null:
		store.close()

func _process(delta: float) -> void:
	if not playing or snapshot_ticks.is_empty():
		return
	var speed_slider := get_node_or_null(^"UI/ControlsPanel/SpeedSlider") as HSlider
	var speed: float = speed_slider.value if speed_slider != null else 4.0
	play_accum += delta * speed
	if play_accum < 1.0:
		return
	play_accum -= 1.0
	var slider := get_node_or_null(^"UI/ControlsPanel/Slider") as HSlider
	if slider == null:
		return
	var next_val: int = int(slider.value) + 1
	if next_val > int(slider.max_value):
		playing = false
		_update_play_btn()
		return
	slider.value = next_val   # triggers _on_slider_changed

func _init_world() -> void:
	var r: Dictionary = store.get_run(run_id)
	if r.is_empty():
		return
	var terrarium_id: int = int(r.get("terrarium_id", -1))
	if terrarium_id < 0:
		return
	var t_row: Dictionary = store.get_terrarium(terrarium_id)
	if t_row.is_empty():
		return
	var size_val: int = int(t_row.get("world_size", 20))
	var seed_val: int = int(t_row.get("world_seed", 0))
	world = World.new(size_val, seed_val)
	var terr_s: String = str(t_row.get("terrain_json", ""))
	if terr_s != "":
		var parsed = JSON.parse_string(terr_s)
		if parsed is Array:
			world.apply_explicit_terrain(parsed)
	var cfg = JSON.parse_string(str(t_row.get("config_json", "{}")))
	var res_cfg: Dictionary = {}
	if cfg is Dictionary and cfg.has("resources"):
		res_cfg = cfg["resources"]
	resources = ResourceField.new(world, seed_val, res_cfg)
	# cast から agent オブジェクト群を作る(姿形は復元スナップショットで上書きされる)
	agents = []
	var cast_raw = JSON.parse_string(str(t_row.get("cast_json", "[]")))
	if cast_raw is Array:
		for i in range(cast_raw.size()):
			var d = cast_raw[i]
			if not (d is Dictionary):
				continue
			var a := Agent.new(i)
			a.agent_name = str(d.get("name", ""))
			a.romaji = str(d.get("romaji", ""))
			a.gender = str(d.get("gender", "female"))
			a.cooperative = int(d.get("cooperative", 50))
			a.aggressive = int(d.get("aggressive", 50))
			a.curious = int(d.get("curious", 50))
			agents.append(a)
	if world_view != null:
		world_view.set_world_and_agents(world, agents)
		world_view.set_resources(resources)
		# 20 × TILE(36) を 720 にフィット
		var fit_scale: float = WORLD_FRAME_SIZE / float(max(1, world.size) * 36)
		world_view.scale = Vector2(fit_scale, fit_scale)

func _load_ticks() -> void:
	snapshot_ticks = store.list_snapshot_ticks(run_id) if store != null else []
	var slider := get_node_or_null(^"UI/ControlsPanel/Slider") as HSlider
	var status := get_node_or_null(^"UI/StatusLabel") as Label
	if snapshot_ticks.is_empty():
		if slider != null:
			slider.editable = false
		if status != null:
			status.text = "この run にはマップ再生用のスナップショットがありません(Phase 4.5.C 以前の run は未対応)。"
		return
	if slider != null:
		slider.min_value = float(snapshot_ticks[0])
		slider.max_value = float(snapshot_ticks[-1])
		slider.value = float(snapshot_ticks[0])
		slider.editable = true
	if status != null:
		status.text = "%d 件のスナップショット (tick %d → %d)" % [snapshot_ticks.size(), snapshot_ticks[0], snapshot_ticks[-1]]

func _update_header() -> void:
	var r: Dictionary = store.get_run(run_id)
	var title := get_node_or_null(^"UI/TitleLabel") as Label
	var sub := get_node_or_null(^"UI/SubLabel") as Label
	if title != null:
		title.text = "マップ再生  r%d · %s" % [run_id, str(r.get("terrarium_title", "?"))]
	if sub != null and not r.is_empty():
		sub.text = "%d tick · 生存 %d/%d · %s %s · $%.4f" % [
			int(r.get("final_tick", 0)),
			int(r.get("final_alive", 0)), int(r.get("final_total", 0)),
			str(r.get("provider", "")), str(r.get("model", "")),
			float(r.get("cost_usd", 0.0)),
		]

func _apply_tick(tick_v: int) -> void:
	var snap: Dictionary = store.load_tick_snapshot(run_id, tick_v)
	if snap.is_empty():
		# 厳密な tick がない場合は直前の tick にフォールバック
		var best: int = -1
		for t in snapshot_ticks:
			if t <= tick_v:
				best = t
		if best >= 0:
			snap = store.load_tick_snapshot(run_id, best)
	if snap.is_empty():
		return
	# エージェント動的状態を上書き
	var agent_dumps = snap.get("agents", [])
	if agent_dumps is Array:
		var by_id: Dictionary = {}
		for a in agents:
			by_id[a.id] = a
		for dump in agent_dumps:
			if not (dump is Dictionary):
				continue
			var aid: int = int(dump.get("id", -1))
			if not by_id.has(aid):
				continue
			_apply_agent_snapshot(by_id[aid], dump)
	# 食料グリッド
	var food = snap.get("resources_food", null)
	if food is Array and resources != null and food.size() == resources.size:
		resources.food = food
	if world_view != null:
		world_view.current_tick = tick_v
		world_view.queue_redraw()
	var tick_lbl := get_node_or_null(^"UI/ControlsPanel/TickLabel") as Label
	if tick_lbl != null:
		tick_lbl.text = "t%04d" % tick_v

func _apply_agent_snapshot(a: Agent, dump: Dictionary) -> void:
	var pos_arr = dump.get("grid_pos", null)
	if pos_arr is Array and pos_arr.size() >= 2:
		a.grid_pos = Vector2i(int(pos_arr[0]), int(pos_arr[1]))
	a.hunger = int(dump.get("hunger", a.hunger))
	a.health = int(dump.get("health", a.health))
	a.stamina = int(dump.get("stamina", a.stamina))
	var inv = dump.get("inventory", [])
	if inv is Array:
		a.inventory.clear()
		for item in inv:
			a.inventory.append(str(item))
	a.inventory_capacity = int(dump.get("inventory_capacity", a.inventory_capacity))
	a.last_speech = str(dump.get("last_speech", ""))
	a.last_speech_tick = int(dump.get("last_speech_tick", -1))
	var tids = dump.get("last_speech_target_ids", [])
	a.last_speech_target_ids = []
	if tids is Array:
		for t in tids:
			a.last_speech_target_ids.append(int(t))

func _on_slider_changed(v: float) -> void:
	_apply_tick(int(v))

func _on_play_toggled() -> void:
	if snapshot_ticks.is_empty():
		return
	playing = not playing
	play_accum = 0.0
	_update_play_btn()

func _update_play_btn() -> void:
	var btn := get_node_or_null(^"UI/ControlsPanel/PlayBtn") as Button
	if btn != null:
		btn.text = "⏸" if playing else "▶"

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/RunBrowser.tscn")
