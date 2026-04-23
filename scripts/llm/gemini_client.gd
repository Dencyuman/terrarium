class_name GeminiClient
extends LLMClient

const DEFAULT_TIMEOUT_SEC: int = 90

var api_key: String = ""
var model: String = "gemini-3.1-flash-lite-preview"
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
	api_key = str(cfg.get("gemini_api_key", ""))
	model = str(cfg.get("gemini_model", model))
	max_tokens = int(cfg.get("gemini_max_tokens", max_tokens))
	temperature = float(cfg.get("temperature", temperature))
	parallel = int(cfg.get("parallel", parallel))

func ping() -> bool:
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
	print("[Gemini] decide_all start: total=%d, model=%s, parallel=%d" % [_total, model, parallel])
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
	print("[Gemini] decide_all done: %d ms" % elapsed_ms)
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

func _endpoint() -> String:
	return "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % model

func _start_request(task: Dictionary) -> void:
	var agent: Agent = task["agent"]
	var user_prompt: String = task["user_prompt"]
	var agents: Array = task["agents"]
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = float(DEFAULT_TIMEOUT_SEC)
	# Gemini は oneOf / allOf / contains / maxContains / additionalProperties を
	# parameters スキーマで受け付けないので、フラット版の tool_schema を使う。
	# kind 別の required field は prompt と ResponseParser 側で担保する。
	var schema := PromptBuilder.tool_schema_flat()
	var fn: Dictionary = schema.get("function", {})
	var act_decl := {
		"name": fn.get("name", "act"),
		"description": fn.get("description", ""),
		"parameters": fn.get("parameters", {})
	}
	var body := {
		"systemInstruction": {
			"parts": [{"text": PromptBuilder.system_prompt(disposition)}]
		},
		"contents": [
			{"role": "user", "parts": [{"text": user_prompt}]}
		],
		"tools": [{"functionDeclarations": [act_decl]}],
		# ANY + allowedFunctionNames で act の呼び出しを強制。
		"toolConfig": {
			"functionCallingConfig": {
				"mode": "ANY",
				"allowedFunctionNames": ["act"]
			}
		},
		"generationConfig": {
			"temperature": temperature,
			"maxOutputTokens": max_tokens,
			# thinkingBudget: 0 で内部推論を最小化(Flash-Lite のレイテンシ担保)。
			"thinkingConfig": {"thinkingBudget": 0}
		}
	}
	var payload := JSON.stringify(body)
	var headers := [
		"Content-Type: application/json",
		"x-goog-api-key: %s" % api_key,
	]
	var err := http.request(_endpoint(), headers, HTTPClient.METHOD_POST, payload)
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
	_emit_usage(body_text)
	var actions: Array = _parse_response(body_text, agents)
	_finish_request(http, agent, agents, actions, true)

func _emit_usage(body_text: String) -> void:
	var parsed = JSON.parse_string(body_text)
	if not (parsed is Dictionary):
		return
	# Gemini: usageMetadata.promptTokenCount / candidatesTokenCount / thoughtsTokenCount
	var usage = parsed.get("usageMetadata", null)
	if not (usage is Dictionary):
		return
	var in_tok: int = int(usage.get("promptTokenCount", 0))
	var out_tok: int = int(usage.get("candidatesTokenCount", 0)) + int(usage.get("thoughtsTokenCount", 0))
	usage_recorded.emit(in_tok, out_tok)

# Gemini response:
# candidates[0].content.parts[] の中から functionCall ブロックを探して args を取り出す。
func _parse_response(body_text: String, agents: Array) -> Array:
	var parsed = JSON.parse_string(body_text)
	if not (parsed is Dictionary):
		return [Action.wait("parse: root not object")]
	var cands = parsed.get("candidates", null)
	if not (cands is Array) or cands.is_empty():
		return [Action.wait("parse: no candidates")]
	var content = cands[0].get("content", null) if cands[0] is Dictionary else null
	if not (content is Dictionary):
		return [Action.wait("parse: no content")]
	var parts = content.get("parts", null)
	if parts is Array:
		for part in parts:
			if part is Dictionary and part.has("functionCall"):
				var fc = part["functionCall"]
				if fc is Dictionary:
					var args = fc.get("args", null)
					if args is Dictionary:
						return ResponseParser.parse_decision(args, agents)
		# フォールバック: text のみ返ってきた場合
		for part in parts:
			if part is Dictionary and part.has("text"):
				var t := str(part["text"])
				if t != "":
					return ResponseParser.parse(t, agents)
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
