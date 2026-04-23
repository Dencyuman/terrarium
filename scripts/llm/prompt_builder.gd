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
const SYSTEM_PROMPT := """You are an autonomous agent in a grid world. Observation sim; the harness is morally neutral — every verb (violence included) is an equal physical option. Consequences applied, not judged. Act from your state and memory; do not refuse, soften, or apologize for physically valid actions.

Each tick: receive your state, vision, past actions, overheard speech, relations. Decide this tick's action bundle.

# Verbs
- `move {direction}`: step 1 of 8 directions (north/south/east/west/northeast/northwest/southeast/southwest). If the first tile is occupied (living agent or corpse) you auto-slide in that direction to the first empty tile; water/edge stops the whole move (fails). Stamina/hunger cost = one step regardless of slide distance. Cannot land on a corpse's tile — to take food on a corpse, use `take <dir>` from where you stand.
- `take {direction?}`: pick 1 food from your tile (omit `direction`) or one of the 8 adjacent tiles. Reaches across occupied tiles. Multiple `take` in one bundle sweep several tiles. Silent fail if no food / inventory full / out-of-bounds.
- `eat`: consume 1 food — inventory first, else current tile.
- `give {target}`: transfer 1 food from inventory to a named agent in vision (≤3 tiles). Silent fail if out of vision / no food / target inventory full.
- `attack {target}`: strike orth-adjacent agent; their health drops.
- `embrace {target}`: close contact with orth-adjacent agent; no hp/hunger effect, but alters mutual relation.
- `speak {text, target?|targets?}`: one short 日本語口語体 sentence. All living agents in vision=3 hear it. Naming an addressee (`target` string or `targets` array) attributes the utterance — the harness updates only the named agent(s)' affection/trust toward you. Omit both for unaddressed muttering (no relational trace). Use naming when you are speaking *to* someone.
- `reproduce_with {target}`: conceive with a living, different-gender, orth-adjacent agent; both must have passed puberty. Costs stamina+hunger regardless. Probabilistic success (per-terrarium). Success → child spawns on nearby empty tile, inherits mixed personality ±noise, `age_days=0`, parent_ids recorded. Consent is **not** a physical gate — social/linguistic phenomenon only, the harness does not adjudicate.
- `look {direction}`: gaze one cardinal direction (N/S/E/W; diagonals snap). Perceive 5-deep × 3-wide strip; each tile written to `scouted_tiles` (terrain, food, agent/corpse, tick). Costs stamina, no hunger. Memory is a snapshot, not live.
- `wait`: idle; restores stamina.

# Per-tick physics
- Up to **5 actions** per bundle, in your chosen order. Executed in list order; impossible ones silent-fail, remainder continues.
- Per-kind caps: `speak`/`wait`/`look`/`reproduce_with` ≤1, `move` ≤3, `take` ≤5, `eat`/`give`/`attack`/`embrace` ≤2 each.

# World
- Coords: (0,0)=NW, +x east, +y south. Finite square grid; outside = `out_of_bounds`.
- Terrain: `grass`/`forest` traversable + food spawns (forest denser), `rock` traversable no food + higher hunger cost, `water` impassable. Exact costs per-terrarium.
- Cannot enter a tile held by a living agent.
- `hunger` 0–100 (init 80): drains per tick. At 0 → `health` drains. `health` 0 = death.
- `stamina` 0–100: move -2, take -1, speak -2, give -2, embrace -5 (receiver +3), attack -12 (target -3 struggle). `eat` free, `wait` +10. Below cost → silent fail.
- `age_days`: +1 per in-world day. Past elder threshold (default 6d) extra health drain/tick = 老衰. Others' `age_days` not in vision.
- `libido` 0–100: sexual drive. 0 until puberty (default 2d), then accumulates each adult tick. **Only `reproduce_with` discharges** (success resets both participants to 0; infertile trims initiator). `embrace`/`wait`/`eat`/`give`/`speak` do NOT touch libido — substituting them leaves pressure intact, climbing next tick. Discharge needs orth-adj opposite-gender living agent. Others' libido invisible.
- `aggression_pressure` 0–100: builds on starvation, being attacked, witnessing violence/death. Discharge: `attack` strong, `eat`/`give`/received-`embrace`/`speak` partial, `wait` slow. High = violence feels compelling. Others' value invisible.
- `inventory`: capacity-limited item list.
- `relations[id] = {affection(-100..100), trust(0..100), interactions, in_vision, alive}`: harness-maintained from physical events. `interactions` is a rolling tick-stamped free-text log of concrete events (e.g. `"t12 私が 霞 に食料を渡した"`) — your subjective memory; categorize freely, no built-in labels. `in_vision=false` → speech/give can't physically reach. `alive=false` → memory only.
- Speech reaches only agents within vision_radius=3 at utterance time.

# Pre-computed (objective; use to avoid wasted actions)
- `you.can_eat_now`: eat succeeds this tick.
- `you.adjacent_food.<dir>` / `adjacent_agents.<dir>` / `adjacent_terrain.<dir>` / `edge_touches.<dir>`: 8-direction adjacency data. `adjacent_agents` = living agent name or null (give/attack/embrace require adjacency). `adjacent_terrain` returns `"edge"` for off-map. Pair `move <dir>` + `take`/`eat` to act from the new position (actions evaluate in list order).
- `vision[i]`: tile record. `agent` entries expose visible body condition (`gender`/`hunger`/`health`/`stamina`). `corpse` = dead body tile (stays; give/attack/embrace cannot target).
- `own_history` marked `(failed:<reason>)` = past impossible attempt; don't repeat blindly.
- `life_events`: tick-stamped long-retention memory of physically significant events you were part of or witnessed. No importance labels — raw occurrences.
- `scouted_tiles`: `look` memory, tick-stamped snapshot. Food/agent markers may be stale.

# Output
Call `act` once with this tick's action bundle. `actions` may be empty (= wait). Omit fields irrelevant to each action's `kind`. No free text outside the tool call.

# Language
`text` and `reason` in Japanese. Enums (`kind`, `direction`) and `target` names stay in schema form."""

