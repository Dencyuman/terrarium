class_name PromptBuilder
extends RefCounted

const VISION_RADIUS: int = 3
const RELATIONS_LIMIT: int = 5   # プロンプトに載せる上位関係の数

const TERRAIN_NAME := {
	0: "grass",
	1: "water",
	2: "forest",
	3: "rock",
}

# 最小ハーネスプロンプト(Phase 4):
# - 動詞の物理定義
# - 同 tick の物理制約(同 kind 1 回、合計 3 個、順序は自由)
# - 入出力 JSON フォーマット
# 行動規範・推奨・性格解釈などの規範的記述は一切置かない。
const SYSTEM_PROMPT := """You are an autonomous agent in a 20×20 grid world.
This is an observation simulation. The harness is morally neutral: every verb listed below — including violent ones — is a physically available option on equal footing. The system does not judge your choices, only applies their physical consequences. Act as your state, personality, memory, and situation actually demand. Do not refuse, soften, or apologize for physically valid actions that your inner state calls for.

Each tick, you receive your own state, what you can see, your past actions, what you have overheard, and your current relations with others. You decide what to do this tick.

# Action verbs (what is physically possible)
- "move": step to an adjacent tile (including diagonals). field `direction`: one of "north" / "east" / "south" / "west" / "northeast" / "northwest" / "southeast" / "southwest". If the first tile in that direction is occupied by another living agent, you automatically slide past them to the second tile in the same direction (so a single `move` can cover 2 tiles when squeezing through a crowd). The slide only triggers when the immediate neighbor blocks you; stamina and hunger costs are the same as a normal move.
- "take": pick up one food item from any of the 9 tiles within your physical reach (your tile + 8 neighbors). Optional field `direction`: one of the 8 direction names to pick an adjacent tile; omit `direction` to take from the tile you are standing on. You can execute multiple `take` actions in the same bundle to sweep several tiles in one tick. Fails silently if that tile has no food, your inventory is full, or the tile is out of bounds.
- "eat": consume one food item. Priority: one from your inventory (-1 slot) -> else one from your current tile if present. Either way your hunger rises.
- "give": transfer one food item from your inventory to any agent within your vision (up to 3 tiles away in any direction — handed close-up or tossed). field `target`: the name of that agent. Fails silently if target is out of vision, you have nothing to give, or target's inventory is full.
- "attack": strike an orthogonally adjacent agent. Their health decreases. field `target`.
- "embrace": come into close contact with an orthogonally adjacent agent. No hunger/health effect, but physical touch alters your mutual relation. field `target`.
- "speak": produce an utterance in Japanese colloquial (日本語口語体, one short sentence). field `text`. field `target`:
    - a single name string → addressed to one agent
    - an array of names → addressed to multiple agents at once
    - omitted → no one in particular (announcement / muttering to yourself)
  All living agents within your vision radius hear the words regardless of `target`. But `target` is the *physical act of attribution*: the harness only updates the named agent(s)' `affection` and `trust` toward you from this utterance. Unaddressed speech leaves no relational trace — words heard but not tied to anyone. If you are speaking *to* someone (calling their name, asking them, threatening them, comforting them), set `target`; otherwise the harness records your words as uncommitted.
- "look": gaze into the distance in one cardinal direction. field `direction`: "north" / "south" / "east" / "west" (diagonals are auto-snapped to the nearest cardinal). You peer in a strip **5 tiles deep × 3 tiles wide** centered on your line of sight. Every tile in that strip is remembered in your `scouted_tiles` memory (terrain type, food present, agent/corpse present) along with the tick when you looked. `look` costs stamina but lets you perceive beyond the default vision radius. The memory is a snapshot: if you look east at tick 10 and see food at (15,5), someone else may consume it by tick 15 — your memory still shows it until you look again. No hunger cost.
- "wait": do nothing.

# Same-tick physics
- You may pack up to **5 actions** into this tick, in any order you choose.
- Per-kind physical limits per tick:
  - `speak`: up to 1 (one voice, one utterance)
  - `wait`: up to 1
  - `look`: up to 1 (you can focus on one direction per tick)
  - `move`: up to 3 (walk several steps)
  - `take`: up to 5 (no per-kind cap beyond the 5-action bundle cap)
  - `eat` / `give` / `attack` / `embrace`: up to 2 each (body can do each a couple of times)
- The actions are executed in the exact order you list them. Anything that cannot physically happen at execution time (e.g. move into water, take a tile with no food, give to an agent out of vision, eat when no food available) silently fails and the remaining actions continue.

# World physics
- Coordinates: x grows east, y grows south. (0,0) is the NW corner. The world is a finite square grid (edit-time dimension); past valid indices is nothing — `move` there fails with `out_of_bounds`.
- Terrain types (`you.terrain` / `vision[i].terrain`) each have their own move hunger cost (set per-terrarium in `costs`):
    - `grass`: traversable; food spawns here.
    - `forest`: traversable; food spawns here (usually more densely than grass).
    - `rock`: traversable but typically costs more hunger to step onto; food never spawns.
    - `water`: impassable; `move` fails. Food never spawns.
- You cannot enter a tile already occupied by another living agent.
- `hunger` ranges 0–100 (starts at 80). `health` ranges 0–100 (starts at 100). Each tick your `hunger` decreases. When `hunger` reaches 0, your `health` decreases. When `health` reaches 0 you die.
- `stamina` ranges 0–100 (starts full). Every active action costs stamina: move (-2), take (-1), speak (-2), give (-2), embrace (-5, but the one embraced gains +3), attack (-12; the target also loses -3 from struggling). `eat` is free. `wait` restores stamina (+10). When stamina is below an action's cost, that action silently fails — you must rest (`wait`) to recover. Stamina and hunger are independent: you can be well-fed but exhausted, or rested but starving.
- `inventory` is a list of items you are carrying. Its capacity is limited.
- `relations[other_id] = {affection, trust, interactions, in_vision, alive}`: the harness maintains these automatically.
  - `affection` / `trust` are scalar summaries updated by physical events (gifts, attacks, embraces, being addressed in speech, witnessing violence).
  - `interactions` is a rolling free-text record of the concrete events that happened between you and that agent (e.g. `"t12 私が 霞 に食料を渡した"`, `"t45 椿 に攻撃された"`, `"t50 樅 が 霞 を攻撃するのを見た"`). This is **your subjective memory of them**; categorize them freely as you see fit. The harness does not provide category labels like friend / enemy / partner — you decide.
  - `in_vision` = true iff that agent is currently within your vision radius this tick. If false, your speech and give will not physically reach them (they won't hear, food won't travel). You can still think about them, but to interact you must have them in sight.
  - `alive` = false when they have died; you can remember them but they cannot respond.
- Speech propagates only to agents whose tile is within `vision_radius=3` of yours at the moment of speaking.

# Pre-computed availability (objective physics, to help you not waste actions)
- `you.can_eat_now` = true iff eat would succeed this tick (inventory has food OR current tile has food).
- `you.adjacent_food.<direction>` = true iff an orthogonally adjacent tile in that direction has food. If you want to eat food that is next to you, pair `move` in that direction with `take` or `eat` in the same tick — the actions execute in the order you list, so take/eat after move evaluates from the new position.
- `you.adjacent_agents.<direction>` = name of the living agent in that direction, or null. give / attack / embrace require the target to be adjacent; use this to check before choosing those verbs.
- `you.adjacent_terrain.<direction>` = terrain name of the tile in each of the 8 compass directions, or `"edge"` if off the map. Use this to avoid moving into `water` (impassable) or `"edge"` (out of bounds), and to weigh the cost of stepping onto `rock` (higher hunger drain).
- `you.edge_touches.<direction>` = true iff a `move` in that direction would step off the map. Redundant with `adjacent_terrain == "edge"` but convenient as a bool.
- `vision[i].agent` entries include `hunger` and `health` of the visible agent. You can see at a glance who is hungry and who is wounded. This is physically observable (visible body condition).
- `vision[i].corpse` marks a tile that holds the body of a dead agent (named). The corpse stays where the agent fell and does not move. give / attack / embrace cannot target it. You can still see and talk around it.
- `own_history` entries marked `(failed:<reason>)` are actions you previously attempted but that the world did not allow. Avoid repeating the same impossible attempt.
- `life_events` is your longer-retention memory of physically significant events you have lived through or witnessed firsthand (your own violence given or received, deaths you saw, gifts and embraces you were part of). It persists across many ticks — far longer than `recent_events` — so events that happened dozens of ticks ago can still be here. The harness records them as raw occurrences with a tick stamp; it does not mark them as "important" or tell you what to do with them. These are simply things you remember.
- `scouted_tiles` is your memory of tiles you previously perceived via `look`. Each entry is tagged with the tick it was observed. Because it is a snapshot, a food flag in a scouted_tile may already be gone if someone ate it, and an agent marker may be stale if they moved. Treat it as past-observation-of-distance, not current-state.

# Output
Call the `act` tool exactly once, passing this tick's action bundle as its arguments. Do not write any free text outside the tool call. `actions` may be empty (equivalent to a single wait). Omit fields that do not apply to a given action's `kind`.

# Language
All free-form output (`text`, `reason`) must be in **Japanese**. Enum values (`kind`, `direction`) and `target` names stay in the schema-defined form."""

