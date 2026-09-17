import { describe, expect, it } from "vitest";
import { createWorld, defaultCognition } from "../src/simulation/world";
import { availableActions, destination } from "../src/simulation/actions";
import { applyAction, commitTick } from "../src/simulation/engine";
import {
  observation,
  shouldThink,
  validateGoal,
} from "../src/simulation/cognition";
import { demoTick } from "../src/simulation/demo";
function fixture() {
  const w = createWorld(42);
  w.terrain = w.terrain.map((row) => row.map(() => "grass" as const));
  w.food = w.food.map((row) => row.map(() => false));
  w.agents = w.agents.slice(0, 2);
  Object.assign(w.agents[0], {
    x: 5,
    y: 5,
    inventory: 1,
    stamina: 100,
    hunger: 50,
    gender: "female",
    age: 2,
  });
  Object.assign(w.agents[1], {
    x: 6,
    y: 5,
    inventory: 0,
    stamina: 100,
    hunger: 50,
    gender: "male",
    age: 2,
  });
  return w;
}
describe("physical action catalog", () => {
  it("does not mutate state or consume random numbers", () => {
    const w = fixture(),
      before = structuredClone(w);
    availableActions(w, w.agents[0]);
    expect(w).toEqual(before);
  });
  it("slides across occupied tiles, blocks water, and allows diagonal pickup", () => {
    const w = fixture(),
      a = w.agents[0];
    expect(destination(w, a, { x: 1, y: 0 })).toEqual({ x: 7, y: 5 });
    w.terrain[5][7] = "water";
    expect(destination(w, a, { x: 1, y: 0 })).toBeNull();
    w.food[4][4] = true;
    expect(availableActions(w, a).some((c) => c.id === "take:-1:-1")).toBe(
      true,
    );
  });
  it("uses vision for give but cardinal adjacency for touch and reproduction", () => {
    const w = fixture(),
      a = w.agents[0],
      b = w.agents[1];
    b.x = 7;
    b.y = 7;
    const actions = availableActions(w, a);
    expect(actions.some((c) => c.kind === "give")).toBe(true);
    expect(
      actions.some((c) =>
        ["attack", "embrace", "teach", "reproduce_with"].includes(c.kind),
      ),
    ).toBe(false);
  });
  it("keeps full hunger eat and low libido reproduction physically available", () => {
    const w = fixture(),
      a = w.agents[0];
    a.hunger = 100;
    a.libido = 0;
    const actions = availableActions(w, a);
    expect(actions.some((c) => c.kind === "eat")).toBe(true);
    expect(actions.some((c) => c.kind === "reproduce_with")).toBe(true);
  });
  it("rejects stale food without taking another action", () => {
    const w = fixture(),
      a = w.agents[0];
    w.food[a.y][a.x] = true;
    const action = availableActions(w, a).find((c) => c.id === "take:0:0")!;
    w.food[a.y][a.x] = false;
    expect(applyAction(w, a, action)).toBe(false);
    expect(a.inventory).toBe(1);
  });
  it("exhaustion excludes expensive actions; wait remains", () => {
    const w = fixture(),
      a = w.agents[0];
    a.stamina = 0;
    expect(availableActions(w, a).map((c) => c.kind)).toEqual(["wait", "eat"]);
  });
  it("teach preserves speaker and hearsay, speech reaches all nearby listeners", () => {
    const w = fixture(),
      a = w.agents[0],
      b = w.agents[1];
    const action = availableActions(w, a).find((c) => c.kind === "teach")!;
    expect(
      applyAction(w, a, { ...action, text: "森の奥には空を飛ぶ魚がいる。" }),
    ).toBe(true);
    expect(b.memories.at(-1)).toMatchObject({
      source: "heard",
      sourceId: a.id,
      text: "森の奥には空を飛ぶ魚がいる。",
    });
  });
  it("only produces one child for a pair in a tick; newborns do not act or decay", () => {
    const w = fixture();
    w.config.costs.reproduce_success_prob = 1;
    const [a, b] = w.agents;
    const decisions = new Map(
      w.agents.map((a) => [
        a.id,
        [availableActions(w, a).find((c) => c.kind === "reproduce_with")!],
      ]),
    );
    commitTick(w, decisions);
    expect(w.agents).toHaveLength(3);
    expect(w.agents[2].parents).toEqual([a.id, b.id]);
    expect(w.agents[2].age).toBe(0);
    expect(w.agents[2].lastAction).toBe("wait");
  });
  it("keeps action resolution independent of response insertion order", () => {
    const a = fixture(),
      b = structuredClone(a);
    const pairs = a.agents.map(
      (x) =>
        [
          x.id,
          [
            availableActions(a, x).find((c) => c.kind === "give") ??
              availableActions(a, x)[0],
          ],
        ] as const,
    );
    commitTick(a, new Map(pairs));
    commitTick(b, new Map([...pairs].reverse()));
    expect(a).toEqual(b);
  });
});
describe("perception and cognition", () => {
  it("does not reveal remote deaths or private memories", () => {
    const w = fixture(),
      [a, b] = w.agents;
    b.x = 19;
    b.y = 19;
    b.health = 0;
    b.memories.push({
      id: "private",
      tick: 0,
      text: "private-secret",
      source: "experienced",
      relatedIds: [],
      position: { x: 19, y: 19 },
    });
    a.relations[b.id] = { affection: 99, trust: 80 };
    const state = JSON.stringify(observation(w, a));
    expect(state).not.toContain("private-secret");
    expect(state).not.toContain('"alive":false');
  });
  it("does not start another thought during cooldown or existing thought", () => {
    const w = fixture(),
      a = w.agents[0];
    a.judgment = {
      tick: 0,
      selected: "wait",
      probabilities: { wait: 1 },
      labels: { wait: "wait" },
      confidence: 1,
      needsDeliberation: 0.9,
      source: "jev",
    };
    expect(shouldThink(w, a)).toBe(true);
    a.cognition.status = "thinking";
    expect(shouldThink(w, a)).toBe(false);
    a.cognition.status = "completed";
    a.cognition.lastThoughtTick = 0;
    expect(shouldThink(w, a)).toBe(false);
  });
  it("rejects physically impossible inventory goals", () => {
    const w = fixture();
    expect(() =>
      validateGoal(
        {
          description: "食料を貯める",
          priority: 0.8,
          successConditions: [{ type: "inventory_count", value: 30 }],
          constraints: [],
          relevantAgentIds: [],
        },
        w.agents[0],
        w,
      ),
    ).toThrow();
  });
});
it("runs and restores a seeded world for 100 ticks without non-finite bodies or terrain violations", () => {
  let w = createWorld(5);
  for (let i = 0; i < 100; i++) {
    demoTick(w);
    if (i === 50) w = JSON.parse(JSON.stringify(w));
    for (const a of w.agents) {
      expect(Number.isFinite(a.health)).toBe(true);
      expect(a.inventory).toBeGreaterThanOrEqual(0);
      expect(a.inventory).toBeLessThanOrEqual(a.capacity);
      expect(w.terrain[a.y][a.x]).not.toBe("water");
    }
    expect(w.agents.filter((a) => a.health > 0).length).toBeLessThanOrEqual(
      w.config.maxPopulation,
    );
  }
  expect(w.tick).toBe(100);
});
