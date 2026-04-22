class_name LLMClient
extends Node

# 複数 provider (Ollama / Anthropic / 将来的に他) の共通インターフェース。
# main.gd はこの型に対してのみ依存し、具象は config.llm.provider で決まる。

signal batch_started(total: int)
signal batch_progress(done: int, total: int, in_flight: int)
signal batch_finished(elapsed_sec: float)
signal health_changed(status: String)   # "ok" / "error" / "unknown"
signal agent_decided(agent_id: int, actions: Array)
signal llm_request_sent(agent_id: int, user_prompt: String)
signal llm_response_received(agent_id: int, body: String, latency_ms: int)

var last_latency_ms: int = 0
var last_status: String = "unknown"

func configure(_cfg: Dictionary) -> void:
	pass

func ping() -> bool:
	return false

func reset_status_to_unknown() -> void:
	if last_status != "unknown":
		last_status = "unknown"
		health_changed.emit("unknown")

func decide_all(_agents: Array, _world: World, _resources: ResourceField) -> Array:
	return []

func _set_status(s: String) -> void:
	if s != last_status:
		last_status = s
		health_changed.emit(s)
