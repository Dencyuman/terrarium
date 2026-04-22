class_name Action
extends RefCounted

enum Kind { WAIT, MOVE, TAKE, SPEAK, EAT, GIVE, ATTACK, EMBRACE }

var kind: int = Kind.WAIT
var direction: Vector2i = Vector2i.ZERO
var speech_text: String = ""
var speech_target_ids: Array[int] = []   # 空 = 不特定(独り言/宣言)
var target_id: int = -1                  # give / attack / embrace の対象(1 体のみ)
var reason: String = ""
# apply 時に set される物理結果。UI ログの成否表示用。
var succeeded: bool = false
var failure_note: String = ""   # "no_food" / "blocked" / "inventory_full" / "not_adjacent" 等

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
	# Phase 4 以降、take は「現在タイルの食料を inventory に積む」物理動作。
	var a := Action.new()
	a.kind = Kind.TAKE
	a.reason = reason_
	return a

static func eat(reason_: String = "") -> Action:
	# inventory にあれば消費、なければ現在タイルの食料を直接消費。
	var a := Action.new()
	a.kind = Kind.EAT
	a.reason = reason_
	return a

static func give(target_id_: int, reason_: String = "") -> Action:
	var a := Action.new()
	a.kind = Kind.GIVE
	a.target_id = target_id_
	a.reason = reason_
	return a

static func attack(target_id_: int, reason_: String = "") -> Action:
	var a := Action.new()
	a.kind = Kind.ATTACK
	a.target_id = target_id_
	a.reason = reason_
	return a

static func embrace(target_id_: int, reason_: String = "") -> Action:
	var a := Action.new()
	a.kind = Kind.EMBRACE
	a.target_id = target_id_
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
		Kind.WAIT: return "wait"
		Kind.MOVE: return "move"
		Kind.TAKE: return "take"
		Kind.SPEAK: return "speak"
		Kind.EAT: return "eat"
		Kind.GIVE: return "give"
		Kind.ATTACK: return "attack"
		Kind.EMBRACE: return "embrace"
		_: return "?"
