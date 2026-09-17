import type { Agent, WorldState } from "./types";
import { alive } from "./world";
import { validateGoal } from "./cognition";
import { emit } from "./engine";
export interface Thought {
  agentId: number;
  revision: number;
  worldId: string;
  started: number;
  health: number;
  knownAlive: number[];
  result?: unknown;
  error?: string;
}
export function applyThought(
  w: WorldState,
  task: Thought,
): "applied" | "discarded" | "error" {
  const a = w.agents.find((a) => a.id === task.agentId);
  if (!a) return "discarded";
  const stale =
    w.id !== task.worldId ||
    !alive(a) ||
    a.cognition.revision !== task.revision ||
    w.tick - task.started > w.config.thoughtMaxAge ||
    (a.health < 30 && task.health >= 30) ||
    task.knownAlive.some((id) => {
      const b = w.agents.find((b) => b.id === id);
      return (
        !b ||
        (!alive(b) &&
          a.memories.some(
            (m) =>
              m.tick >= task.started &&
              m.relatedIds.includes(id) &&
              /倒れ|生涯|死/.test(m.text),
          ))
      );
    });
  if (stale || task.error) {
    a.cognition.status = stale ? "discarded" : "error";
    a.cognition.note = task.error ?? "考えている間に、重要な前提が変わった";
    emit(
      w,
      stale ? "thought_discarded" : "thought_failed",
      `${a.name}: ${a.cognition.note}`,
      a,
    );
    return stale ? "discarded" : "error";
  }
  try {
    const r = task.result as Record<string, unknown>;
    for (const key of ["beliefs", "priorities", "plan"])
      if (
        !Array.isArray(r[key]) ||
        r[key].length > 8 ||
        r[key].some((v: unknown) => typeof v !== "string" || v.length > 240)
      )
        throw new Error("熟考結果の形式が不正です");
    const before = a.cognition.goal?.description,
      goal = validateGoal(r.goal, a, w);
    const known = new Set([
      a.id,
      ...task.knownAlive,
      ...a.memories.flatMap((m) => m.relatedIds),
    ]);
    if (goal?.relevantAgentIds.some((id) => !known.has(id)))
      throw new Error("知らない人物への参照です");
    a.cognition = {
      ...a.cognition,
      assessments: {},
      goal,
      beliefs: r.beliefs as string[],
      priorities: r.priorities as string[],
      plan: r.plan as string[],
      revision: a.cognition.revision + 1,
      status: "completed",
      note: undefined,
    };
    emit(
      w,
      "thought_completed",
      `${a.name}の目標: ${before ?? "まだない"} → ${goal?.description ?? "まだない"}`,
      a,
    );
    return "applied";
  } catch (error) {
    a.cognition.status = "error";
    a.cognition.note =
      error instanceof Error ? error.message : "熟考結果が不正です";
    emit(w, "thought_failed", `${a.name}: 熟考結果を採用できなかった`, a);
    return "error";
  }
}
