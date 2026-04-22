extends Node2D

# 1 run の全イベント(action + event)を時系列表示。
# agent / 失敗アクション表示の 2 フィルタをサポート。

var store: TerrariumStore
var run_id: int = -1
var agent_names: Array = []
var selected_agent: String = ""
var show_failed: bool = false

func _ready() -> void:
	store = TerrariumStore.new()
	if not store.open():
		push_error("[RunTimeline] TerrariumStore open failed")
	run_id = GameContext.selected_run_id if GameContext else -1
	var back := get_node_or_null(^"UI/BackBtn") as Button
	if back != null:
		back.pressed.connect(_on_back_pressed)
	var af := get_node_or_null(^"UI/FilterPanel/AgentFilter") as OptionButton
	if af != null:
		af.item_selected.connect(_on_agent_selected)
	var fc := get_node_or_null(^"UI/FilterPanel/FailedCheck") as CheckBox
	if fc != null:
		fc.toggled.connect(_on_failed_toggled)
	_populate_header()
	_populate_agent_filter()
	_populate_body()

func _exit_tree() -> void:
	if store != null:
		store.close()

func _populate_header() -> void:
	var title := get_node_or_null(^"UI/TitleLabel") as Label
	var sub := get_node_or_null(^"UI/SubLabel") as Label
	var r: Dictionary = store.get_run(run_id) if store != null else {}
	if r.is_empty():
		if title != null: title.text = "run %d  (不明)" % run_id
		return
	var tt: String = str(r.get("terrarium_title", "?"))
	if title != null:
		title.text = "run r%d · %s" % [run_id, tt]
	if sub != null:
		sub.text = "%s → %s · %d tick · 生存 %d/%d · %s %s · $%.4f · in %.1fk / out %.1fk tok" % [
			str(r.get("started_at", "")),
			(str(r.get("ended_at", "")) if str(r.get("ended_at", "")) != "" else "(中断)"),
			int(r.get("final_tick", 0)),
			int(r.get("final_alive", 0)), int(r.get("final_total", 0)),
			str(r.get("provider", "")), str(r.get("model", "")),
			float(r.get("cost_usd", 0.0)),
			float(r.get("input_tokens", 0)) / 1000.0,
			float(r.get("output_tokens", 0)) / 1000.0,
		]

func _populate_agent_filter() -> void:
	var af := get_node_or_null(^"UI/FilterPanel/AgentFilter") as OptionButton
	if af == null:
		return
	af.clear()
	af.add_item("全員", 0)
	agent_names = store.list_run_agent_names(run_id) if store != null else []
	var i: int = 1
	for name in agent_names:
		af.add_item(name, i)
		i += 1
	af.selected = 0

func _populate_body() -> void:
	var body := get_node_or_null(^"UI/ListPanel/Scroll/Body") as RichTextLabel
	var count_lbl := get_node_or_null(^"UI/FilterPanel/CountLbl") as Label
	if body == null:
		return
	var events: Array = store.list_events_for_run(run_id, selected_agent, show_failed) if store != null else []
	if count_lbl != null:
		count_lbl.text = "%d 件" % events.size()
	if events.is_empty():
		body.text = "[color=#707070]このフィルタに合致するイベントはありません。[/color]"
		return
	var lines: Array[String] = []
	for e in events:
		lines.append(_format_event(e))
	body.text = "\n".join(lines)

func _format_event(e: Dictionary) -> String:
	var tick_s: String = "[color=#6a6660]t%04d[/color]" % int(e["tick"])
	var agent_name: String = str(e.get("agent_name", ""))
	var kind: String = str(e.get("kind", ""))
	var type_s: String = str(e.get("type", ""))
	var data = JSON.parse_string(str(e.get("data_json", "{}")))
	if not (data is Dictionary):
		data = {}
	if type_s == "event":
		return _format_event_row(tick_s, kind, data)
	# type == action
	return _format_action_row(tick_s, agent_name, kind, data)

func _format_action_row(tick_s: String, agent_name: String, kind: String, d: Dictionary) -> String:
	var name_hex := "#b4b0a8"
	var head := "%s  [b][color=%s]%s[/color][/b]" % [tick_s, name_hex, agent_name]
	var reason: String = str(d.get("reason", ""))
	var reason_tail := ""
	if reason != "":
		reason_tail = "    [color=#6a6660]└ %s[/color]" % reason
	var succeeded: bool = bool(d.get("succeeded", true))
	var fail_note: String = str(d.get("failure_note", ""))
	var fail_tag := ""
	if not succeeded and fail_note != "":
		fail_tag = "  [color=#a06060](失敗: %s)[/color]" % fail_note
	match kind:
		"move":
			var dir = d.get("direction", [0, 0])
			return "%s  [color=#8a8680]move %s[/color]%s%s" % [head, _dir_label(dir), fail_tag, reason_tail]
		"take":
			return "%s  [color=#d0a050]take 食料[/color]%s%s" % [head, fail_tag, reason_tail]
		"eat":
			return "%s  [color=#a7d088]eat[/color]%s%s" % [head, fail_tag, reason_tail]
		"give":
			return "%s  [color=#6acfb0]→ give → 他者[/color]%s%s" % [head, fail_tag, reason_tail]
		"attack":
			return "%s  [color=#e07070]— attack →[/color]%s%s" % [head, fail_tag, reason_tail]
		"embrace":
			return "%s  [color=#e0a0c0]— embrace →[/color]%s%s" % [head, fail_tag, reason_tail]
		"look":
			var ldir = d.get("direction", [0, 0])
			return "%s  [color=#a7c5e0]眺める %s[/color]%s%s" % [head, _dir_label(ldir), fail_tag, reason_tail]
		"speak":
			var text = str(d.get("speech_text", ""))
			var tids = d.get("speech_target_ids", [])
			var target_s := ""
			if tids is Array and tids.size() > 0:
				target_s = " [color=#6a6660]→ %d 人に[/color]" % tids.size()
			return "%s%s  [color=#e6e4de]「%s」[/color]%s" % [head, target_s, text, reason_tail]
		"wait":
			return "%s  [color=#6a6660]wait[/color]%s" % [head, reason_tail]
	return "%s  %s%s" % [head, kind, reason_tail]

func _format_event_row(tick_s: String, kind: String, d: Dictionary) -> String:
	var text: String = str(d.get("text", ""))
	var color := "#8a8680"
	var icon := "·"
	match kind:
		"death":   color = "#c0b8a8"; icon = "🕊"
		"attack":  color = "#e07070"; icon = "💢"
		"give":    color = "#6acfb0"; icon = "📤"
		"embrace": color = "#e0a0c0"; icon = "❤"
	return "%s  [color=%s][b]%s[/b]  %s[/color]" % [tick_s, color, icon, text]

func _dir_label(dir) -> String:
	if not (dir is Array) or dir.size() < 2:
		return "?"
	var v := Vector2i(int(dir[0]), int(dir[1]))
	match v:
		Vector2i(0, -1): return "↑"
		Vector2i(0, 1):  return "↓"
		Vector2i(1, 0):  return "→"
		Vector2i(-1, 0): return "←"
		Vector2i(1, -1): return "↗"
		Vector2i(-1, -1): return "↖"
		Vector2i(1, 1):  return "↘"
		Vector2i(-1, 1): return "↙"
	return "?"

func _on_agent_selected(idx: int) -> void:
	if idx == 0:
		selected_agent = ""
	else:
		selected_agent = agent_names[idx - 1]
	_populate_body()

func _on_failed_toggled(v: bool) -> void:
	show_failed = v
	_populate_body()

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/RunBrowser.tscn")
