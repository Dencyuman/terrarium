extends Node2D

const BASE_TICK_SEC: float = 0.5  # 無 LLM 時の基準 tick。LLM 駆動時は LLM が bottleneck
const LOG_MAX: int = 50
const CHRONICLE_MAX: int = 200
const CHRONICLE_COMPACT_LIMIT: int = 12
const WORLD_FRAME_SIZE: float = 720.0   # 20*36
const WORLD_ORIG_LOCAL: Vector2 = Vector2(100, 4)   # WorldView の元位置

@export var world_view_path: NodePath = ^"ViewStack/WorldView"

var world: World
var agents: Array = []
var resources: ResourceField
var scheduler: Scheduler
var ollama: LLMClient   # 歴史的名前。Ollama / Anthropic のどちらかが入る。
var run_logger: TerrariumStore   # Phase 4.5 で DB バックエンド化。メソッド名は RunLogger 互換。
var current_terrarium_id: int = -1

var current_tab: int = 0
var view_nodes: Array = []
var tab_buttons: Array = []

var running: bool = false
var llm_enabled: bool = true
var speed_multiplier: float = 1.0
var accumulator: float = 0.0
var current_phase_name: String = "Idle"
var tick_in_progress: bool = false

var world_seed: int = 0
var world_size: int = 20
var tick_per_day: int = 10
var config: Dictionary

# LLM API コスト累積(per-run、リセット時にクリア)
var total_input_tokens: int = 0
var total_output_tokens: int = 0
var total_cost_usd: float = 0.0

# 各モデルの価格 (USD / 1M tokens)。不明なモデルは 0 扱い(無償=Ollama など)。
const PRICING := {
	"claude-haiku-4-5-20251001": {"in": 1.0, "out": 5.0},
	"claude-haiku-4-5":          {"in": 1.0, "out": 5.0},
	"gemini-3.1-flash-lite-preview": {"in": 0.25, "out": 1.5},
	"gemini-3.1-flash-lite":         {"in": 0.25, "out": 1.5},
	"gemini-3-flash-preview":        {"in": 0.5,  "out": 2.0},
	"gemini-3-flash":                {"in": 0.5,  "out": 2.0},
}

var log_entries: Array[String] = []
var chronicle_entries: Array[Dictionary] = []
var decide_progress_str: String = "—"
var selected_agent_id: int = -1
var ping_retry_timer: Timer
# tick 内で LLM が返したエージェントの部分結果(agent_id -> Action)
var pending_decisions: Dictionary = {}

func _ready() -> void:
	run_logger = TerrariumStore.new()
	if not run_logger.open():
		push_error("TerrariumStore open failed; persistence disabled")

	# GameContext 経由でテラリウム ID が渡されている場合は DB からロード。
	# 直接 Main.tscn を起動した場合(TopPage を経由しない)は default terrarium にフォールバック。
	var names_data: Dictionary
	var selected_id: int = GameContext.selected_terrarium_id if GameContext else -1
	if selected_id > 0 and run_logger != null:
		var t_row: Dictionary = run_logger.get_terrarium(selected_id)
		if not t_row.is_empty():
			config = JSON.parse_string(str(t_row.get("config_json", "{}")))
			if not (config is Dictionary):
				config = _load_config()
			var cast_raw = JSON.parse_string(str(t_row.get("cast_json", "[]")))
			names_data = {"agents": cast_raw if cast_raw is Array else []}
			run_logger.current_terrarium_id = selected_id
			run_logger.current_terrarium_title = str(t_row.get("title", ""))
			current_terrarium_id = selected_id
	if config == null or config.is_empty():
		# フォールバック経路: config.json + names.json 直読み + default terrarium 確保
		config = _load_config()
		names_data = _load_json("res://data/names.json")
		if run_logger != null:
			current_terrarium_id = run_logger.ensure_default_terrarium(config, names_data)

	world_seed = int(config["world"]["seed"])
	world_size = int(config["world"]["size"])
	tick_per_day = int(config["world"].get("tick_per_day", 10))

	var provider: String = str(config["llm"].get("provider", "ollama")).to_lower()
	match provider:
		"anthropic":
			ollama = AnthropicClient.new()
		"gemini":
			ollama = GeminiClient.new()
		_:
			ollama = OllamaClient.new()
	add_child(ollama)
	ollama.configure(config["llm"])
	print("[LLM] provider=%s" % provider)
	# 実行中 run 開始(最初の tick が走る前に run 行を作る)
	if run_logger != null and current_terrarium_id >= 0:
		var model_id: String = _current_model_id()
		run_logger.start_run(current_terrarium_id, provider, model_id)
	ollama.health_changed.connect(_on_health_changed)
	ollama.batch_progress.connect(_on_decide_progress)
	ollama.agent_decided.connect(_on_agent_decided_incremental)
	ollama.llm_request_sent.connect(_on_llm_request_sent)
	ollama.llm_response_received.connect(_on_llm_response_received)
	ollama.usage_recorded.connect(_on_usage_recorded)

	_initialize_simulation(names_data)
	_wire_views()
	_wire_tabs()
	_wire_playback()
	_wire_view_controls()
	_populate_ui(config)
	_select_tab(0)
	_update_tick_ui()

	var back_btn := get_node_or_null(^"UI/FooterBar/BackToTopBtn") as Button
	if back_btn != null:
		back_btn.pressed.connect(_on_back_to_top_pressed)

	# バックグラウンド ping(結果は footer に反映)
	_ping_ollama_async()
	# 接続失敗時に自動で再試行する Timer
	ping_retry_timer = Timer.new()
	ping_retry_timer.wait_time = 5.0
	ping_retry_timer.autostart = true
	ping_retry_timer.timeout.connect(_on_ping_retry_timer)
	add_child(ping_retry_timer)
	# フッターの接続ラベルをクリックで即再試行
	var conn_label := get_node_or_null(^"UI/FooterBar/ConnectionStatus") as Label
	if conn_label != null:
		conn_label.mouse_filter = Control.MOUSE_FILTER_STOP
		conn_label.gui_input.connect(_on_connection_label_clicked)
		conn_label.tooltip_text = "クリックで LLM プロバイダへの接続を再試行"

