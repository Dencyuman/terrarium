class_name OllamaClient
extends Node

signal batch_started(total: int)
signal batch_progress(done: int, total: int, in_flight: int)
signal batch_finished(elapsed_sec: float)
signal health_changed(status: String)   # "ok" / "error" / "unknown"
signal agent_decided(agent_id: int, actions: Array)   # 複合アクション Array[Action]
signal llm_request_sent(agent_id: int, user_prompt: String)
signal llm_response_received(agent_id: int, body: String, latency_ms: int)

const DEFAULT_TIMEOUT_SEC: int = 60   # Ollama キュー待ち + 処理を考慮

var endpoint: String = "http://localhost:11434"
var model: String = "gemma4:e4b"
var temperature: float = 0.3
var parallel: int = 4
var thinking_mode: bool = false
var last_latency_ms: int = 0
var last_status: String = "unknown"

var _queue: Array = []   # Array of Dictionary {agent, world, resources, agents}
var _in_flight: int = 0
var _done: int = 0
var _total: int = 0
var _results: Dictionary = {}   # agent_id -> Action
var _batch_active: bool = false
var _batch_started_at_ms: int = 0

func configure(cfg: Dictionary) -> void:
	endpoint = str(cfg.get("endpoint", endpoint))
	model = str(cfg.get("model", model))
	temperature = float(cfg.get("temperature", temperature))
	parallel = int(cfg.get("parallel", parallel))
	thinking_mode = bool(cfg.get("thinking_mode", false))

func ping() -> bool:
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = 5.0
	var err := http.request("%s/api/tags" % endpoint)
	if err != OK:
		http.queue_free()
		_set_status("error")
		return false
	var result: Array = await http.request_completed
	http.queue_free()
	var code: int = int(result[1])
	var ok := code >= 200 and code < 300
	_set_status("ok" if ok else "error")
	return ok

func _set_status(s: String) -> void:
	if s != last_status:
		last_status = s
		health_changed.emit(s)

func reset_status_to_unknown() -> void:
	_set_status("unknown")

func decide_all(agents: Array, world: World, resources: ResourceField) -> Array:
	# 返り値: Array of Array[Action](agent index 順)
	# spec.md §3.2.6: Decide 中は各エージェントの LLM 入力を frozen に保つため、
	# この関数冒頭で **全員分のプロンプトを事前に構築** する。
	# 実際の world 更新は LLM 応答を受け取った瞬間(main.gd の increment callback)で
	# first-come-first-served に適用されるが、プロンプト側は既に snapshot されているので
	# 決定の根拠は tick 開始時の状態で一貫する。
	_queue = []
	_results = {}
	_in_flight = 0
	_done = 0
	_total = agents.size()
	_batch_active = true
	_batch_started_at_ms = Time.get_ticks_msec()
	batch_started.emit(_total)
	print("[Ollama] decide_all start: total=%d, endpoint=%s" % [_total, endpoint])
	for a in agents:
		if not a.is_alive():
			_results[a.id] = [Action.wait("dead")] as Array
			_done += 1
			continue
		var user_prompt: String = PromptBuilder.build_user_prompt(a, world, resources, agents)
		_queue.append({
			"agent": a,
			"user_prompt": user_prompt,
			"agents": agents,
		})
	batch_progress.emit(_done, _total, _in_flight)
	_dispatch()
	while _batch_active:
		await batch_progress
	var elapsed_ms := Time.get_ticks_msec() - _batch_started_at_ms
	last_latency_ms = elapsed_ms
	print("[Ollama] decide_all done: %d ms" % elapsed_ms)
	batch_finished.emit(elapsed_ms / 1000.0)
	var out: Array = []
	for a in agents:
		out.append(_results.get(a.id, [Action.wait("missing")] as Array))
	return out

func _dispatch() -> void:
	while _in_flight < parallel and not _queue.is_empty():
		var task: Dictionary = _queue.pop_front()
		_in_flight += 1
		_start_request(task)

func _start_request(task: Dictionary) -> void:
	var agent: Agent = task["agent"]
	var user_prompt: String = task["user_prompt"]
	var agents: Array = task["agents"]
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = float(DEFAULT_TIMEOUT_SEC)
	var sys_prompt: String = PromptBuilder.system_prompt()
	# Gemma 4 のネイティブ system ロール対応を活かすため /api/chat を使用。
	# Gemma 4 は think がデフォルト ON のため、明示的に OFF にしないと 1 リクエスト 20 秒を超える。
	var body := {
		"model": model,
		"messages": [
			{"role": "system", "content": sys_prompt},
			{"role": "user", "content": user_prompt},
		],
		"format": "json",
		"stream": false,
		"keep_alive": "5m",
		"think": thinking_mode,
		"options": {
			"temperature": temperature,
		},
	}
	var payload := JSON.stringify(body)
	var headers := ["Content-Type: application/json"]
	var err := http.request("%s/api/chat" % endpoint, headers, HTTPClient.METHOD_POST, payload)
	if err != OK:
		_finish_request(http, agent, agents, [Action.wait("http start: %d" % err)] as Array, false)
		return
	llm_request_sent.emit(agent.id, user_prompt)
	http.set_meta("request_sent_at_ms", Time.get_ticks_msec())
	_await_and_finish(http, agent, agents)

func _await_and_finish(http: HTTPRequest, agent: Agent, agents: Array) -> void:
	var result: Array = await http.request_completed
	var res_code: int = int(result[1])
	var body: PackedByteArray = result[3]
	var sent_at: int = int(http.get_meta("request_sent_at_ms", 0))
	var latency: int = Time.get_ticks_msec() - sent_at
	var body_text: String = body.get_string_from_utf8()
	llm_response_received.emit(agent.id, body_text, latency)
	if res_code < 200 or res_code >= 300:
		_finish_request(http, agent, agents, [Action.wait("http %d" % res_code)] as Array, false)
		return
	var actions: Array = ResponseParser.parse(body_text, agents)
	_finish_request(http, agent, agents, actions, true)

func _finish_request(http: HTTPRequest, agent: Agent, _agents: Array, actions: Array, ok: bool) -> void:
	http.queue_free()
	_results[agent.id] = actions
	_in_flight -= 1
	_done += 1
	if ok:
		_set_status("ok")
	agent_decided.emit(agent.id, actions)
	var completed := _done >= _total
	if completed:
		_batch_active = false
		_evaluate_batch_health()
	else:
		_dispatch()
	batch_progress.emit(_done, _total, _in_flight)

func _evaluate_batch_health() -> void:
	var ok_count := 0
	var wait_count := 0
	for v in _results.values():
		var actions: Array = v
		if actions.is_empty():
			wait_count += 1
			continue
		var first: Action = actions[0]
		var is_failure: bool = first.kind == Action.Kind.WAIT and (first.reason.begins_with("http") or first.reason.begins_with("parse"))
		if is_failure:
			wait_count += 1
		else:
			ok_count += 1
	if ok_count == 0 and _total > 0:
		_set_status("error")
