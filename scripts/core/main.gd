extends Node2D

const BASE_TICK_SEC: float = 0.5  # 1x の 1 tick 実時間(Phase 2 無 LLM 想定)

@export var world_view_path: NodePath = ^"ViewStack/WorldView"

var world: World
var agents: Array = []
var resources: ResourceField
var scheduler: Scheduler

var current_tab: int = 0
var view_nodes: Array = []
var tab_buttons: Array = []

var running: bool = false
var speed_multiplier: float = 1.0
var accumulator: float = 0.0
var current_phase_name: String = "Idle"

var world_seed: int = 0
var world_size: int = 20
var tick_per_day: int = 10
var config: Dictionary

func _ready() -> void:
	config = _load_json("res://data/config.json")
	var names_data: Dictionary = _load_json("res://data/names.json")

	world_seed = int(config["world"]["seed"])
	world_size = int(config["world"]["size"])
	tick_per_day = int(config["world"].get("tick_per_day", 10))

	_initialize_simulation(names_data)
	_wire_views()
	_wire_tabs()
	_wire_playback()
	_populate_ui(config)
	_select_tab(0)
	_update_tick_ui()

func _initialize_simulation(names_data: Dictionary) -> void:
	world = World.new(world_size, world_seed)
	resources = ResourceField.new(world, world_seed)
	agents = _spawn_agents(names_data["agents"], world, world_seed)
	scheduler = Scheduler.new(world, resources, agents, world_seed, tick_per_day)
	scheduler.phase_changed.connect(_on_phase_changed)
	scheduler.tick_completed.connect(_on_tick_completed)

func _process(delta: float) -> void:
	if not running:
		return
	var tick_time: float = BASE_TICK_SEC / max(0.01, speed_multiplier)
	accumulator += delta
	# 1 フレームあたり進められる tick 数に上限を設けてフリーズ回避
	var budget: int = 4
	while accumulator >= tick_time and budget > 0:
		accumulator -= tick_time
		budget -= 1
		scheduler.step()
	_refresh_runtime_ui()

# --- wiring ---

func _wire_views() -> void:
	var stack := get_node_or_null(^"ViewStack")
	if stack == null:
		return
	var world_view := stack.get_node_or_null(^"WorldView") as WorldView
	if world_view != null:
		world_view.set_world_and_agents(world, agents)
		world_view.set_resources(resources)
	var relation := stack.get_node_or_null(^"RelationView") as RelationGraphView
	if relation != null:
		relation.set_agents(agents)
	var family := stack.get_node_or_null(^"FamilyView") as FamilyTreeView
	if family != null:
		family.set_agents(agents)
	var chronicle := stack.get_node_or_null(^"ChronicleView") as EventChroniclePageView
	if chronicle != null:
		chronicle.set_agents(agents)
	view_nodes = [world_view, relation, family, chronicle]

func _wire_tabs() -> void:
	var tabs_parent := get_node_or_null(^"UI/StatusBar/Tabs")
	if tabs_parent == null:
		return
	tab_buttons = [
		tabs_parent.get_node_or_null(^"Tab1") as Button,
		tabs_parent.get_node_or_null(^"Tab2") as Button,
		tabs_parent.get_node_or_null(^"Tab3") as Button,
		tabs_parent.get_node_or_null(^"Tab4") as Button,
	]
	for i in tab_buttons.size():
		var btn: Button = tab_buttons[i]
		if btn == null:
			continue
		btn.pressed.connect(_on_tab_pressed.bind(i))

func _wire_playback() -> void:
	var group := get_node_or_null(^"UI/StatusBar/SpeedGroup")
	if group == null:
		return
	var pause: Button = group.get_node_or_null(^"Pause") as Button
	var spd1: Button = group.get_node_or_null(^"Spd1") as Button
	var spd2: Button = group.get_node_or_null(^"Spd2") as Button
	var spd5: Button = group.get_node_or_null(^"Spd5") as Button
	var reset_btn: Button = group.get_node_or_null(^"Reset") as Button
	if pause != null:
		pause.disabled = false
		pause.text = "▶"
		pause.pressed.connect(_on_pause_toggled.bind(pause))
	if spd1 != null:
		spd1.disabled = false
		spd1.pressed.connect(_on_speed_changed.bind(1.0, [spd1, spd2, spd5]))
	if spd2 != null:
		spd2.disabled = false
		spd2.pressed.connect(_on_speed_changed.bind(2.0, [spd1, spd2, spd5]))
	if spd5 != null:
		spd5.disabled = false
		spd5.pressed.connect(_on_speed_changed.bind(5.0, [spd1, spd2, spd5]))
	if reset_btn != null:
		reset_btn.disabled = false
		reset_btn.pressed.connect(_on_reset_pressed)
	_highlight_speed([spd1, spd2, spd5], 0)

# --- handlers ---

func _on_tab_pressed(idx: int) -> void:
	_select_tab(idx)

func _select_tab(idx: int) -> void:
	current_tab = idx
	for i in view_nodes.size():
		var view: Node2D = view_nodes[i]
		if view == null:
			continue
		view.visible = (i == idx)
		if i == idx:
			view.queue_redraw()
	for i in tab_buttons.size():
		if tab_buttons[i] != null:
			tab_buttons[i].button_pressed = (i == idx)
	var action_panel := get_node_or_null(^"UI/ActionPanel") as Panel
	if action_panel != null:
		action_panel.visible = (idx == 0)

func _on_pause_toggled(btn: Button) -> void:
	running = not running
	btn.text = "II" if running else "▶"
	accumulator = 0.0

func _on_speed_changed(mult: float, btns: Array) -> void:
	speed_multiplier = mult
	var idx := 0
	if mult == 2.0:
		idx = 1
	elif mult == 5.0:
		idx = 2
	_highlight_speed(btns, idx)