func _initialize_simulation(names_data: Dictionary) -> void:
	world = World.new(world_size, world_seed)
	resources = ResourceField.new(world, world_seed, config.get("resources", {}))
	agents = _spawn_agents(names_data["agents"], world, world_seed)
	scheduler = Scheduler.new(world, resources, agents, world_seed, tick_per_day)
	scheduler.configure_costs(config.get("costs", {}))
	scheduler.configure_relations(config.get("relations", {}))
	scheduler.phase_changed.connect(_on_phase_changed)
	scheduler.tick_completed.connect(_on_tick_completed_with_logging)
	scheduler.event_emitted.connect(_on_event_emitted)
	scheduler.action_applied.connect(_on_action_applied)

func _ping_ollama_async() -> void:
	await ollama.ping()

func _on_ping_retry_timer() -> void:
	# 既に ok のときは再試行しない(サーバ負荷軽減)
	if ollama == null:
		return
	if ollama.last_status == "ok":
		return
	# tick 中は再試行を控える(HTTPRequest の多重発行を避ける)
	if tick_in_progress:
		return
	_ping_ollama_async()

func _on_connection_label_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if ollama == null:
		return
	# 手動再試行: 一時的に "unknown" に戻して UI を更新
	ollama.reset_status_to_unknown()
	_ping_ollama_async()

func _process(delta: float) -> void:
	if not running or tick_in_progress:
		return
	var tick_time: float = BASE_TICK_SEC / max(0.01, speed_multiplier)
	accumulator += delta
	if accumulator < tick_time:
		return
	accumulator = 0.0
	_run_tick_async()

func _run_tick_async() -> void:
	tick_in_progress = true
	pending_decisions.clear()
	_clear_action_cards()
	scheduler.observe()
	var decisions: Array
	if llm_enabled and ollama != null:
		scheduler.enter_decide_phase()
		# LLM 経路: 応答が返ってくるごとに _on_agent_decided_incremental で
		# apply_bundle_for_agent を呼び、world と UI を即時更新する。
		# decide_all は全完了まで await する。
		decisions = await ollama.decide_all(agents, world, resources)
	else:
		# ローカル経路: 旧来どおり commit でまとめて apply
		decisions = scheduler.decide_local_all()
		scheduler.commit(decisions)
		_collect_log_non_incremental(decisions)
	scheduler.finalize_tick()
	tick_in_progress = false
	_refresh_runtime_ui(decisions)

# --- wiring ---

func _wire_views() -> void:
	var stack := get_node_or_null(^"ViewStack")
	if stack == null:
		return
	var world_view := stack.get_node_or_null(^"WorldView") as WorldView
	if world_view != null:
		world_view.set_world_and_agents(world, agents)
		world_view.set_resources(resources)
		if not world_view.agent_clicked.is_connected(_on_agent_clicked):
			world_view.agent_clicked.connect(_on_agent_clicked)
		if not world_view.zoom_requested.is_connected(_on_zoom_requested):
			world_view.zoom_requested.connect(_on_zoom_requested)
	var relation := stack.get_node_or_null(^"RelationView") as RelationGraphView
	if relation != null:
		relation.set_agents(agents)
		if not relation.agent_clicked.is_connected(_on_agent_clicked):
			relation.agent_clicked.connect(_on_agent_clicked)
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

func _wire_view_controls() -> void:
	var tb := get_node_or_null(^"UI/StatusBar/ViewControls/ToggleBubbles") as Button
	var ta := get_node_or_null(^"UI/StatusBar/ViewControls/ToggleArrows") as Button
	var rv := get_node_or_null(^"UI/StatusBar/ViewControls/ResetView") as Button
	if tb != null:
		tb.toggled.connect(_on_toggle_bubbles)
	if ta != null:
		ta.toggled.connect(_on_toggle_arrows)
	if rv != null:
		rv.pressed.connect(_on_reset_view)

func _on_toggle_bubbles(enabled: bool) -> void:
	var wv := get_node_or_null(world_view_path) as WorldView
	if wv != null:
		wv.set_bubbles_visible(enabled)

func _on_toggle_arrows(enabled: bool) -> void:
	var wv := get_node_or_null(world_view_path) as WorldView
	if wv != null:
		wv.set_arrows_visible(enabled)

func _on_reset_view() -> void:
	var wv := get_node_or_null(world_view_path) as WorldView
	if wv == null:
		return
	wv.scale = Vector2.ONE
	wv.position = WORLD_ORIG_LOCAL

func _on_zoom_requested(rect_local: Rect2) -> void:
	var wv := get_node_or_null(world_view_path) as WorldView
	if wv == null:
		return
	if rect_local.size.x < 1.0 or rect_local.size.y < 1.0:
		return
	var s: float = min(WORLD_FRAME_SIZE / rect_local.size.x, WORLD_FRAME_SIZE / rect_local.size.y)
	s = min(s, 8.0)   # 最大 8x
	var content := rect_local.size * s
	var pad := Vector2(
		(WORLD_FRAME_SIZE - content.x) / 2.0,
		(WORLD_FRAME_SIZE - content.y) / 2.0
	)
	wv.scale = Vector2(s, s)
	wv.position = WORLD_ORIG_LOCAL + pad - rect_local.position * s

func _wire_playback() -> void:
	var group := get_node_or_null(^"UI/StatusBar/SpeedGroup")
	if group == null:
		return
	var pause: Button = group.get_node_or_null(^"Pause") as Button
	var reset_btn: Button = group.get_node_or_null(^"Reset") as Button
	if pause != null:
		pause.disabled = false
		pause.text = "▶"
		pause.pressed.connect(_on_pause_toggled.bind(pause))
	if reset_btn != null:
		reset_btn.disabled = false
		reset_btn.pressed.connect(_on_reset_pressed)
	# LLM レイテンシが律速なので速度倍率は常に 1.0 固定
	speed_multiplier = 1.0

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

