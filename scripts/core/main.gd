extends Node2D

@export var world_view_path: NodePath = ^"ViewStack/WorldView"

var world: World
var agents: Array = []
var current_tab: int = 0
var view_nodes: Array = []
var tab_buttons: Array = []

func _ready() -> void:
	var config: Dictionary = _load_json("res://data/config.json")
	var names_data: Dictionary = _load_json("res://data/names.json")

	var world_seed: int = int(config["world"]["seed"])
	var world_size: int = int(config["world"]["size"])
	world = World.new(world_size, world_seed)
	agents = _spawn_agents(names_data["agents"], world, world_seed)

	_wire_views()
	_wire_tabs()
	_populate_ui(config)
	_select_tab(0)

func _wire_views() -> void:
	var stack := get_node_or_null(^"ViewStack")
	if stack == null:
		return
	var world_view := stack.get_node_or_null(^"WorldView") as WorldView
	if world_view != null:
		world_view.set_world_and_agents(world, agents)
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
			# invisible の間にキューされた描画要求は落ちている場合があるため、
			# 可視化時に再リクエストして確実に再描画させる。
			view.queue_redraw()
	for i in tab_buttons.size():
		if tab_buttons[i] != null:
			tab_buttons[i].button_pressed = (i == idx)
	# ActionPanel は 世界 タブのみ(Phase 1 では中身空だが可視性だけ連動)
	var action_panel := get_node_or_null(^"UI/ActionPanel") as Panel
	if action_panel != null:
		action_panel.visible = (idx == 0)

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

func _populate_ui(config: Dictionary) -> void:
	var pop_value := get_node_or_null(^"UI/StatusBar/PopValue") as Label
	if pop_value != null:
		pop_value.text = "%d  (±0)" % agents.size()

	var agent_header := get_node_or_null(^"UI/AgentListPanel/Header") as Label
	if agent_header != null:
		agent_header.text = "エージェント (%d)" % agents.size()

	var list_body := get_node_or_null(^"UI/AgentListPanel/AgentListBody") as RichTextLabel
	if list_body != null:
		list_body.text = _format_agent_list()

	var seed_label := get_node_or_null(^"UI/FooterBar/SeedStatus") as Label
	if seed_label != null:
		seed_label.text = "OBSERVER MODE  ·  seed 0x%08X" % int(config["world"]["seed"])

	var model_label := get_node_or_null(^"UI/FooterBar/ModelStatus") as Label
	if model_label != null:
		var thinking := "ON" if bool(config["llm"]["thinking_mode"]) else "OFF"
		model_label.text = "●  モデル  %s  (thinking: %s)" % [config["llm"]["model"], thinking]

	var conn_label := get_node_or_null(^"UI/FooterBar/ConnectionStatus") as Label
	if conn_label != null:
		conn_label.text = "●  接続 Ollama  %s" % _strip_scheme(config["llm"]["endpoint"])

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
