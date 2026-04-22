class_name Action
extends RefCounted

enum Kind { WAIT, MOVE, TAKE, SPEAK, EAT, GIVE, ATTACK, EMBRACE, LOOK, REPRODUCE_WITH }

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

static func take(reason_: String = "", dir: Vector2i = Vector2i.ZERO) -> Action:
	# take は「指定タイルの食料を拾う」物理動作。dir は自タイルからのオフセット(-1..1, -1..1)。
	# 既定 (0,0) なら現在タイル。8 近傍 + 現在 = 9 マスのいずれかを選べる。
	var a := Action.new()
	a.kind = Kind.TAKE
	a.direction = dir
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

static func reproduce_with(target_id_: int, reason_: String = "") -> Action:
	# Phase 5: 合意ベースの生殖。異性間 + 隣接 + 双方が同 tick で相互指定が必須。
	var a := Action.new()
	a.kind = Kind.REPRODUCE_WITH
	a.target_id = target_id_
	a.reason = reason_
	return a

static func look(dir: Vector2i, reason_: String = "") -> Action:
	# 一時的な遠方観察。自身から dir の方向に矩形(5×3)を覗き見る。
	# 結果は scouted_tiles に記憶される(vision 半径を越えた情報の一次取得)。
	var a := Action.new()
	a.kind = Kind.LOOK
	a.direction = dir
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
		Kind.LOOK: return "look"
		Kind.REPRODUCE_WITH: return "reproduce_with"
		_: return "?"
