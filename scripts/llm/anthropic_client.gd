class_name AnthropicClient
extends LLMClient

const DEFAULT_TIMEOUT_SEC: int = 90
const ENDPOINT: String = "https://api.anthropic.com/v1/messages"
const ANTHROPIC_VERSION: String = "2023-06-01"

var api_key: String = ""
var model: String = "claude-haiku-4-5-20251001"
var max_tokens: int = 800
var temperature: float = 0.6
var parallel: int = 4

var _queue: Array = []
var _in_flight: int = 0
var _done: int = 0
var _total: int = 0
var _results: Dictionary = {}
var _batch_active: bool = false
var _batch_started_at_ms: int = 0

func configure(cfg: Dictionary) -> void:
	# 同じ llm ブロックに Ollama / Anthropic 両方の設定が同居する想定。
	# api_key は機密なので config.local.json 側で書く(.gitignore 済み)。
	api_key = str(cfg.get("anthropic_api_key", ""))
	model = str(cfg.get("anthropic_model", model))
	max_tokens = int(cfg.get("anthropic_max_tokens", max_tokens))
	temperature = float(cfg.get("temperature", temperature))
	parallel = int(cfg.get("parallel", parallel))

func ping() -> bool:
	# Anthropic API は軽量な health エンドポイントを持たないので、api_key の有無だけ確認。
	# 実際の疎通は最初のリクエストで失敗したときに _set_status("error") に倒れる。
	var ok := api_key != ""
	_set_status("ok" if ok else "error")
	return ok

func decide_all(agents: Array, world: World, resources: ResourceField) -> Array:
	_queue = []
	_results = {}
	_in_flight = 0
	_done = 0
	_total = agents.size()
	_batch_active = true
	_batch_started_at_ms = Time.get_ticks_msec()
	batch_started.emit(_total)
	print("[Anthropic] decide_all start: total=%d, model=%s, parallel=%d" % [_total, model, parallel])
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
	print("[Anthropic] decide_all done: %d ms" % elapsed_ms)
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
	# Anthropic tool 形式: {name, description, input_schema}。
	# PromptBuilder.tool_schema() は OpenAI/Ollama 形式 {type:"function", function:{...}} を返すので
	# ここでキー名を詰め替える。
	var schema := PromptBuilder.tool_schema()
	var fn: Dictionary = schema.get("function", {})
	var act_tool := {
		"name": fn.get("name", "act"),
		"description": fn.get("description", ""),
		"input_schema": fn.get("parameters", {})
	}
	var body := {
		"model": model,
		"max_tokens": max_tokens,
		"temperature": temperature,
		"system": PromptBuilder.system_prompt(),
		"messages": [
			{"role": "user", "content": user_prompt}
		],
		"tools": [act_tool],
		# tool_choice で act の呼び出しを強制。これで content[0].input に Dict が必ず入る。
		"tool_choice": {"type": "tool", "name": "act"},
	}
	var payload := JSON.stringify(body)
	var headers := [
		"Content-Type: application/json",
		"x-api-key: %s" % api_key,
		"anthropic-version: %s" % ANTHROPIC_VERSION,
	]
	var err := http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, payload)
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
	var actions: Array = _parse_response(body_text, agents)
	_finish_request(http, agent, agents, actions, true)

# content[] の中から tool_use ブロックを探し、その input(既にパース済み Dictionary)を流用。
func _parse_response(body_text: String, agents: Array) -> Array:
	var parsed = JSON.parse_string(body_text)
	if not (parsed is Dictionary):
		return [Action.wait("parse: root not object")]
	var content = parsed.get("content", null)
	if content is Array:
		for block in content:
			if block is Dictionary and str(block.get("type", "")) == "tool_use":
				var input = block.get("input", null)
				if input is Dictionary:
					return ResponseParser.parse_decision(input, agents)
	# fallback: 通常の text block しか返ってこなかった場合、そのテキストを JSON としてパース試行
	if content is Array:
		for block in content:
			if block is Dictionary and str(block.get("type", "")) == "text":
				var text_s := str(block.get("text", ""))
				if text_s != "":
					return ResponseParser.parse(text_s, agents)
	return ResponseParser.parse(body_text, agents)

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
	for v in _results.values():
		var actions: Array = v
		if actions.is_empty():
			continue
		var first: Action = actions[0]
		var is_failure: bool = first.kind == Action.Kind.WAIT and (first.reason.begins_with("http") or first.reason.begins_with("parse"))
		if not is_failure:
			ok_count += 1
	if ok_count == 0 and _total > 0:
		_set_status("error")
