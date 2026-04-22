class_name Agent
extends RefCounted

const HUNGER_MAX: int = 100
const HEALTH_MAX: int = 100
const HUNGER_INITIAL: int = 80
const HEALTH_INITIAL: int = 100

var id: int = 0
var agent_name: String = ""
var romaji: String = ""
var gender: String = "female"
var cooperative: int = 50
var aggressive: int = 50
var curious: int = 50
var grid_pos: Vector2i = Vector2i.ZERO
var hunger: int = HUNGER_INITIAL
var health: int = HEALTH_INITIAL

func _init(id_: int = 0) -> void:
	id = id_

func is_alive() -> bool:
	return health > 0

func apply_tick_decay() -> void:
	hunger = max(0, hunger - 1)
	if hunger == 0:
		health = max(0, health - 2)

func eat(amount: int) -> void:
	hunger = min(HUNGER_MAX, hunger + amount)

func dominant_axis() -> String:
	if _is_balanced():
		return "balanced"
	if cooperative >= aggressive and cooperative >= curious:
		return "cooperative"
	if aggressive >= curious:
		return "aggressive"
	return "curious"

func _is_balanced() -> bool:
	return abs(cooperative - 50) <= 10 \
		and abs(aggressive - 50) <= 10 \
		and abs(curious - 50) <= 10

func badge_color() -> Color:
	# design.md §3.9.2 の色割当。band 内で id ハッシュから微調整。
	var band := _color_band(dominant_axis())
	var shift := fmod(float(id) * 0.137, 1.0)
	var hue := fmod(band[0] + (band[1] - band[0]) * shift, 1.0)
	return Color.from_hsv(hue, 0.55, 0.78)

func _color_band(axis: String) -> Array:
	match axis:
		"cooperative":
			return [0.28, 0.38]
		"aggressive":
			return [0.97, 1.05]
		"curious":
			return [0.60, 0.78]
		_:
			return [0.09, 0.15]
