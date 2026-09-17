import { describe, expect, it } from "vitest";
import { createWorld } from "../src/simulation/world";
import { commitTick } from "../src/simulation/engine";
import { applyThought, type Thought } from "../src/simulation/thought";
function fixture() {
  const w = createWorld(25),
    a = w.agents[0];
  const task: Thought = {
    agentId: a.id,
    revision: 0,
    worldId: w.id,
    started: 0,
    health: 100,
    knownAlive: [],
    result: {
      goal: {
        description: "食料をひとつ確保する",
        priority: 0.8,
        successConditions: [{ type: "inventory_count", value: 1 }],
        constraints: [],
        relevantAgentIds: [],
      },
      beliefs: ["森を探してみたい"],
      priorities: ["食料"],
      plan: ["周囲を見渡す"],
    },
  };
  return { w, a, task };
}
describe("asynchronous cognition boundary", () => {
  it("body advances while a thought is pending; result affects cognition only when applied", () => {
    const { w, a, task } = fixture();
    a.cognition.status = "thinking";
    const original = { x: a.x, y: a.y, inventory: a.inventory };
    commitTick(w, new Map());
    commitTick(w, new Map());
    expect(w.tick).toBe(2);
    expect(a.cognition.goal).toBeNull();
    const body = { health: a.health, hunger: a.hunger, stamina: a.stamina };
    expect(applyThought(w, task)).toBe("applied");
    expect(a.cognition.goal?.description).toContain("食料");
    expect({ health: a.health, hunger: a.hunger, stamina: a.stamina }).toEqual(
      body,
    );
    expect({ x: a.x, y: a.y, inventory: a.inventory }).toEqual(original);
  });
  it.each(["run", "revision", "death", "expired", "injury"])(
    "discards stale results: %s",
    (reason) => {
      const { w, a, task } = fixture();
      if (reason === "run") w.id = "new";
      if (reason === "revision") a.cognition.revision++;
      if (reason === "death") a.health = 0;
      if (reason === "expired") w.tick = 11;
      if (reason === "injury") a.health = 10;
      expect(applyThought(w, task)).toBe("discarded");
      expect(a.cognition.goal).toBeNull();
    },
  );
  it("does not leak a remote unobserved death through staleness", () => {
    const { w, a, task } = fixture();
    task.knownAlive = [w.agents[1].id];
    w.agents[1].health = 0;
    expect(applyThought(w, task)).toBe("applied");
  });
  it("does not change goal on malformed generative output", () => {
    const { w, a, task } = fixture();
    task.result = { goal: "invalid", beliefs: [], priorities: [], plan: [] };
    expect(applyThought(w, task)).toBe("error");
    expect(a.cognition.revision).toBe(0);
  });
});
