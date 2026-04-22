class_name Action
extends RefCounted

enum Kind { WAIT, MOVE, TAKE }

var kind: int = Kind.WAIT
var direction: Vector2i = Vector2i.ZERO

static func wait() -> Action:
	var a := Action.new()
	a.kind = Kind.WAIT
	return a

static func move(dir: Vector2i) -> Action:
	var a := Action.new()
	a.kind = Kind.MOVE
	a.direction = dir
	return a

static func take() -> Action:
	var a := Action.new()
	a.kind = Kind.TAKE
	return a
