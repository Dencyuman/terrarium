class_name ResponseParser
extends RefCounted

const DIRECTIONS := {
	# 正方位(4)
	"north": Vector2i(0, -1),
	"south": Vector2i(0, 1),
	"east":  Vector2i(1, 0),
	"west":  Vector2i(-1, 0),
	# 斜方位(4)
	"northeast": Vector2i(1, -1),
	"northwest": Vector2i(-1, -1),
	"southeast": Vector2i(1, 1),
	"southwest": Vector2i(-1, 1),
	# 略語
	"n": Vector2i(0, -1), "s": Vector2i(0, 1), "e": Vector2i(1, 0), "w": Vector2i(-1, 0),
	"ne": Vector2i(1, -1), "nw": Vector2i(-1, -1), "se": Vector2i(1, 1), "sw": Vector2i(-1, 1),
	# 日本語
	"上": Vector2i(0, -1), "下": Vector2i(0, 1), "右": Vector2i(1, 0), "左": Vector2i(-1, 0),
}

static func parse(body_text: String, agents: Array) -> Array:
	# 返り値は Array[Action](複合アクション)。空 Array の場合は wait として扱う。
	var data = JSON.parse_string(body_text)
	if data == null or not (data is Dictionary):
		return [Action.wait("parse: root not object")]
	if data.has("message") and data["message"] is Dictionary:
		var content_raw = data["message"].get("content", "")
		var inner = JSON.parse_string(str(content_raw))
		if inner is Dictionary:
			data = inner
		else:
			return [Action.wait("parse: chat content not object")]
	elif data.has("response"):
		var inner2 = JSON.parse_string(str(data["response"]))
		if inner2 is Dictionary:
			data = inner2
		else:
			return [Action.wait("parse: response not object")]
	return parse_decision(data, agents)

# Tool use 経路: tool_call.function.arguments(既にパース済み Dictionary)を直接受ける。
static func parse_decision(data: Variant, agents: Array) -> Array:
	if data == null or not (data is Dictionary):
		return [Action.wait("parse: decision not object")]
	var reason: String = str(data.get("reason", ""))
	if data.has("actions") and data["actions"] is Array:
		var result: Array = []
		for entry in data["actions"]:
			if not (entry is Dictionary):
				continue
			var act := _parse_one(entry, reason, agents)
			if act != null:
				result.append(act)
		if result.is_empty():
			return [Action.wait(reason if reason != "" else "parse: empty actions")]
		return result
	# 旧スキーマ: 単発 "action"
	var single := _parse_one(data, reason, agents)
	if single == null:
		return [Action.wait("parse: unknown shape")]
	return [single]

static func _parse_one(d: Dictionary, fallback_reason: String, agents: Array) -> Action:
	var kind_str: String = str(d.get("kind", d.get("action", ""))).to_lower().strip_edges()
	var reason: String = str(d.get("reason", fallback_reason))
	match kind_str:
		"wait", "":
			return Action.wait(reason)
		"take":
			var tdir_raw: String = str(d.get("direction", "")).to_lower().strip_edges()
			var tdir: Vector2i = Vector2i.ZERO
			if tdir_raw != "":
				if DIRECTIONS.has(tdir_raw):
					tdir = DIRECTIONS[tdir_raw]
				else:
					return Action.wait("parse: bad take direction %s" % tdir_raw)
			return Action.take(reason, tdir)
		"eat":
			return Action.eat(reason)
		"move":
			var dir_raw: String = str(d.get("direction", "")).to_lower().strip_edges()
			if DIRECTIONS.has(dir_raw):
				return Action.move(DIRECTIONS[dir_raw], reason)
			return Action.wait("parse: bad direction %s" % dir_raw)
		"speak", "say", "話す":
			var text: String = str(d.get("text", "")).strip_edges()
			if text.is_empty():
				return Action.wait("parse: empty speech")
			var target_ids: Array[int] = _parse_targets(d.get("target", null), agents)
			return Action.speak(text, target_ids, reason)
		"give":
			var tid: int = _parse_single_target(d.get("target", null), agents)
			if tid < 0:
				return Action.wait("parse: give missing target")
			return Action.give(tid, reason)
		"attack":
			var tid2: int = _parse_single_target(d.get("target", null), agents)
			if tid2 < 0:
				return Action.wait("parse: attack missing target")
			return Action.attack(tid2, reason)
		"embrace":
			var tid3: int = _parse_single_target(d.get("target", null), agents)
			if tid3 < 0:
				return Action.wait("parse: embrace missing target")
			return Action.embrace(tid3, reason)
		_:
			return null

static func _parse_single_target(raw: Variant, agents: Array) -> int:
	if raw == null:
		return -1
	if raw is Array:
		if raw.size() == 0:
			return -1
		return _lookup_agent_id(str(raw[0]).strip_edges(), agents)
	var name_s: String = str(raw).strip_edges()
	if name_s.is_empty():
		return -1
	return _lookup_agent_id(name_s, agents)

static func _lookup_agent_id(name: String, agents: Array) -> int:
	if name.is_empty():
		return -1
	for a in agents:
		if a.agent_name == name or a.romaji == name:
			return a.id
	return -1

# target フィールド: 文字列 / 文字列配列 / null を受けて id 配列に正規化
static func _parse_targets(raw: Variant, agents: Array) -> Array[int]:
	var out: Array[int] = []
	if raw == null:
		return out
	if raw is Array:
		for item in raw:
			var name_s: String = str(item).strip_edges()
			var id_val: int = _lookup_agent_id(name_s, agents)
			if id_val >= 0 and not (id_val in out):
				out.append(id_val)
	else:
		var single: String = str(raw).strip_edges()
		if not single.is_empty():
			var id_val: int = _lookup_agent_id(single, agents)
			if id_val >= 0:
				out.append(id_val)
	return out