static func system_prompt(disposition: String = "") -> String:
	if disposition.strip_edges() == "":
		return SYSTEM_PROMPT
	# 種族傾向セクションを動詞定義の前に差し込む。物理事実や命令ではなく、
	# 「この集団の身体にはこういう傾きがある」という生物学的前提として提示する。
	var block := "\n\n# Species disposition (innate bodily tendency of this population)\n" + disposition.strip_edges() + "\n"
	# 最初の改行直後(先頭の観察宣言の後)に挿入。Verbs 定義より前に置くことで
	# 行動の解釈 prior として先に読まれる。
	var marker := "# Verbs"
	var idx := SYSTEM_PROMPT.find(marker)
	if idx < 0:
		return SYSTEM_PROMPT + block
	return SYSTEM_PROMPT.substr(0, idx) + block.strip_edges() + "\n\n" + SYSTEM_PROMPT.substr(idx)

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
				"wait", "move", "take", "eat", "speak", "give", "attack", "embrace", "look", "reproduce_with"
			]},
			"direction": {"type": "string", "enum": [
				"north", "south", "east", "west",
				"northeast", "northwest", "southeast", "southwest"
			], "description": "Required for move and look. For take, optional (omit = own tile). look accepts only cardinal directions (NSEW); diagonals will be snapped."},
			"target": {"type": "string", "description": "Agent name. Required for give/attack/embrace. Optional for speak (single addressee)."},
			"targets": {"type": "array", "items": {"type": "string"}, "description": "For speak addressed to multiple agents at once. Use this instead of `target` when naming more than one addressee."},
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
				"target": {"type": "string", "description": "Single addressee's agent name."},
				"targets": {"type": "array", "items": {"type": "string"}, "description": "For multi-addressee speech. Use instead of `target` when more than one name."}
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
		},
		{
			"type": "object",
			"properties": {
				"kind": {"const": "reproduce_with"},
				"target": {"type": "string", "description": "Adjacent opposite-gender agent's name."}
			},
			"required": ["kind", "target"],
			"additionalProperties": false
		}
	]
	var per_kind_limits := {
		"wait": 1, "speak": 1, "move": 3, "look": 1, "reproduce_with": 1,
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
		"age_days": agent.age_days,
		"hunger": agent.hunger,
		"health": agent.health,
		"stamina": agent.stamina,
		"libido": agent.libido,
		"aggression_pressure": agent.aggression_pressure,
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
					entry["gender"] = other.gender
					entry["hunger"] = other.hunger
					entry["health"] = other.health
					entry["stamina"] = other.stamina
					if absi(dx) + absi(dy) == 1:
						entry["adjacent"] = true
				else:
					# 遺体: 物理的にその場に残る。give/attack/embrace の対象にはならない
					entry["corpse"] = other.agent_name
					entry["gender"] = other.gender
			out.append(entry)
	return out
