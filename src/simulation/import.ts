import { ACTION_NAMES, type WorldState } from "./types";
import { DEFAULT_CONFIG } from "./world";
import { validateGoal } from "./cognition";

const invalid = () => {
  throw new Error("世界ファイルの形式や値が不正です");
};
const object = (v: unknown): Record<string, any> => {
  if (!v || typeof v !== "object" || Array.isArray(v)) return invalid();
  return v as Record<string, any>;
};
const number = (
  v: unknown,
  min = 0,
  max = Number.MAX_SAFE_INTEGER,
  integer = false,
) => {
  if (
    typeof v !== "number" ||
    !Number.isFinite(v) ||
    v < min ||
    v > max ||
    (integer && !Number.isSafeInteger(v))
  )
    invalid();
};
const string = (v: unknown, max = 1000) => {
  if (typeof v !== "string" || v.length > max) invalid();
};
const list = (v: unknown, check: (v: any) => void, max = 10000): void => {
  if (!Array.isArray(v) || v.length > max) return invalid();
  v.forEach(check);
};
const choice = (v: unknown, choices: string[]) => {
  if (typeof v !== "string" || !choices.includes(v)) invalid();
};
const optional = (v: unknown, check: (v: any) => void) => {
  if (v !== undefined) check(v);
};
const textList = (v: unknown) => list(v, (s) => string(s, 1000), 100);

/** Validate an untrusted export before handing it to the simulation or renderer. */
export function parseWorld(value: unknown): WorldState {
  const w = object(value),
    c = object(w.config);
  if (w.version !== 2) invalid();
  string(w.id, 100);
  string(w.name, 100);
  string(w.disposition, 5000);
  number(w.seed, -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, true);
  number(w.rng, -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, true);
  for (const key of ["tick", "day", "createdAt"]) number(w[key]);
  number(c.size, 12, 28, true);
  number(c.population, 2, 40, true);
  number(c.ticksPerDay, 1, 100000, true);
  number(c.elderAge, 0, 100000);
  number(c.maxPopulation, 2, 100, true);
  for (const key of [
    "initialFood",
    "foodRegen",
    "deliberationThreshold",
    "top1Threshold",
    "marginThreshold",
  ])
    number(c[key], 0, 1);
  for (const key of ["thoughtCooldown", "thoughtMaxAge"])
    number(c[key], 0, 100000, true);
  const costs = object(c.costs);
  for (const key of Object.keys(DEFAULT_CONFIG.costs))
    number(costs[key], 0, 100000);
  number(costs.reproduce_success_prob, 0, 1);
  choice(w.mode, ["demo", "jev", "legacy_llm"]);
  optional(w.narrativeLanguage, (value) => choice(value, ["ja", "en"]));
  const terrain = (v: unknown) =>
    choice(v, ["grass", "forest", "water", "rock"]);
  const grid = (v: unknown, check: (v: any) => void) => {
    if (!Array.isArray(v) || v.length !== c.size) invalid();
    list(
      v,
      (row) => {
        if (!Array.isArray(row) || row.length !== c.size) invalid();
        list(row, check, c.size);
      },
      c.size,
    );
  };
  grid(w.terrain, terrain);
  grid(w.food, (v) => {
    if (typeof v !== "boolean") invalid();
  });
  const point = (v: unknown) => {
    const p = object(v);
    number(p.x, 0, c.size - 1, true);
    number(p.y, 0, c.size - 1, true);
  };
  const id = (v: unknown) => number(v, 0, Number.MAX_SAFE_INTEGER, true);
  const ids = new Set<number>();
  list(w.agents, (v) => {
    const a = object(v);
    id(a.id);
    if (ids.has(a.id)) invalid();
    ids.add(a.id);
    point(a);
    string(a.name, 100);
    if (typeof a.color !== "string" || !/^#[0-9a-f]{6}$/i.test(a.color))
      invalid();
    choice(a.gender, ["female", "male"]);
    for (const key of ["health", "hunger", "stamina", "libido", "aggression"])
      number(a[key], 0, 100);
    for (const key of ["age", "generation", "capacity", "inventory"])
      number(a[key], 0, 100000, true);
    if (a.inventory > a.capacity) invalid();
    list(a.parents, id, 2);
    const personality = object(a.personality);
    for (const key of ["cooperative", "aggressive", "curious"])
      number(personality[key], 0, 100);
    for (const r of Object.values(object(a.relations))) {
      const relation = object(r);
      number(relation.affection, -100, 100);
      number(relation.trust, 0, 100);
    }
    list(
      a.memories,
      (v) => {
        const m = object(v);
        string(m.id);
        string(m.text, 5000);
        number(m.tick);
        point(m.position);
        choice(m.source, ["experienced", "witnessed", "heard"]);
        optional(m.sourceId, id);
        list(m.relatedIds, id);
      },
      256,
    );
    list(a.scouted, (v) => {
      const s = object(v);
      point(s);
      terrain(s.terrain);
      number(s.tick);
      if (typeof s.food !== "boolean") invalid();
      optional(s.occupant, string);
    });
    const cognition = object(a.cognition);
    number(cognition.revision);
    number(cognition.lastThoughtTick, -100000);
    choice(cognition.status, [
      "idle",
      "thinking",
      "completed",
      "discarded",
      "error",
    ]);
    for (const key of ["beliefs", "priorities", "plan"])
      textList(cognition[key]);
    optional(cognition.note, string);
    optional(cognition.assessments, (v) => {
      for (const entry of Object.values(object(v))) {
        const r = object(entry);
        number(r.tick);
        number(r.probability, 0, 1);
      }
    });
    choice(a.lastAction, Object.keys(ACTION_NAMES));
    string(a.lastActionLabel);
    optional(a.diedAt, number);
    optional(a.speech, (v) => {
      const s = object(v);
      string(s.text, 1000);
      number(s.tick);
      optional(s.targetId, id);
    });
    optional(a.judgment, (v) => {
      const j = object(v);
      number(j.tick);
      string(j.selected);
      number(j.confidence, 0, 1);
      number(j.needsDeliberation, 0, 1);
      choice(j.source, ["demo", "jev", "legacy"]);
      optional(j.error, string);
      Object.values(object(j.probabilities)).forEach((p) => number(p, 0, 1));
      Object.values(object(j.labels)).forEach((s) => string(s));
    });
  });
  // Cross references can be checked only after all individuals are known.
  for (const a of w.agents) validateGoal(a.cognition.goal, a, w as WorldState);
  list(
    w.events,
    (v) => {
      const e = object(v);
      string(e.id);
      string(e.kind, 100);
      string(e.text, 5000);
      number(e.tick);
      optional(e.actorId, id);
      optional(e.targetId, id);
      optional(e.position, point);
      optional(e.success, (v) => {
        if (typeof v !== "boolean") invalid();
      });
    },
    1000,
  );
  const usage = object(w.usage);
  for (const role of ["system1", "thought", "language", "legacy"]) {
    const u = object(usage[role]);
    for (const key of [
      "input",
      "output",
      "usd",
      "requests",
      "latencyMs",
      "failures",
    ])
      number(u[key]);
    optional(u.unpricedRequests, number);
  }
  return w as WorldState;
}