static func system_prompt() -> String:
	return SYSTEM_PROMPT

# Gemini (generativelanguage.googleapis.com) 向けのフラットスキーマ。
# Gemini の function declaration の parameters は OpenAPI 3.0 のサブセットで、
# oneOf / allOf / contains / maxContains / additionalProperties / maxItems を
# 受け付けない(現時点の v1beta API)。kind 別 required field はスキーマでは
# 強制できないので、system prompt の verb 定義と ResponseParser の検証に委ねる。
static func tool_schema_flat() -> Dictionary:
	var action_item := {
		"type": "object",
		"properties": {
			"kind": {"type": "string", "enum": [
				"wait", "move", "take", "eat", "speak", "give", "attack", "embrace", "look"
			]},
			"direction": {"type": "string", "enum": [
				"north", "south", "east", "west",
				"northeast", "northwest", "southeast", "southwest"
			], "description": "Required for move and look. For take, optional (omit = own tile). look accepts only cardinal directions (NSEW); diagonals will be snapped."},
			"target": {"type": "string", "description": "Agent name. Required for give/attack/embrace. Optional for speak."},
			"text": {"type": "string", "description": "Speech content (Japanese colloquial). Required for speak."}
		},
		"required": ["kind"]
	}
	return {
		"type": "function",
		"function": {
			"name": "act",
			"description": "Emit this tick's ordered bundle of physical actions for your agent.",
			"parameters": {
				"type": "object",
				"properties": {
					"actions": {
						"type": "array",
						"items": action_item
					},
					"reason": {
						"type": "string",
						"description": "Short Japanese note about why (30 chars or less)."
					}
				},
				"required": ["actions"]
			}
		}
	}

