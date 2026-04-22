class_name PromptBuilder
extends RefCounted

const VISION_RADIUS: int = 3

const TERRAIN_NAME := {
	0: "grass",
	1: "water",
	2: "forest",
	3: "rock",
}

# 最小ハーネスプロンプト:
# - 実行可能な動詞の定義(物理)
# - 同 tick の物理制約(同 kind 1 回、合計 3 個、順序は自由)
# - 入出力の JSON フォーマット
# 「何をすべきか」「何を避けるべきか」の規範的記述は一切置かない。
# 行動の選択はエージェントの内部状態・性格・記憶・環境からのみ決まる。
const SYSTEM_PROMPT := """You are an autonomous agent in a 20×20 grid world.
Each tick, you receive your own state, what you can see, your own past actions, and what you have overheard. You decide what to do this tick.

# Action verbs (what is physically possible)
- "move": step to an orthogonally adjacent tile. field `direction`: one of "north" / "east" / "south" / "west".
- "take": pick up food located on your current tile at the moment this action executes. If there is no food there, the action does nothing.
- "speak": produce an utterance. field `text` is the spoken string in **natural Japanese colloquial (日本語口語体) — one short sentence**. `target` is optional and may be:
    - omitted → unaddressed (independent / to-whom-it-may-concern)
    - a single name string (e.g. `"霞"`) → addressed to one agent
    - an array of names (e.g. `["霞","朔"]`) → addressed to multiple agents at once (useful for calling a group)
  Speech physically propagates to **every living agent within your vision radius**, regardless of `target`. `target` only labels whom you intend to address, it does not restrict the audience.
- "wait": do nothing.

# Same-tick physics
- You may pack up to 3 actions into this tick, in any order you choose.
- Each `kind` (move / take / speak / wait) can appear at most once per tick (you have one body and one voice).
- The actions are executed in the exact order you list them. Anything that cannot physically happen at execution time (e.g. move into water, take on a tile with no food, speak to an agent no longer in sight) silently fails and the remaining actions continue.

# World physics
- Coordinates: x grows east, y grows south. (0,0) is the NW corner.
- Water tiles are impassable. You cannot enter a tile already occupied by another living agent.
- `hunger` ranges 0–100 (starts at 80). `health` ranges 0–100 (starts at 100). Each tick your `hunger` decreases. When `hunger` reaches 0, your `health` decreases. When `health` reaches 0 you die.
- Speech propagates only to agents whose tile is within `vision_radius=3` of yours at the moment of speaking.

# Output format
Return exactly one JSON object, nothing else. No markdown, no explanation.

{
  "actions": [
    {"kind":"move","direction":"east"},
    {"kind":"take"},
    {"kind":"speak","text":"...","target":"..."}
  ],
  "reason": "<optional short Japanese note about why, 30 chars or less>"
}

Omit fields that do not apply. `actions` may be empty (equivalent to a single wait).

# Language
All free-form output (`text`, `reason`) must be in **Japanese**. Keys and enum values (`action`, `kind`, `direction`, `target` names) stay in the schema-defined form."""

static func system_prompt() -> String:
	return SYSTEM_PROMPT

static func build_user_prompt(agent: Agent, world: World, resources: ResourceField, agents: Array) -> String:
	var state := _agent_state(agent, world, resources)
	var vision := _vision(agent, world, resources, agents)
	var obj := {
		"you": state,
		"vision": vision,
	}
	if agent.own_history.size() > 0:
		obj["own_history"] = agent.own_history
	if agent.recent_events.size() > 0:
		obj["recent_events"] = agent.recent_events
	return JSON.stringify(obj, "  ")

static func _agent_state(agent: Agent, world: World, resources: ResourceField) -> Dictionary:
	var t: int = world.get_terrain(agent.grid_pos.x, agent.grid_pos.y)
	return {
		"name": agent.agent_name,
		"gender": agent.gender,
		"personality": {
			"cooperative": agent.cooperative,
			"aggressive": agent.aggressive,
			"curious": agent.curious,
		},
		"position": [agent.grid_pos.x, agent.grid_pos.y],
		"terrain": TERRAIN_NAME.get(t, "grass"),
		"hunger": agent.hunger,
		"health": agent.health,
		"food_here": resources.has_food(agent.grid_pos.x, agent.grid_pos.y),
	}

static func _vision(agent: Agent, world: World, resources: ResourceField, agents: Array) -> Array:
	# 視界範囲内で観測可能なタイル情報。草地で何もないタイルは省略してペイロード削減。
	var out: Array = []
	var by_pos: Dictionary = {}
	for other in agents:
		if other.id == agent.id:
			continue
		if not other.is_alive():
			continue
		by_pos[other.grid_pos] = other
	for dy in range(-VISION_RADIUS, VISION_RADIUS + 1):
		for dx in range(-VISION_RADIUS, VISION_RADIUS + 1):
			if dx == 0 and dy == 0:
				continue
			var x: int = agent.grid_pos.x + dx
			var y: int = agent.grid_pos.y + dy
			if x < 0 or y < 0 or x >= world.size or y >= world.size:
				continue
			var t: int = world.get_terrain(x, y)
			var has_food: bool = resources.has_food(x, y)
			var has_agent: bool = by_pos.has(Vector2i(x, y))
			if t == 0 and not has_food and not has_agent:
				continue
			var entry: Dictionary = {
				"pos": [x, y],
				"terrain": TERRAIN_NAME.get(t, "grass"),
			}
			if has_food:
				entry["food"] = true
			if has_agent:
				var other: Agent = by_pos[Vector2i(x, y)]
				entry["agent"] = other.agent_name
			out.append(entry)
	return out