func _on_reset_pressed() -> void:
	running = false
	accumulator = 0.0
	log_entries.clear()
	chronicle_entries.clear()
	total_input_tokens = 0
	total_output_tokens = 0
	total_cost_usd = 0.0
	# 前 run を終了させ、新しい run 行を開始(reset = 別実験)
	_end_current_run()
	_update_cost_label()
	var pause := get_node_or_null(^"UI/StatusBar/SpeedGroup/Pause") as Button
	if pause != null:
		pause.text = "▶"
	var names_data: Dictionary = _load_json("res://data/names.json")
	_initialize_simulation(names_data)
	_wire_views()
	_update_tick_ui()
	_refresh_runtime_ui([])
	var list_body := get_node_or_null(^"UI/AgentListPanel/AgentListBody") as RichTextLabel
	if list_body != null:
		list_body.text = _format_agent_list()
	_update_speech_log_ui()
	_update_chronicle_ui()
	# 新しい run を開始
	if run_logger != null and current_terrarium_id >= 0:
		var p: String = str(config["llm"].get("provider", "ollama")).to_lower()
		run_logger.start_run(current_terrarium_id, p, _current_model_id())

func _on_back_to_top_pressed() -> void:
	running = false
	_end_current_run()
	if run_logger != null:
		run_logger.close()
	GameContext.selected_terrarium_id = -1
	get_tree().change_scene_to_file("res://scenes/TopPage.tscn")

func _end_current_run() -> void:
	if run_logger == null or scheduler == null:
		return
	var alive_count: int = 0
	for a in agents:
		if a.is_alive():
			alive_count += 1
	run_logger.end_run(scheduler.tick, alive_count, agents.size(), total_input_tokens, total_output_tokens, total_cost_usd)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_end_current_run()
		if run_logger != null:
			run_logger.close()

func _on_phase_changed(phase_name: String) -> void:
	current_phase_name = phase_name

func _on_tick_completed(_tick_no: int) -> void:
	pass

func _on_action_applied(agent_id: int, action: Action, snapshot: Dictionary) -> void:
	if run_logger == null:
		return
	var a := _get_agent_by_id(agent_id)
	var nm: String = a.agent_name if a != null else str(agent_id)
	run_logger.log_action(scheduler.tick, nm, {
		"kind": action.kind_label(),
		"succeeded": action.succeeded,
		"failure_note": action.failure_note,
		"direction": [action.direction.x, action.direction.y],
		"speech_text": action.speech_text,
		"speech_target_ids": action.speech_target_ids,
		"target_id": action.target_id,
		"reason": action.reason,
		"after_hunger": snapshot.get("hunger"),
		"after_health": snapshot.get("health"),
		"after_stamina": snapshot.get("stamina"),
		"after_pos": snapshot.get("pos"),
		"after_inventory_size": snapshot.get("inventory_size"),
	})

func _on_tick_completed_with_logging(tick_no: int) -> void:
	if run_logger == null:
		return
	var alive := 0
	for a in agents:
		if a.is_alive():
			alive += 1
	run_logger.log_tick_boundary(tick_no, scheduler.day, alive)
	# run 行の集計カラムを tick 境界で反映(途中で SQL 叩いても最新コストが見える)
	run_logger.update_run_stats(tick_no, alive, agents.size(), total_input_tokens, total_output_tokens, total_cost_usd)

func _on_event_emitted(event: Dictionary) -> void:
	chronicle_entries.push_back(event)
	while chronicle_entries.size() > CHRONICLE_MAX:
		chronicle_entries.pop_front()
	_update_chronicle_ui()
	if run_logger != null:
		run_logger.log_event(scheduler.tick, event)

func _on_llm_request_sent(agent_id: int, user_prompt: String) -> void:
	if run_logger == null:
		return
	var a := _get_agent_by_id(agent_id)
	var nm: String = a.agent_name if a != null else str(agent_id)
	run_logger.log_llm_request(scheduler.tick, nm, user_prompt)

func _on_llm_response_received(agent_id: int, body: String, latency_ms: int) -> void:
	if run_logger == null:
		return
	var a := _get_agent_by_id(agent_id)
	var nm: String = a.agent_name if a != null else str(agent_id)
	run_logger.log_llm_response(scheduler.tick, nm, body, latency_ms)

func _on_decide_progress(done: int, total: int, in_flight: int) -> void:
	decide_progress_str = "%d / %d  (in-flight %d)" % [done, total, in_flight]
	var phase_label := get_node_or_null(^"UI/ActionPanel/PhaseLabel") as Label
	if phase_label != null:
		phase_label.text = "フェーズ: Decide  ·  %s" % decide_progress_str

func _on_agent_decided_incremental(agent_id: int, actions: Array) -> void:
	# LLM 応答が届いた瞬間、world に即 apply して UI も同時に更新する。
	pending_decisions[agent_id] = actions
	var agent := _get_agent_by_id(agent_id)
	if agent == null:
		return
	var ordered: Array = scheduler.sanitize_bundle(actions)
	scheduler.apply_bundle_for_agent(agent, actions)
	# action のログは scheduler.action_applied シグナル経由で per-action に記録される
	# (ここでは bundle 全体のスナップショットは取らない)
	# UI をすべて decide ごとに更新する
	_append_action_card(agent, ordered)
	for act in ordered:
		# 物理的に失敗したアクション(TAKE だが食料なし等)はログに出さない。
		# ハーネス原則: 起きなかった事は観察できない。
		if act.kind == Action.Kind.WAIT:
			continue
		if not act.succeeded:
			continue
		_append_log_entry(agent, act)
	# ワールドビュー(位置・吹き出し・矢印・inventory dots)
	var world_view := get_node_or_null(world_view_path) as WorldView
	if world_view != null:
		world_view.set_current_tick(scheduler.tick)
		world_view.queue_redraw()
	# エージェントリスト(hp/hg の即時反映)
	var list_body := get_node_or_null(^"UI/AgentListPanel/AgentListBody") as RichTextLabel
	if list_body != null:
		list_body.text = _format_agent_list()
	# エージェント詳細(選択中なら、自分じゃなくても give/attack/embrace の影響で
	# inventory や relations が動いた可能性がある。常に redraw する)
	if selected_agent_id >= 0:
		_update_agent_detail()
	# 関係性グラフ(表示中のみ再描画)
	var relation_view := get_node_or_null(^"ViewStack/RelationView") as RelationGraphView
	if relation_view != null and relation_view.visible:
		relation_view.queue_redraw()

func _clear_action_cards() -> void:
	var panel := get_node_or_null(^"UI/ActionPanel") as Panel
	if panel == null:
		return
	for child in panel.get_children():
		if child.name.begins_with("Card"):
			panel.remove_child(child)
			child.queue_free()
	var empty := panel.get_node_or_null(^"EmptyState") as Label
	if empty != null:
		empty.visible = false

