class_name Agent
extends RefCounted

const HUNGER_MAX: int = 100
const HEALTH_MAX: int = 100
const STAMINA_MAX: int = 100
const HUNGER_INITIAL: int = 80
const HEALTH_INITIAL: int = 100
const STAMINA_INITIAL: int = 100
const DEFAULT_INVENTORY_CAPACITY: int = 3
const LIFE_EVENTS_MAX: int = 20

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
var stamina: int = STAMINA_INITIAL
# 加齢(日単位)。Phase 5 で導入。tick ではなく day 境界でインクリメントされる。
var age_days: int = 0
# 親系譜(Phase 5 の reproduce_with で設定される)
var parent_ids: Array[int] = []
# 内的衝動(Phase 5.E)。hunger/stamina と同じく身体化された圧として扱う。
# 閾値を超えると行動動機が生まれる。discharge 行動で減衰する。
var libido: int = 0                   # 性欲。puberty 後に蓄積、reproduce_with で解消
var aggression_pressure: int = 0      # 攻撃衝動。飢餓や被攻撃で蓄積、attack で解消

# 所持品(v0.1 は食料のみ扱う。文字列 "food" をスロット占有の単位とする)
var inventory: Array[String] = []
var inventory_capacity: int = DEFAULT_INVENTORY_CAPACITY

# 他エージェントごとの関係(id → {affection, trust, last_tick})
# affection: -100..+100 (好嫌)
# trust:      0..100    (信頼、中立 50 スタート)
var relations: Dictionary = {}

# Phase 3 で導入、短期記憶
var last_action_kind: int = 0
var last_action_reason: String = ""
var last_speech: String = ""
var last_speech_tick: int = -1
var last_speech_target_ids: Array[int] = []
var recent_events: Array[String] = []
var own_history: Array[String] = []
# 中期記憶: 高 salience 物理イベント(attack / death 目撃、give/embrace 関与)を
# 平坦タイムラインで 20 件ロール保持。recent_events より長寿命、interactions より広範。
var life_events: Array[String] = []
# 遠方観察(look アクション)で覗き見た視界外タイルの記憶。
# 各 entry = {tick: int, pos: [x,y], terrain: str, food?: bool, agent?: str, corpse?: str}
var scouted_tiles: Array = []
const SCOUTED_TILES_MAX: int = 24
# Phase 6: 他者から teach アクションで伝えられた記憶(口伝)。
# 各 entry = {tick: int, from_id: int, from_name: str, text: str}
# 直接体験した life_events と区別され、「~から聞いた話」として保持される。
var heard_memories: Array = []
const HEARD_MEMORIES_MAX: int = 16

func _init(id_: int = 0) -> void:
	id = id_

func is_alive() -> bool:
	return health > 0

func apply_tick_decay(base_cost: int = 1, starving_drain: int = 2, elder_age_days: int = 6, elder_drain: int = 2) -> void:
	hunger = max(0, hunger - base_cost)
	if hunger == 0:
		health = max(0, health - starving_drain)
	# 老衰: age_days >= elder_age_days なら毎 tick さらに health が削れる
	if age_days >= elder_age_days:
		health = max(0, health - elder_drain)

func eat_amount(amount: int) -> void:
	hunger = min(HUNGER_MAX, hunger + amount)

func spend_stamina(amount: int) -> void:
	stamina = max(0, stamina - amount)

func gain_stamina(amount: int) -> void:
	stamina = min(STAMINA_MAX, stamina + amount)

func can_afford_stamina(cost: int) -> bool:
	return stamina >= cost

# --- inventory ---

func inventory_has_space() -> bool:
	return inventory.size() < inventory_capacity

func inventory_add(item: String) -> bool:
	if not inventory_has_space():
		return false
	inventory.append(item)
	return true

func inventory_remove_first(item: String) -> bool:
	var idx := inventory.find(item)
	if idx < 0:
		return false
	inventory.remove_at(idx)
	return true

func inventory_count(item: String) -> int:
	var n := 0
	for x in inventory:
		if x == item:
			n += 1
	return n

# --- relations ---

func ensure_relation(other_id: int, current_tick: int) -> Dictionary:
	if not relations.has(other_id):
		relations[other_id] = {
			"affection": 0,
			"trust": 50,
			"last_tick": current_tick,
		}
	return relations[other_id]

func adjust_relation(other_id: int, d_affection: int, d_trust: int, current_tick: int) -> void:
	var rel: Dictionary = ensure_relation(other_id, current_tick)
	rel["affection"] = clamp(int(rel["affection"]) + d_affection, -100, 100)
	rel["trust"] = clamp(int(rel["trust"]) + d_trust, 0, 100)
	rel["last_tick"] = current_tick

func append_scouted(entry: Dictionary) -> void:
	scouted_tiles.append(entry)
	while scouted_tiles.size() > SCOUTED_TILES_MAX:
		scouted_tiles.pop_front()

func append_life_event(current_tick: int, text: String) -> void:
	life_events.append("t%d %s" % [current_tick, text])
	while life_events.size() > LIFE_EVENTS_MAX:
		life_events.pop_front()

func append_heard_memory(current_tick: int, from_id: int, from_name: String, text: String) -> void:
	heard_memories.append({
		"tick": current_tick,
		"from_id": from_id,
		"from_name": from_name,
		"text": text,
	})
	while heard_memories.size() > HEARD_MEMORIES_MAX:
		heard_memories.pop_front()

func append_interaction(other_id: int, current_tick: int, text: String, limit: int = 8) -> void:
	# ハーネスが物理イベントを客観的に記録する自由テキスト。解釈はしない。
	var rel: Dictionary = ensure_relation(other_id, current_tick)
	if not rel.has("interactions"):
		rel["interactions"] = [] as Array[String]
	var arr: Array = rel["interactions"]
	arr.append("t%d %s" % [current_tick, text])
	while arr.size() > limit:
		arr.pop_front()
	rel["interactions"] = arr

# 上位 N 件の関係(|affection| 降順)をプロンプト/UI 用に返す
# vision_radius を指定すると、自分の視界内にその相手がいるかのフラグも載せる。
func top_relations(limit: int, agents: Array, vision_radius: int = 3) -> Array:
	var entries: Array = []
	for other_id in relations.keys():
		var rel: Dictionary = relations[other_id]
		var name := ""
		var other_agent: Agent = null
		for a in agents:
			if a.id == other_id:
				name = a.agent_name
				other_agent = a
				break
		if name == "":
			continue
		var interactions: Array = rel.get("interactions", [])
		var entry: Dictionary = {
			"name": name,
			"affection": int(rel["affection"]),
			"trust": int(rel["trust"]),
			"interactions": interactions.duplicate(),
		}
		if other_agent != null:
			var dx: int = absi(other_agent.grid_pos.x - grid_pos.x)
			var dy: int = absi(other_agent.grid_pos.y - grid_pos.y)
			entry["in_vision"] = (dx <= vision_radius and dy <= vision_radius) and other_agent.is_alive()
			entry["alive"] = other_agent.is_alive()
		entries.append(entry)
	entries.sort_custom(func(a, b): return abs(int(a["affection"])) > abs(int(b["affection"])))
	if entries.size() > limit:
		entries.resize(limit)
	return entries

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