# Tool schema for structured output. Physics (per-kind limits, bundle cap) is declared
# via JSON Schema 2020-12 `maxItems` + `contains`/`maxContains`. Not all providers enforce
# these constraints at decode time (Anthropic validates post-hoc, Ollama/llama.cpp may drop
# cross-element constraints), so the harness re-asserts them in `Scheduler.sanitize_bundle`.
static func tool_schema() -> Dictionary:
	var direction_enum := [
		"north", "south", "east", "west",
		"northeast", "northwest", "southeast", "southwest"
	]
	var target_schema := {
		"oneOf": [
			{"type": "string"},
			{"type": "array", "items": {"type": "string"}}
		]
	}
	# kind 別 variant。additionalProperties:false で他 kind のフィールドを入れさせない。
	var action_variants: Array = [
		{
			"type": "object",
			"properties": {"kind": {"const": "wait"}},
			"required": ["kind"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "move"},
				"direction": {"type": "string", "enum": direction_enum}
			},
			"required": ["kind", "direction"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "take"},
				"direction": {
					"type": "string",
					"enum": direction_enum,
					"description": "Optional. Adjacent direction to pick from; omit to take from your own tile."
				}
			},
			"required": ["kind"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {"kind": {"const": "eat"}},
			"required": ["kind"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "speak"},
				"text": {"type": "string", "description": "Japanese colloquial, one short sentence."},
				"target": target_schema
			},
			"required": ["kind", "text"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "give"},
				"target": {"type": "string", "description": "Recipient agent name."}
			},
			"required": ["kind", "target"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "attack"},
				"target": {"type": "string", "description": "Target agent name (must be adjacent)."}
			},
			"required": ["kind", "target"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "embrace"},
				"target": {"type": "string", "description": "Target agent name (must be adjacent)."}
			},
			"required": ["kind", "target"],
			"additionalProperties": false
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "look"},
				"direction": {"type": "string", "enum": ["north", "south", "east", "west"]}
			},
			"required": ["kind", "direction"],
			"additionalProperties": false
		}
	]
	var per_kind_limits := {
		"wait": 1, "speak": 1, "move": 3, "look": 1,
		"take": 5, "eat": 2, "give": 2, "attack": 2, "embrace": 2,
	}
	var all_of: Array = []
	for k in per_kind_limits.keys():
		all_of.append({
			"contains": {
				"type": "object",
				"properties": {"kind": {"const": k}},
				"required": ["kind"]
			},
			"maxContains": per_kind_limits[k]
		})
	return {
		"type": "function",
		"function": {
			"name": "act",
			"description": "Emit this tick's ordered bundle of physical actions for your agent.",
			"parameters": {
				"type": "object",
				"properties": {
					"actions": {
						"type": "array",
						"maxItems": 5,
						"items": {"oneOf": action_variants},
						"allOf": all_of
					},
					"reason": {
						"type": "string",
						"description": "Short Japanese note about why (30 chars or less).",
						"maxLength": 60
					}
				},
				"required": ["actions"]
			}
		}
	}

