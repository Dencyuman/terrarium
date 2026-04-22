class_name Action
extends RefCounted

enum Kind { WAIT, MOVE, TAKE, SPEAK }

var kind: int = Kind.WAIT
var direction: Vector2i = Vector2i.ZERO
var speech_text: String = ""
var speech_target_ids: Array[int] = []   # 空 = 不特定(独り言/宣言)
var reason: String = ""

static func wait(reason_: String = "") -> Action:
	var a := Action.new()
	a.kind = Kind.WAIT
	a.reason = reason_
	return a

static func move(dir: Vector2i, reason_: String = "") -> Action:
	var a := Action.new()
	a.kind = Kind.MOVE
	a.direction = dir
	a.reason = reason_
	return a

static func take(reason_: String = "") -> Action:
	var a := Action.new()
	a.kind = Kind.TAKE
	a.reason = reason_
	return a

static func speak(text: String, target_ids: Array[int] = [] as Array[int], reason_: String = "") -> Action:
	var a := Action.new()
	a.kind = Kind.SPEAK
	a.speech_text = text
	a.speech_target_ids = target_ids
	a.reason = reason_
	return a

func kind_label() -> String:
	match kind:
		Kind.WAIT:
			return "wait"
		Kind.MOVE:
			return "move"
		Kind.TAKE:
			return "take"
		Kind.SPEAK:
			return "speak"
		_:
			return "?"
