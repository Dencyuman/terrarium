class_name RunLogger
extends RefCounted

# 1 起動 = 1 ディレクトリ。runs/<ISO8601>/log.jsonl に全イベントを追記。
# .gitignore 済み。`jq . < log.jsonl | less` で読める。

var run_dir: String = ""
var log_path: String = ""
var file: FileAccess = null

func _init() -> void:
	var ts: String = _iso_timestamp()
	run_dir = "runs/%s" % ts
	_ensure_runs_dir()
	log_path = "%s/log.jsonl" % run_dir
	file = FileAccess.open(log_path, FileAccess.WRITE)
	if file == null:
		push_error("RunLogger: cannot open %s" % log_path)
		return
	print("[RunLogger] writing to %s" % log_path)
	_write({"type": "meta", "data": {"run_dir": run_dir, "started_at": ts}})

func _ensure_runs_dir() -> void:
	var d := DirAccess.open(".")
	if d == null:
		return
	if not d.dir_exists("runs"):
		d.make_dir("runs")
	var run_base: String = run_dir
	if not d.dir_exists(run_base):
		d.make_dir_recursive(run_base)

func _iso_timestamp() -> String:
	var t: Dictionary = Time.get_datetime_dict_from_system()
	return "%04d%02d%02dT%02d%02d%02d" % [
		t["year"], t["month"], t["day"], t["hour"], t["minute"], t["second"]
	]

func log_event(tick: int, event: Dictionary) -> void:
	_write({"tick": tick, "type": "event", "data": event})

func log_action(tick: int, agent_name: String, action: Dictionary) -> void:
	_write({"tick": tick, "type": "action", "agent": agent_name, "data": action})

func log_llm_request(tick: int, agent_name: String, user_prompt: String) -> void:
	_write({"tick": tick, "type": "llm_request", "agent": agent_name, "data": {"user_prompt": user_prompt}})

func log_llm_response(tick: int, agent_name: String, body: String, latency_ms: int) -> void:
	_write({"tick": tick, "type": "llm_response", "agent": agent_name, "data": {"body": body, "latency_ms": latency_ms}})

func log_tick_boundary(tick: int, day: int, alive: int) -> void:
	_write({"tick": tick, "type": "tick", "data": {"day": day, "alive": alive}})

func _write(rec: Dictionary) -> void:
	if file == null:
		return
	rec["ts"] = Time.get_datetime_string_from_system()
	file.store_line(JSON.stringify(rec))
	file.flush()