func _append_action_card(agent: Agent, actions: Array) -> void:
	var panel := get_node_or_null(^"UI/ActionPanel") as Panel
	if panel == null:
		return
	var existing_cards := []
	for child in panel.get_children():
		if child.name.begins_with("Card"):
			existing_cards.append(child)
	# bundle が全 wait なら "退屈" なので後回し
	var primary_kind: int = _primary_kind(actions)
	if existing_cards.size() >= 5:
		if primary_kind == Action.Kind.WAIT:
			return
		for ec in existing_cards:
			if ec.get_meta("kind", Action.Kind.WAIT) == Action.Kind.WAIT:
				panel.remove_child(ec)
				ec.queue_free()
				existing_cards.erase(ec)
				break
		if existing_cards.size() >= 5:
			return
	var idx := existing_cards.size()
	var card := _make_card_node(idx, agent, actions, primary_kind)
	panel.add_child(card)

func _primary_kind(actions: Array) -> int:
	# カード表示上の "primary" = SPEAK > MOVE > TAKE > WAIT
	var has_speak := false
	var has_move := false
	var has_take := false
	for a in actions:
		if a.kind == Action.Kind.SPEAK:
			has_speak = true
		elif a.kind == Action.Kind.MOVE:
			has_move = true
		elif a.kind == Action.Kind.TAKE:
			has_take = true
	if has_speak:
		return Action.Kind.SPEAK
	if has_move:
		return Action.Kind.MOVE
	if has_take:
		return Action.Kind.TAKE
	return Action.Kind.WAIT

func _make_card_node(idx: int, agent: Agent, actions: Array, primary_kind: int) -> VBoxContainer:
	var card := VBoxContainer.new()
	card.name = "Card%d_a%d" % [idx, agent.id]
	card.set_meta("kind", primary_kind)
	var card_w: int = 148
	var card_h: int = 86
	var left: int = 16 + idx * (card_w + 8)
	card.offset_left = left
	card.offset_top = 34
	card.offset_right = left + card_w
	card.offset_bottom = 34 + card_h
	card.custom_minimum_size = Vector2(card_w, card_h)

	var color: Color = agent.badge_color()
	var hex := "#%02X%02X%02X" % [int(color.r * 255), int(color.g * 255), int(color.b * 255)]
	# アクションラベルを結合("move + take + speak" 等)
	var action_labels: Array[String] = []
	var aggregate_reason: String = ""
	for a in actions:
		action_labels.append(a.kind_label())
		if aggregate_reason == "" and a.reason != "":
			aggregate_reason = a.reason
	var labels_str: String = " + ".join(action_labels)

	var header := RichTextLabel.new()
	header.bbcode_enabled = true
	header.fit_content = true
	header.scroll_active = false
	header.custom_minimum_size = Vector2(card_w, 18)
	header.text = "[color=%s]■[/color]  [b]%s[/b]" % [hex, agent.agent_name]
	header.add_theme_font_size_override("normal_font_size", 11)
	card.add_child(header)

	var acts_label := RichTextLabel.new()
	acts_label.bbcode_enabled = true
	acts_label.fit_content = true
	acts_label.scroll_active = false
	acts_label.custom_minimum_size = Vector2(card_w, 16)
	acts_label.text = "[color=#6acfb0]%s[/color]" % labels_str
	acts_label.add_theme_font_size_override("normal_font_size", 10)
	card.add_child(acts_label)

	var reason := RichTextLabel.new()
	reason.bbcode_enabled = true
	reason.fit_content = true
	reason.scroll_active = false
	reason.custom_minimum_size = Vector2(card_w, 44)
	var body_text: String = aggregate_reason if aggregate_reason != "" else "—"
	reason.text = "[color=#b4b0a8]%s[/color]" % body_text
	reason.add_theme_font_size_override("normal_font_size", 10)
	card.add_child(reason)
	return card

func _append_log_entry(agent: Agent, act: Action) -> void:
	if act.kind == Action.Kind.WAIT:
		return
	var color: Color = agent.badge_color()
	var hex := "#%02X%02X%02X" % [int(color.r * 255), int(color.g * 255), int(color.b * 255)]
	var tick_str := "[color=#6a6660]t%04d[/color]" % scheduler.tick
	var line: String
	match act.kind:
		Action.Kind.SPEAK:
			if act.speech_target_ids.size() > 0:
				# 指向性発話: 話者 → [相手1, 相手2, ...]
				var target_parts: Array[String] = []
				for tid in act.speech_target_ids:
					var target := _get_agent_by_id(tid)
					if target == null:
						continue
					var t_color: Color = target.badge_color()
					var t_hex := "#%02X%02X%02X" % [int(t_color.r * 255), int(t_color.g * 255), int(t_color.b * 255)]
					target_parts.append("[color=%s][b]%s[/b][/color]" % [t_hex, target.agent_name])
				if target_parts.is_empty():
					line = "%s  [color=%s][b]%s[/b][/color]  [color=#e6e4de]「%s」[/color]  [color=#6acfb0]speak[/color]" % [
						tick_str, hex, agent.agent_name, act.speech_text
					]
				else:
					line = "%s  [color=%s][b]%s[/b][/color] [color=#6a6660]→[/color] %s  [color=#e6e4de]「%s」[/color]" % [
						tick_str, hex, agent.agent_name, ",".join(target_parts), act.speech_text
					]
			else:
				line = "%s  [color=%s][b]%s[/b][/color]  [color=#e6e4de]「%s」[/color]  [color=#8a8680]— 独り言[/color]" % [
					tick_str, hex, agent.agent_name, act.speech_text
				]
		Action.Kind.MOVE:
			var dir := _direction_label(act.direction)
			line = "%s  [color=%s][b]%s[/b][/color]  [color=#8a8680]— move %s[/color]" % [
				tick_str, hex, agent.agent_name, dir
			]
		Action.Kind.TAKE:
			line = "%s  [color=%s][b]%s[/b][/color]  [color=#d0a050]— take 食料[/color]" % [
				tick_str, hex, agent.agent_name
			]
		Action.Kind.EAT:
			line = "%s  [color=%s][b]%s[/b][/color]  [color=#a7d088]— eat[/color]" % [
				tick_str, hex, agent.agent_name
			]
		Action.Kind.GIVE:
			var g_target := _get_agent_by_id(act.target_id)
			var g_name := g_target.agent_name if g_target != null else "?"
			line = "%s  [color=%s][b]%s[/b][/color] [color=#6acfb0]→ give →[/color] [b]%s[/b]" % [
				tick_str, hex, agent.agent_name, g_name
			]
		Action.Kind.ATTACK:
			var at_target := _get_agent_by_id(act.target_id)
			var at_name := at_target.agent_name if at_target != null else "?"
			line = "%s  [color=%s][b]%s[/b][/color] [color=#e07070]— attack →[/color] [b]%s[/b]" % [
				tick_str, hex, agent.agent_name, at_name
			]
		Action.Kind.EMBRACE:
			var em_target := _get_agent_by_id(act.target_id)
			var em_name := em_target.agent_name if em_target != null else "?"
			line = "%s  [color=%s][b]%s[/b][/color] [color=#e0a0c0]— embrace →[/color] [b]%s[/b]" % [
				tick_str, hex, agent.agent_name, em_name
			]
		_:
			return
	# 理由を sub-line として併記(空でなければ)
	var reason_text: String = act.reason.strip_edges()
	if reason_text != "":
		line += "\n       [color=#6a6660]└ %s[/color]" % reason_text
	log_entries.push_back(line)
	while log_entries.size() > LOG_MAX:
		log_entries.pop_front()
	_update_speech_log_ui()