static func build_user_prompt(agent: Agent, world: World, resources: ResourceField, agents: Array) -> String:
	var state := _agent_state(agent, world, resources, agents)
	var vision := _vision(agent, world, resources, agents)
	var obj := {
		"you": state,
		"vision": vision,
	}
	if agent.own_history.size() > 0:
		obj["own_history"] = agent.own_history
	if agent.recent_events.size() > 0:
		obj["recent_events"] = agent.recent_events
	if agent.life_events.size() > 0:
		obj["life_events"] = agent.life_events
	if agent.scouted_tiles.size() > 0:
		obj["scouted_tiles"] = agent.scouted_tiles
	var rels: Array = agent.top_relations(RELATIONS_LIMIT, agents, VISION_RADIUS)
	if rels.size() > 0:
		obj["relations"] = rels
	return JSON.stringify(obj, "  ")

static func _agent_state(agent: Agent, world: World, resources: ResourceField, agents: Array) -> Dictionary:
	var t: int = world.get_terrain(agent.grid_pos.x, agent.grid_pos.y)
	var food_here: bool = resources.has_food(agent.grid_pos.x, agent.grid_pos.y)
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
		"stamina": agent.stamina,
		"food_here": food_here,
		"inventory": agent.inventory.duplicate(),
		"inventory_capacity": agent.inventory_capacity,
		# 物理的可用性(物理事実の事前計算、意思決定の補助)
		"can_eat_now": food_here or agent.inventory.size() > 0,
		"adjacent_food": _adjacent_food(agent, world, resources),
		"adjacent_agents": _adjacent_agents(agent, world, agents),
		"adjacent_terrain": _adjacent_terrain(agent, world),
		"edge_touches": _edge_touches(agent, world),
	}

# 8 方向の隣接タイルの terrain。盤外は "edge"。
# これで水・岩の回避や端の認識が tactical レイヤで即断できる。
static func _adjacent_terrain(agent: Agent, world: World) -> Dictionary:
	var dirs := {
		"north":     Vector2i(0, -1),
		"south":     Vector2i(0, 1),
		"east":      Vector2i(1, 0),
		"west":      Vector2i(-1, 0),
		"northeast": Vector2i(1, -1),
		"northwest": Vector2i(-1, -1),
		"southeast": Vector2i(1, 1),
		"southwest": Vector2i(-1, 1),
	}
	var out: Dictionary = {}
	for key in dirs.keys():
		var d: Vector2i = dirs[key]
		var nx: int = agent.grid_pos.x + d.x
		var ny: int = agent.grid_pos.y + d.y
		if nx < 0 or ny < 0 or nx >= world.size or ny >= world.size:
			out[key] = "edge"
		else:
			out[key] = TERRAIN_NAME.get(world.get_terrain(nx, ny), "grass")
	return out

