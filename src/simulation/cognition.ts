import type { Agent, Goal, WorldState } from "./types";
import { alive, distance } from "./world";
export function relevantMemories(w: WorldState, a: Agent) {
  const ids = new Set([
    ...w.agents
      .filter((b) => b.id !== a.id && distance(a, b) <= 3)
      .map((b) => b.id),
    ...(a.cognition.goal?.relevantAgentIds ?? []),
  ]);
  return a.memories
    .map((m) => ({
      m,
      score: m.relatedIds.some((id) => ids.has(id)) ? 1000 + m.tick : m.tick,
    }))
    .sort((a, b) => b.score - a.score)
    .slice(0, 10)
    .map((v) => ({ ...v.m, text: v.m.text.slice(0, 240) }));
}
export function goalProgress(a: Agent) {
  const goal = a.cognition.goal;
  if (!goal) return null;
  return goal.successConditions.map((c, i) => {
    switch (c.type) {
      case "inventory_count":
        return {
          condition: c,
          progress: Math.min(1, a.inventory / Math.max(1, c.value ?? 1)),
          achieved: a.inventory >= (c.value ?? 1),
        };
      case "position":
        return { condition: c, achieved: a.x === c.x && a.y === c.y };
      case "health":
        return { condition: c, achieved: a.health >= (c.value ?? 100) };
      default:
        return {
          condition: c,
          achieved: a.cognition.assessments?.[i]
            ? a.cognition.assessments[i].probability >= 0.8
            : null,
          probability: a.cognition.assessments?.[i]?.probability,
        };
    }
  });
}
export function observation(w: WorldState, a: Agent) {
  const visible = w.agents.filter((b) => b.id !== a.id && distance(a, b) <= 3);
  const known = new Set([
    ...visible.map((b) => b.id),
    ...a.memories.flatMap((m) => m.relatedIds),
  ]);
  const nearby = [];
  for (
    let y = Math.max(0, a.y - 3);
    y <= Math.min(w.config.size - 1, a.y + 3);
    y++
  )
    for (
      let x = Math.max(0, a.x - 3);
      x <= Math.min(w.config.size - 1, a.x + 3);
      x++
    ) {
      const b = visible.find((b) => b.x === x && b.y === y);
      nearby.push({
        x,
        y,
        terrain: w.terrain[y][x],
        food: w.food[y][x],
        ...(b
          ? {
              occupant: {
                id: b.id,
                name: b.name,
                gender: b.gender,
                health: b.health,
                stamina: b.stamina,
                hunger: b.hunger,
                alive: alive(b),
              },
            }
          : {}),
      });
    }
  return {
    agent: {
      id: a.id,
      name: a.name,
      body: {
        health: a.health,
        stamina: a.stamina,
        hunger: a.hunger,
        age_days: a.age,
        libido: a.libido,
        aggression_pressure: a.aggression,
      },
      personality: a.personality,
      inventory_food: a.inventory,
      inventory_capacity: a.capacity,
      position: { x: a.x, y: a.y },
      cognition: {
        goal: a.cognition.goal,
        beliefs: a.cognition.beliefs,
        priorities: a.cognition.priorities,
        plan: a.cognition.plan,
        progress: goalProgress(a),
      },
      relationships: Object.entries(a.relations)
        .filter(([id]) => known.has(Number(id)))
        .map(([id, r]) => ({
          id: Number(id),
          name: w.agents.find((b) => b.id === Number(id))?.name,
          ...r,
        })),
      relevant_memories: relevantMemories(w, a),
    },
    nearby,
    world: {
      tick: w.tick,
      day: w.day,
      size: w.config.size,
      hunger_definition: "0=starving,100=full; higher is more satiated",
      coordinates: "+x=east,+y=south",
      costs: w.config.costs,
    },
    recent_events: a.memories.filter((m) => m.tick >= w.tick - 2).slice(-5),
    scouted_tiles: a.scouted.slice(-12),
    disposition: w.disposition,
  };
}
export function shouldThink(w: WorldState, a: Agent) {
  const j = a.judgment;
  if (
    !j ||
    j.error ||
    a.cognition.status === "thinking" ||
    w.tick - a.cognition.lastThoughtTick < w.config.thoughtCooldown
  )
    return false;
  const probs = Object.values(j.probabilities).sort((a, b) => b - a);
  return (
    j.needsDeliberation > w.config.deliberationThreshold ||
    (probs[0] ?? 1) < w.config.top1Threshold ||
    (probs.length > 1 && probs[0] - probs[1] < w.config.marginThreshold)
  );
}
export function validateGoal(
  value: unknown,
  a: Agent,
  w: WorldState,
): Goal | null {
  if (value === null) return null;
  if (!value || typeof value !== "object") throw new Error("goal が不正です");
  const g = value as Goal;
  if (
    typeof g.description !== "string" ||
    !g.description.trim() ||
    g.description.length > 240 ||
    typeof g.priority !== "number" ||
    !Number.isFinite(g.priority) ||
    g.priority < 0 ||
    g.priority > 1 ||
    !Array.isArray(g.successConditions) ||
    g.successConditions.length > 6 ||
    !Array.isArray(g.constraints) ||
    !Array.isArray(g.relevantAgentIds)
  )
    throw new Error("goal の構造が不正です");
  if (
    g.constraints.some((s) => typeof s !== "string" || s.length > 240) ||
    g.constraints.length > 6 ||
    g.relevantAgentIds.some((id) => !w.agents.some((b) => b.id === id))
  )
    throw new Error("goal の参照が不正です");
  for (const c of g.successConditions) {
    if (
      !c ||
      !["inventory_count", "position", "health", "semantic"].includes(c.type)
    )
      throw new Error("目標条件が不正です");
    if (
      c.type === "inventory_count" &&
      (!Number.isInteger(c.value) || c.value! < 0 || c.value! > a.capacity)
    )
      throw new Error("所持上限を超える目標です");
    if (
      c.type === "position" &&
      (!Number.isInteger(c.x) ||
        !Number.isInteger(c.y) ||
        c.x! < 0 ||
        c.y! < 0 ||
        c.x! >= w.config.size ||
        c.y! >= w.config.size)
    )
      throw new Error("座標が不正です");
    if (
      c.type === "health" &&
      (typeof c.value !== "number" || c.value < 0 || c.value > 100)
    )
      throw new Error("体力条件が不正です");
    if (
      c.type === "semantic" &&
      (typeof c.description !== "string" ||
        !c.description.trim() ||
        c.description.length > 240)
    )
      throw new Error("意味条件が不正です");
  }
  return { ...g, createdAtTick: w.tick };
}