func _collect_log_non_incremental(decisions: Array) -> void:
	if not pending_decisions.is_empty():
		return
	for i in agents.size():
		if i >= decisions.size():
			continue
		var bundle: Array = decisions[i]
		for act in bundle:
			_append_log_entry(agents[i], act)

func _on_health_changed(status: String) -> void:
	var conn_label := get_node_or_null(^"UI/FooterBar/ConnectionStatus") as Label
	if conn_label == null:
		return
	var provider_label: String = _provider_display_name()
	var target: String = _provider_target_display()
	var prefix: String
	var color: Color
	match status:
		"ok":
			prefix = "●  接続 %s" % provider_label
			color = Color(0.431, 0.855, 0.541, 1)
		"error":
			prefix = "✕  接続失敗 %s" % provider_label
			color = Color(0.88, 0.44, 0.44, 1)
		_:
			prefix = "○  確認中 %s" % provider_label
			color = Color(0.88, 0.72, 0.38, 1)
	conn_label.text = "%s  %s" % [prefix, target]
	conn_label.modulate = color

func _on_usage_recorded(in_tok: int, out_tok: int) -> void:
	total_input_tokens += in_tok
	total_output_tokens += out_tok
	var model_id: String = _current_model_id()
	if PRICING.has(model_id):
		var p: Dictionary = PRICING[model_id]
		total_cost_usd += float(in_tok) * float(p["in"]) / 1_000_000.0
		total_cost_usd += float(out_tok) * float(p["out"]) / 1_000_000.0
	_update_cost_label()

func _current_model_id() -> String:
	var p: String = str(config["llm"].get("provider", "ollama")).to_lower()
	match p:
		"anthropic": return str(config["llm"].get("anthropic_model", ""))
		"gemini":    return str(config["llm"].get("gemini_model", ""))
		_:           return str(config["llm"].get("model", ""))

func _update_cost_label() -> void:
	var label := get_node_or_null(^"UI/FooterBar/CostStatus") as Label
	if label == null:
		return
	var in_k := float(total_input_tokens) / 1000.0
	var out_k := float(total_output_tokens) / 1000.0
	if PRICING.has(_current_model_id()):
		label.text = "$%.4f  ·  in %.1fk / out %.1fk tok" % [total_cost_usd, in_k, out_k]
	else:
		# 無償(Ollama 等)はコスト省略してトークンだけ
		label.text = "in %.1fk / out %.1fk tok (local)" % [in_k, out_k]

func _provider_display_name() -> String:
	var p: String = str(config["llm"].get("provider", "ollama")).to_lower()
	match p:
		"anthropic": return "Anthropic"
		"gemini": return "Gemini"
		_: return "Ollama"

func _provider_target_display() -> String:
	var p: String = str(config["llm"].get("provider", "ollama")).to_lower()
	match p:
		"anthropic":
			return str(config["llm"].get("anthropic_model", "claude-haiku-4-5"))
		"gemini":
			return str(config["llm"].get("gemini_model", "gemini-3.1-flash-lite"))
		_:
			return _strip_scheme(str(config["llm"].get("endpoint", "")))

# --- UI refresh ---

func _refresh_runtime_ui(decisions: Array) -> void:
	var world_view := get_node_or_null(world_view_path) as WorldView
	if world_view != null:
		world_view.set_current_tick(scheduler.tick)
		world_view.queue_redraw()
	_update_tick_ui()
	# アクションカードは基本的に増分 (_on_agent_decided_incremental) で埋まっている。
	# ローカル経路で pending_decisions が空なら、ここでまとめて描く(fallback)
	if pending_decisions.is_empty():
		_update_action_cards(decisions)
	_update_speech_log_ui()
	if selected_agent_id >= 0:
		_update_agent_detail()
	var list_body := get_node_or_null(^"UI/AgentListPanel/AgentListBody") as RichTextLabel
	if list_body != null:
		list_body.text = _format_agent_list()

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
	if phase_label != null and current_phase_name != "Decide":
		phase_label.text = "フェーズ: %s  ·  —" % current_phase_name