func _highlight_speed(btns: Array, active_idx: int) -> void:
	for i in btns.size():
		var b: Button = btns[i]
		if b == null:
			continue
		b.button_pressed = (i == active_idx)

func _on_reset_pressed() -> void:
	running = false
	accumulator = 0.0
	var pause := get_node_or_null(^"UI/StatusBar/SpeedGroup/Pause") as Button
	if pause != null:
		pause.text = "▶"
	var names_data: Dictionary = _load_json("res://data/names.json")
	_initialize_simulation(names_data)
	_wire_views()
	_update_tick_ui()
	_refresh_runtime_ui()
	var list_body := get_node_or_null(^"UI/AgentListPanel/AgentListBody") as RichTextLabel
	if list_body != null:
		list_body.text = _format_agent_list()

func _on_phase_changed(phase_name: String) -> void:
	current_phase_name = phase_name

func _on_tick_completed(_tick_no: int) -> void:
	# tick 毎に重い描画は避け、_process で refresh する
	pass

# --- UI refresh ---

func _refresh_runtime_ui() -> void:
	var world_view := get_node_or_null(world_view_path) as WorldView
	if world_view != null:
		world_view.queue_redraw()
	_update_tick_ui()

func _update_tick_ui() -> void:
	var tick_value := get_node_or_null(^"UI/StatusBar/TickValue") as Label
	if tick_value != null:
		tick_value.text = "%04d" % scheduler.tick
	var day_value := get_node_or_null(^"UI/StatusBar/DayValue") as Label
	if day_value != null:
		day_value.text = "%03d" % scheduler.day
	var alive_count := 0
	for a in agents:
		if a.is_alive():
			alive_count += 1
	var pop_value := get_node_or_null(^"UI/StatusBar/PopValue") as Label
	if pop_value != null:
		pop_value.text = "%d  (%s%d)" % [alive_count, "±" if alive_count == agents.size() else "-", agents.size() - alive_count]
	var action_header := get_node_or_null(^"UI/ActionPanel/Header") as Label
	if action_header != null:
		action_header.text = "現在のアクション (Tick %04d)" % scheduler.tick
	var phase_label := get_node_or_null(^"UI/ActionPanel/PhaseLabel") as Label
	if phase_label != null:
		phase_label.text = "フェーズ: %s  ·  並列処理: —" % current_phase_name

# --- agent spawn / JSON ---

func _spawn_agents(defs: Array, w: World, seed_: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_ ^ 0xA5A5A5A5
	var out: Array = []
	var placed: Dictionary = {}
	for i in defs.size():
		var d: Dictionary = defs[i]
		var a := Agent.new(i)
		a.agent_name = d["name"]
		a.romaji = d["romaji"]
		a.gender = d["gender"]
		a.cooperative = int(d["cooperative"])
		a.aggressive = int(d["aggressive"])
		a.curious = int(d["curious"])
		a.grid_pos = _pick_spawn(w, rng, placed)
		placed[a.grid_pos] = true
		out.append(a)
	return out

func _pick_spawn(w: World, rng: RandomNumberGenerator, placed: Dictionary) -> Vector2i:
	for _try in 1000:
		var x := rng.randi_range(0, w.size - 1)
		var y := rng.randi_range(0, w.size - 1)
		var p := Vector2i(x, y)
		if placed.has(p):
			continue
		if not w.is_passable(x, y):
			continue
		return p
	return Vector2i(0, 0)

func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("cannot open %s" % path)
		return null
	var text: String = f.get_as_text()
	f.close()
	return JSON.parse_string(text)

func _populate_ui(cfg: Dictionary) -> void:
	var agent_header := get_node_or_null(^"UI/AgentListPanel/Header") as Label
	if agent_header != null:
		agent_header.text = "エージェント (%d)" % agents.size()

	var list_body := get_node_or_null(^"UI/AgentListPanel/AgentListBody") as RichTextLabel
	if list_body != null:
		list_body.text = _format_agent_list()

	var seed_label := get_node_or_null(^"UI/FooterBar/SeedStatus") as Label
	if seed_label != null:
		seed_label.text = "OBSERVER MODE  ·  seed 0x%08X" % world_seed

	var model_label := get_node_or_null(^"UI/FooterBar/ModelStatus") as Label
	if model_label != null:
		var thinking := "ON" if bool(cfg["llm"]["thinking_mode"]) else "OFF"
		model_label.text = "●  モデル  %s  (thinking: %s)" % [cfg["llm"]["model"], thinking]

	var conn_label := get_node_or_null(^"UI/FooterBar/ConnectionStatus") as Label
	if conn_label != null:
		conn_label.text = "●  接続 Ollama  %s" % _strip_scheme(cfg["llm"]["endpoint"])

func _format_agent_list() -> String:
	var lines: Array = []
	for i in range(agents.size()):
		var a: Agent = agents[i]
		var color: Color = a.badge_color()
		var hex := "#%02X%02X%02X" % [
			int(color.r * 255),
			int(color.g * 255),
			int(color.b * 255),
		]
		var sym := "♀" if a.gender == "female" else "♂"
		var gender_color := "#d28ac8" if a.gender == "female" else "#7da8e0"
		lines.append(
			"[color=%s]■[/color]  [b]%s[/b]  [color=%s]%s[/color] [color=#8a8680]age %d · g1[/color]" % [
				hex, a.agent_name, gender_color, sym, 20 + (a.id % 10),
			]
		)
		lines.append("[color=#4a4e56]──[/color]")
	return "\n".join(lines)

func _strip_scheme(url: String) -> String:
	return url.replace("http://", "").replace("https://", "")
