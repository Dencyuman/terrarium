import base from "../../data/config.json";
import cast from "../../data/names.json";
import type {
  Agent,
  Cognition,
  Point,
  Terrain,
  Usage,
  WorldConfig,
  WorldState,
} from "./types";
export const PALETTE = [
  "#eebd87",
  "#b9cf9e",
  "#97c2c0",
  "#c5aed1",
  "#e0a899",
  "#b7bacf",
  "#d8cd8c",
  "#9fc8ab",
];
export const defaultCognition = (): Cognition => ({
  revision: 0,
  goal: null,
  beliefs: [],
  priorities: [],
  plan: [],
  lastThoughtTick: -100,
  status: "idle",
});
export const DEFAULT_CONFIG: WorldConfig = {
  size: 20,
  population: 20,
  ticksPerDay: 30,
  elderAge: 60,
  initialFood: 0.16,
  foodRegen: 0.012,
  costs: Object.fromEntries(
    Object.entries(base.costs).filter(([, v]) => typeof v === "number"),
  ) as Record<string, number>,
  deliberationThreshold: 0.7,
  top1Threshold: 0.5,
  marginThreshold: 0.1,
  thoughtCooldown: 5,
  thoughtMaxAge: 10,
  maxPopulation: 100,
};
export const clamp = (n: number, lo = 0, hi = 100) =>
  Math.max(lo, Math.min(hi, n));
export function random(w: { rng: number }) {
  let x = w.rng | 0;
  x ^= x << 13;
  x ^= x >>> 17;
  x ^= x << 5;
  w.rng = x >>> 0;
  return w.rng / 4294967296;
}
export function hash(x: number, y: number, seed: number) {
  let n = Math.imul(x + 123, 374761393) ^ Math.imul(y + 917, 668265263) ^ seed;
  n = Math.imul(n ^ (n >>> 13), 1274126177);
  return ((n ^ (n >>> 16)) >>> 0) / 4294967296;
}
export const inside = (w: WorldState, p: Point) =>
  p.x >= 0 && p.y >= 0 && p.x < w.config.size && p.y < w.config.size;
export const distance = (a: Point, b: Point) =>
  Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y));
export const adjacent = (a: Point, b: Point) =>
  Math.abs(a.x - b.x) + Math.abs(a.y - b.y) === 1;
export const alive = (a: Agent) => a.health > 0;
export function makeAgent(
  id: number,
  x: number,
  y: number,
  w: WorldState,
): Agent {
  const person = cast.agents[id % cast.agents.length];
  return {
    id,
    x,
    y,
    name:
      id < cast.agents.length
        ? person.name
        : `${["澪", "凪", "紡", "翠", "暁", "結"][id % 6]}${Math.floor(id / 6)}`,
    gender: person.gender as Agent["gender"],
    color: PALETTE[id % PALETTE.length],
    health: 100,
    hunger: 45 + Math.floor(random(w) * 40),
    stamina: 75 + Math.floor(random(w) * 25),
    age: 2,
    generation: 1,
    parents: [],
    personality: {
      cooperative: person.cooperative,
      aggressive: person.aggressive,
      curious: person.curious,
    },
    inventory: id % 3 === 0 ? 1 : 0,
    capacity: 3,
    libido: 20,
    aggression: 0,
    relations: {},
    memories: [],
    scouted: [],
    cognition: defaultCognition(),
    lastAction: "wait",
    lastActionLabel: "世界を見渡している",
  };
}
export function createWorld(
  seed = 541119842,
  name = "こもれびの庭",
  overrides: Partial<WorldConfig> = {},
): WorldState {
  const config = {
    ...DEFAULT_CONFIG,
    ...overrides,
    costs: { ...DEFAULT_CONFIG.costs, ...overrides.costs },
  };
  config.size = Math.floor(clamp(config.size, 12, 28));
  config.population = Math.floor(clamp(config.population, 2, 40));
  const usage = (): Usage => ({
    input: 0,
    output: 0,
    usd: 0,
    requests: 0,
    latencyMs: 0,
    failures: 0,
  });
  const w: WorldState = {
    version: 2,
    id: crypto.randomUUID(),
    name,
    seed,
    rng: seed || 1,
    tick: 0,
    day: 0,
    terrain: [],
    food: [],
    agents: [],
    events: [],
    config,
    mode: "demo",
    usage: {
      system1: usage(),
      thought: usage(),
      language: usage(),
      legacy: usage(),
    },
    disposition:
      "有限の寿命を持つ生命。個性や体調、他者との関係、経験に従い、食料を探し、交流し、子を育み、記憶を伝える。行動の社会的な意味はそれぞれが見出す。",
    createdAt: Date.now(),
  };
  for (let y = 0; y < config.size; y++) {
    w.terrain[y] = [];
    w.food[y] = [];
    for (let x = 0; x < config.size; x++) {
      const n = hash(Math.floor(x / 3), Math.floor(y / 3), seed);
      const river = config.size * 0.57 + Math.sin(y * 0.4 + (seed % 10)) * 2;
      const lake = Math.hypot(x - config.size * 0.23, y - config.size * 0.77);
      let t: Terrain =
        Math.abs(x - river) < 0.85 || lake < 2.5
          ? "water"
          : n > 0.66
            ? "forest"
            : n < 0.12
              ? "rock"
              : "grass";
      if (
        (x < 2 || y < 2 || x > config.size - 3 || y > config.size - 3) &&
        hash(x, y, seed) > 0.5 &&
        t !== "water"
      )
        t = "forest";
      w.terrain[y][x] = t;
      w.food[y][x] =
        (t === "grass" || t === "forest") &&
        random(w) < config.initialFood * (t === "forest" ? 1.5 : 1);
    }
  }
  const positions: Point[] = [];
  for (let y = 3; y < config.size - 3; y++)
    for (let x = 3; x < config.size - 3; x++)
      if (w.terrain[y][x] !== "water") positions.push({ x, y });
  while (w.agents.length < config.population && positions.length) {
    const p = positions.splice(Math.floor(random(w) * positions.length), 1)[0];
    w.agents.push(makeAgent(w.agents.length, p.x, p.y, w));
  }
  w.events.push({
    id: `${w.id}:origin`,
    tick: 0,
    kind: "origin",
    text: `${w.agents.length}人の、小さな物語がはじまる。`,
  });
  return w;
}