# ローカル経路(LLM を通さない)用のカードまとめ描画
func _update_action_cards(decisions: Array) -> void:
	var panel := get_node_or_null(^"UI/ActionPanel") as Panel
	if panel == null:
		return
	for child in panel.get_children():
		if child.name.begins_with("Card"):
			panel.remove_child(child)
			child.queue_free()
	var empty := panel.get_node_or_null(^"EmptyState") as Label
	if empty != null:
		empty.visible = decisions.is_empty()
	if decisions.is_empty():
		return
	var selected: Array = []
	for i in agents.size():
		if selected.size() >= 5:
			break
		var a: Agent = agents[i]
		var bundle: Array = decisions[i] if i < decisions.size() else []
		if bundle.is_empty():
			continue
		var pk: int = _primary_kind(bundle)
		if pk != Action.Kind.WAIT:
			selected.append([a, bundle])
	for i in agents.size():
		if selected.size() >= 5:
			break
		var a: Agent = agents[i]
		var bundle: Array = decisions[i] if i < decisions.size() else []
		if bundle.is_empty():
			continue
		var already := false
		for s in selected:
			if s[0].id == a.id:
				already = true
				break
		if not already:
			selected.append([a, bundle])
	for i in selected.size():
		var a: Agent = selected[i][0]
		var bundle: Array = selected[i][1]
		var pk: int = _primary_kind(bundle)
		var card := _make_card_node(i, a, bundle, pk)
		panel.add_child(card)

func _build_card(parent: Panel, idx: int, agent: Agent, act: Action) -> void:
	var card := VBoxContainer.new()
	card.name = "Card%d" % idx
	var card_w: int = 148
	var card_h: int = 72
	var left: int = 16 + idx * (card_w + 8)
	card.offset_left = left
	card.offset_top = 40
	card.offset_right = left + card_w
	card.offset_bottom = 40 + card_h
	card.custom_minimum_size = Vector2(card_w, card_h)
	parent.add_child(card)

	var color: Color = agent.badge_color()
	var hex := "#%02X%02X%02X" % [int(color.r * 255), int(color.g * 255), int(color.b * 255)]
	var header := RichTextLabel.new()
	header.bbcode_enabled = true
	header.fit_content = true
	header.scroll_active = false
	header.custom_minimum_size = Vector2(card_w, 18)
	header.text = "[color=%s]■[/color]  [b]%s[/b]  [color=#8a8680]%s[/color]" % [hex, agent.agent_name, act.kind_label()]
	header.add_theme_font_size_override("normal_font_size", 11)
	card.add_child(header)

	var reason := RichTextLabel.new()
	reason.bbcode_enabled = true
	reason.fit_content = true
	reason.scroll_active = false
	reason.custom_minimum_size = Vector2(card_w, 52)
	var body_text: String = act.reason if act.reason != "" else _default_action_desc(act)
	reason.text = "[color=#b4b0a8]%s[/color]" % body_text
	reason.add_theme_font_size_override("normal_font_size", 10)
	card.add_child(reason)

func _default_action_desc(act: Action) -> String:
	match act.kind:
		Action.Kind.SPEAK:
			return "「%s」" % act.speech_text
		Action.Kind.MOVE:
			return "move (%d,%d)" % [act.direction.x, act.direction.y]
		Action.Kind.TAKE:
			return "take food"
		_:
			return "wait"

func _direction_label(d: Vector2i) -> String:
	match d:
		Vector2i(0, -1): return "↑"
		Vector2i(0, 1):  return "↓"
		Vector2i(1, 0):  return "→"
		Vector2i(-1, 0): return "←"
		Vector2i(1, -1): return "↗"
		Vector2i(-1, -1): return "↖"
		Vector2i(1, 1):  return "↘"
		Vector2i(-1, 1): return "↙"
		_: return "?"

func _update_chronicle_ui() -> void:
	# 右下のコンパクトパネル(最新 12 件)
	var compact := get_node_or_null(^"UI/EventChroniclePanel") as Panel
	if compact != null:
		var empty := compact.get_node_or_null(^"EmptyState") as Label
		var body := compact.get_node_or_null(^"ChronicleBody") as RichTextLabel
		if body == null:
			body = RichTextLabel.new()
			body.name = "ChronicleBody"
			body.bbcode_enabled = true
			body.scroll_active = true
			body.scroll_following = true
			body.offset_left = 16.0
			body.offset_top = 76.0
			body.offset_right = 292.0
			body.offset_bottom = 340.0
			body.add_theme_font_size_override("normal_font_size", 10)
			body.add_theme_color_override("default_color", Color(0.820, 0.808, 0.784, 1))
			compact.add_child(body)
		var has_events := not chronicle_entries.is_empty()
		if empty != null:
			empty.visible = not has_events
		body.visible = has_events
		if has_events:
			var compact_start: int = max(0, chronicle_entries.size() - CHRONICLE_COMPACT_LIMIT)
			var lines: Array[String] = []
			for i in range(compact_start, chronicle_entries.size()):
				lines.append(_chronicle_line(chronicle_entries[i]))
			body.text = "\n".join(lines)

func _chronicle_line(e: Dictionary) -> String:
	var icon: String = _chronicle_icon(e.get("kind", ""))
	var color: String = _chronicle_color(e.get("kind", ""))
	var tick_str := "[color=#6a6660]t%04d[/color]" % int(e.get("tick", 0))
	return "%s  [color=%s]%s[/color] %s" % [tick_str, color, icon, e.get("text", "")]

func _chronicle_icon(kind: String) -> String:
	match kind:
		"death":
			return "🕊"
		"attack":
			return "💢"
		"give":
			return "📤"
		"embrace":
			return "❤"
		_:
			return "·"

func _chronicle_color(kind: String) -> String:
	match kind:
		"death":
			return "#c0b8a8"
		"attack":
			return "#e07070"
		"give":
			return "#6acfb0"
		"embrace":
			return "#e0a0c0"
		_:
			return "#8a8680"

func _update_speech_log_ui() -> void:
	var panel := get_node_or_null(^"UI/LogPanel")
	if panel == null:
		return
	var empty := panel.get_node_or_null(^"EmptyState") as Label
	var body := panel.get_node_or_null(^"LogBody") as RichTextLabel
	var has_entries := not log_entries.is_empty()
	if empty != null:
		empty.visible = not has_entries
	if body != null:
		body.visible = has_entries
		if has_entries:
			# 二重改行で各エントリを視覚的なカードブロックとして分離
			body.text = "\n\n".join(log_entries)

# --- agent spawn / JSON ---