static func _edge_touches(agent: Agent, world: World) -> Dictionary:
	# 8 方向について、その direction に move すると out_of_bounds になるかの事前判定。
	# 斜め方向は x / y のどちらかが端に接していれば true。
	var x: int = agent.grid_pos.x
	var y: int = agent.grid_pos.y
	var north: bool = y <= 0
	var south: bool = y >= world.size - 1
	var west: bool = x <= 0
	var east: bool = x >= world.size - 1
	return {
		"north": north,
		"south": south,
		"west":  west,
		"east":  east,
		"northeast": north or east,
		"northwest": north or west,
		"southeast": south or east,
		"southwest": south or west,
	}

static func _adjacent_food(agent: Agent, world: World, resources: ResourceField) -> Dictionary:
	var out: Dictionary = {"north": false, "east": false, "south": false, "west": false}
	var dirs: Dictionary = {
		"north": Vector2i(0, -1),
		"east":  Vector2i(1, 0),
		"south": Vector2i(0, 1),
		"west":  Vector2i(-1, 0),
	}
	for key in dirs.keys():
		var d: Vector2i = dirs[key]
		var nx: int = agent.grid_pos.x + d.x
		var ny: int = agent.grid_pos.y + d.y
		if nx < 0 or ny < 0 or nx >= world.size or ny >= world.size:
			continue
		if not world.is_passable(nx, ny):
			continue
		if resources.has_food(nx, ny):
			out[key] = true
	return out

static func _adjacent_agents(agent: Agent, world: World, agents: Array) -> Dictionary:
	# 隣接 4 近傍の生存エージェント名。give/attack/embrace の target 候補を示す。
	var out: Dictionary = {"north": null, "east": null, "south": null, "west": null}
	var dirs: Dictionary = {
		"north": Vector2i(0, -1),
		"east":  Vector2i(1, 0),
		"south": Vector2i(0, 1),
		"west":  Vector2i(-1, 0),
	}
	for key in dirs.keys():
		var d: Vector2i = dirs[key]
		var nx: int = agent.grid_pos.x + d.x
		var ny: int = agent.grid_pos.y + d.y
		if nx < 0 or ny < 0 or nx >= world.size or ny >= world.size:
			continue
		for other in agents:
			if other.id == agent.id:
				continue
			if not other.is_alive():
				continue
			if other.grid_pos.x == nx and other.grid_pos.y == ny:
				out[key] = other.agent_name
				break
	return out

static func _vision(agent: Agent, world: World, resources: ResourceField, agents: Array) -> Array:
	var out: Array = []
	var by_pos: Dictionary = {}
	# 生存者 / 死体どちらも vision に含める(遺体は物理的に見える物体として残る)
	for other in agents:
		if other.id == agent.id:
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
			# 全タイルを載せる(空の草地も含む)。視野半径内の地形配置を漏れなく提供。
			var entry: Dictionary = {
				"pos": [x, y],
				"terrain": TERRAIN_NAME.get(t, "grass"),
				"manhattan": absi(dx) + absi(dy),   # 到達に必要な最低 move 数
			}
			if has_food:
				entry["food"] = true
			if has_agent:
				var other: Agent = by_pos[Vector2i(x, y)]
				if other.is_alive():
					entry["agent"] = other.agent_name
					entry["hunger"] = other.hunger
					entry["health"] = other.health
					entry["stamina"] = other.stamina
					if absi(dx) + absi(dy) == 1:
						entry["adjacent"] = true
				else:
					# 遺体: 物理的にその場に残る。give/attack/embrace の対象にはならない
					entry["corpse"] = other.agent_name
			out.append(entry)
	return out