func _spawn_agents(defs: Array, w: World, seed_: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_ ^ 0xA5A5A5A5
	var agents_cfg: Dictionary = config.get("agents", {})
	var costs_cfg: Dictionary = config.get("costs", {})
	var capacity: int = int(agents_cfg.get("inventory_capacity", Agent.DEFAULT_INVENTORY_CAPACITY))
	var hunger_range: Array = agents_cfg.get("initial_hunger_range", [80, 80])
	var hunger_min: int = int(hunger_range[0])
	var hunger_max: int = int(hunger_range[1] if hunger_range.size() > 1 else hunger_range[0])
	var stamina_initial: int = int(costs_cfg.get("stamina_initial", Agent.STAMINA_INITIAL))
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
		a.inventory_capacity = capacity
		a.stamina = stamina_initial
		# 初期 hunger を range 内でランダム化(均一だと交換の必要性が生まれない)
		if hunger_min < hunger_max:
			a.hunger = rng.randi_range(hunger_min, hunger_max)
		else:
			a.hunger = hunger_min
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

# config.json を base として読み込み、config.local.json があれば deep merge する。
# 手元の実験用 override をここで上書きでき、tracked な config.json を汚さない。
func _load_config() -> Dictionary:
	var base: Variant = _load_json("res://data/config.json")
	if not (base is Dictionary):
		return {}
	var local_path := "res://data/config.local.json"
	if FileAccess.file_exists(local_path):
		var local: Variant = _load_json(local_path)
		if local is Dictionary:
			_deep_merge_dict(base, local)
			print("[Config] config.local.json を merge")
	return base

func _deep_merge_dict(dst: Dictionary, src: Dictionary) -> void:
	for key in src.keys():
		var src_val: Variant = src[key]
		if src_val is Dictionary and dst.has(key) and dst[key] is Dictionary:
			_deep_merge_dict(dst[key], src_val)
		else:
			dst[key] = src_val

func _populate_ui(cfg: Dictionary) -> void:
	var agent_header := get_node_or_null(^"UI/AgentListPanel/Header") as Label
	if agent_header != null:
		agent_header.text = "エージェント (%d)" % agents.size()

	var list_body := get_node_or_null(^"UI/AgentListPanel/AgentListBody") as RichTextLabel
	if list_body != null:
		list_body.text = _format_agent_list()
		if not list_body.meta_clicked.is_connected(_on_agent_meta_clicked):
			list_body.meta_clicked.connect(_on_agent_meta_clicked)

	var seed_label := get_node_or_null(^"UI/FooterBar/SeedStatus") as Label
	if seed_label != null:
		var parts: Array[String] = []
		if run_logger != null and run_logger.current_terrarium_title != "":
			parts.append("t:%s" % run_logger.current_terrarium_title)
		if run_logger != null and run_logger.current_run_id >= 0:
			parts.append("r%d" % run_logger.current_run_id)
		parts.append("seed 0x%08X" % world_seed)
		seed_label.text = "  ·  ".join(parts)

	var model_label := get_node_or_null(^"UI/FooterBar/ModelStatus") as Label
	if model_label != null:
		var p: String = str(cfg["llm"].get("provider", "ollama")).to_lower()
		var model_name: String
		var suffix: String
		if p == "anthropic":
			model_name = str(cfg["llm"].get("anthropic_model", ""))
			suffix = ""
		elif p == "gemini":
			model_name = str(cfg["llm"].get("gemini_model", ""))
			suffix = ""
		else:
			model_name = str(cfg["llm"].get("model", ""))
			var thinking := "ON" if bool(cfg["llm"].get("thinking_mode", false)) else "OFF"
			suffix = "  (thinking: %s)" % thinking
		model_label.text = "●  モデル  %s%s" % [model_name, suffix]

	var conn_label := get_node_or_null(^"UI/FooterBar/ConnectionStatus") as Label
	if conn_label != null:
		conn_label.text = "○  確認中 %s  %s" % [_provider_display_name(), _provider_target_display()]

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
		var row: String
		if a.is_alive():
			row = "[color=%s]■[/color]  [b]%s[/b]  [color=%s]%s[/color] [color=#8a8680]age %d · hp %d hg %d st %d[/color]" % [
				hex, a.agent_name, gender_color, sym, 20 + (a.id % 10), a.health, a.hunger, a.stamina,
			]
		else:
			# 死者: grey + 取り消し線風、meta クリックは残す(関係性参照のため)
			row = "[color=#4a4a4a]✕[/color]  [s][color=#707070]%s[/color][/s]  [color=#5a5a5a]%s[/color] [color=#5a5a5a]故人[/color]" % [
				a.agent_name, sym,
			]
		# 行全体をクリック可能に(meta = agent_id)
		lines.append("[url=%d]%s[/url]" % [a.id, row])
		lines.append("[color=#3a3e46]──[/color]")
	return "\n".join(lines)

func _strip_scheme(url: String) -> String:
	return url.replace("http://", "").replace("https://", "")

# --- agent selection / detail ---

func _on_agent_meta_clicked(meta: Variant) -> void:
	var id := int(str(meta))
	_toggle_select_agent(id)

func _on_agent_clicked(id: int) -> void:
	_toggle_select_agent(id)

func _toggle_select_agent(id: int) -> void:
	# 同じエージェントを再選択 → 解除
	if id == selected_agent_id:
		_select_agent(-1)
	else:
		_select_agent(id)

func _select_agent(id: int) -> void:
	selected_agent_id = id
	_update_agent_detail()
	var world_view := get_node_or_null(world_view_path) as WorldView
	if world_view != null:
		world_view.set_selected_agent(id)
	var relation := get_node_or_null(^"ViewStack/RelationView") as RelationGraphView
	if relation != null:
		relation.set_selected_agent(id)

func _get_agent_by_id(id: int) -> Agent:
	for a in agents:
		if a.id == id:
			return a
	return null

func _update_agent_detail() -> void:
	var panel := get_node_or_null(^"UI/AgentDetailPanel") as Panel
	if panel == null:
		return
	var empty_hint := panel.get_node_or_null(^"EmptyHint") as Label
	var empty_sub := panel.get_node_or_null(^"EmptySub") as Label
	var old_content := panel.get_node_or_null(^"DetailContent")
	if old_content != null:
		panel.remove_child(old_content)
		old_content.queue_free()

	if selected_agent_id < 0:
		if empty_hint != null:
			empty_hint.text = "エージェント詳細"
		if empty_sub != null:
			empty_sub.visible = true
		return

	var a := _get_agent_by_id(selected_agent_id)
	if a == null:
		return
	if empty_sub != null:
		empty_sub.visible = false
	if empty_hint != null:
		empty_hint.text = "エージェント詳細"

	var content := VBoxContainer.new()
	content.name = "DetailContent"
	content.offset_left = 16
	content.offset_top = 44
	content.offset_right = 252
	content.offset_bottom = 420
	content.custom_minimum_size = Vector2(236, 376)
	content.add_theme_constant_override("separation", 6)
	panel.add_child(content)

	var color: Color = a.badge_color()
	var hex := "#%02X%02X%02X" % [int(color.r * 255), int(color.g * 255), int(color.b * 255)]
	var sym := "♀" if a.gender == "female" else "♂"

	var head := RichTextLabel.new()
	head.bbcode_enabled = true
	head.fit_content = true
	head.scroll_active = false
	head.custom_minimum_size = Vector2(236, 26)
	head.add_theme_font_size_override("normal_font_size", 13)
	head.text = "[color=%s]●[/color]  [b]%s[/b]  %s  [color=#8a8680]Age %d  G1[/color]" % [
		hex, a.agent_name, sym, 20 + (a.id % 10),
	]
	content.add_child(head)

	var stats := RichTextLabel.new()
	stats.bbcode_enabled = true
	stats.fit_content = true
	stats.scroll_active = false
	stats.custom_minimum_size = Vector2(236, 72)
	stats.add_theme_font_size_override("normal_font_size", 11)
	stats.text = "[color=#8a8680]空腹度[/color]  %s  [b]%d[/b]/100\n[color=#8a8680]体力  [/color]  %s  [b]%d[/b]/100\n[color=#8a8680]元気度[/color]  %s  [b]%d[/b]/100" % [
		_bar(a.hunger, 100, 14), a.hunger,
		_bar(a.health, 100, 14), a.health,
		_bar(a.stamina, 100, 14), a.stamina,
	]
	content.add_child(stats)

	var personality := RichTextLabel.new()
	personality.bbcode_enabled = true
	personality.fit_content = true
	personality.scroll_active = false
	personality.custom_minimum_size = Vector2(236, 60)
	personality.add_theme_font_size_override("normal_font_size", 11)
	personality.text = "[color=#8a8680]性格[/color]\n  協調 %s %d\n  攻撃 %s %d\n  好奇 %s %d" % [
		_bar(a.cooperative, 100, 12), a.cooperative,
		_bar(a.aggressive, 100, 12), a.aggressive,
		_bar(a.curious, 100, 12), a.curious,
	]
	content.add_child(personality)

	var last_action := RichTextLabel.new()
	last_action.bbcode_enabled = true
	last_action.fit_content = true
	last_action.scroll_active = false
	last_action.custom_minimum_size = Vector2(236, 56)
	last_action.add_theme_font_size_override("normal_font_size", 11)
	var action_name := _action_name(a.last_action_kind)
	var reason_text := a.last_action_reason if a.last_action_reason != "" else "—"
	last_action.text = "[color=#8a8680]直近の行動[/color]\n  [color=#b4b0a8]%s[/color]\n  [color=#6a6660]%s[/color]" % [action_name, reason_text]
	content.add_child(last_action)

	var loc := RichTextLabel.new()
	loc.bbcode_enabled = true
	loc.fit_content = true
	loc.scroll_active = false
	loc.custom_minimum_size = Vector2(236, 40)
	loc.add_theme_font_size_override("normal_font_size", 11)
	var terrain_names: Array[String] = ["草地", "水域", "森", "岩場"]
	var terrain_name: String = terrain_names[world.get_terrain(a.grid_pos.x, a.grid_pos.y)]
	loc.text = "[color=#8a8680]場所[/color]  (%d, %d) %s" % [a.grid_pos.x, a.grid_pos.y, terrain_name]
	content.add_child(loc)

	# inventory
	var inv := RichTextLabel.new()
	inv.bbcode_enabled = true
	inv.fit_content = true
	inv.scroll_active = false
	inv.custom_minimum_size = Vector2(236, 28)
	inv.add_theme_font_size_override("normal_font_size", 11)
	var inv_slots: Array[String] = []
	for k in a.inventory_capacity:
		if k < a.inventory.size():
			inv_slots.append("[color=#d0a050]●[/color]")
		else:
			inv_slots.append("[color=#3a3e46]○[/color]")
	inv.text = "[color=#8a8680]所持[/color]  %s  [color=#8a8680]%d/%d[/color]" % [
		" ".join(inv_slots), a.inventory.size(), a.inventory_capacity
	]
	content.add_child(inv)

	# top relations
	var rels_raw: Array = a.top_relations(3, agents)
	if rels_raw.size() > 0:
		var rels_label := RichTextLabel.new()
		rels_label.bbcode_enabled = true
		rels_label.fit_content = true
		rels_label.scroll_active = false
		rels_label.custom_minimum_size = Vector2(236, 72)
		rels_label.add_theme_font_size_override("normal_font_size", 11)
		var lines: Array[String] = ["[color=#8a8680]関係 top 3[/color]"]
		for entry in rels_raw:
			var n: String = entry["name"]
			var aff: int = int(entry["affection"])
			var trust_v: int = int(entry["trust"])
			var tag_color := "#6acfb0" if aff > 0 else ("#e07070" if aff < 0 else "#8a8680")
			var sign := "+" if aff > 0 else ""
			lines.append("  [color=%s][b]%s[/b][/color]  aff %s%d · trust %d" % [tag_color, n, sign, aff, trust_v])
		rels_label.text = "\n".join(lines)
		content.add_child(rels_label)

func _bar(value: int, mx: int, width: int) -> String:
	var filled := int(round(float(value) / float(mx) * float(width)))
	filled = clamp(filled, 0, width)
	var bar := "[color=#6acfb0]"
	for i in filled:
		bar += "■"
	bar += "[/color][color=#3a3e46]"
	for i in range(width - filled):
		bar += "■"
	bar += "[/color]"
	return bar

func _action_name(kind: int) -> String:
	match kind:
		Action.Kind.WAIT:
			return "wait"
		Action.Kind.MOVE:
			return "move"
		Action.Kind.TAKE:
			return "take"
		Action.Kind.SPEAK:
			return "speak"
		_:
			return "—"
