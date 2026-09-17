export type Terrain = "grass" | "water" | "forest" | "rock";
export type ActionKind =
  | "wait"
  | "move"
  | "take"
  | "eat"
  | "give"
  | "attack"
  | "embrace"
  | "look"
  | "reproduce_with"
  | "speak"
  | "teach";
export interface Point {
  x: number;
  y: number;
}
export interface Candidate {
  id: string;
  kind: ActionKind;
  label: string;
  direction?: Point;
  targetId?: number;
  text?: string;
}
export interface Memory {
  id: string;
  tick: number;
  text: string;
  source: "experienced" | "witnessed" | "heard";
  sourceId?: number;
  relatedIds: number[];
  position: Point;
}
export interface GoalCondition {
  type: "inventory_count" | "position" | "health" | "semantic";
  value?: number;
  x?: number;
  y?: number;
  description?: string;
}
export interface Goal {
  description: string;
  priority: number;
  successConditions: GoalCondition[];
  constraints: string[];
  relevantAgentIds: number[];
  createdAtTick: number;
}
export interface Cognition {
  revision: number;
  goal: Goal | null;
  beliefs: string[];
  priorities: string[];
  plan: string[];
  lastThoughtTick: number;
  status: "idle" | "thinking" | "completed" | "discarded" | "error";
  note?: string;
  assessments?: Record<number, { tick: number; probability: number }>;
}
export interface Judgment {
  tick: number;
  selected: string;
  probabilities: Record<string, number>;
  labels: Record<string, string>;
  confidence: number;
  needsDeliberation: number;
  source: "jev" | "demo" | "legacy";
  error?: string;
  goalAssessments?: Record<number, { tick: number; probability: number }>;
}
export interface Agent extends Point {
  id: number;
  name: string;
  gender: "female" | "male";
  color: string;
  health: number;
  hunger: number;
  stamina: number;
  age: number;
  generation: number;
  parents: number[];
  personality: { cooperative: number; aggressive: number; curious: number };
  inventory: number;
  capacity: number;
  libido: number;
  aggression: number;
  relations: Record<number, { affection: number; trust: number }>;
  memories: Memory[];
  scouted: Array<
    Point & { tick: number; terrain: Terrain; food: boolean; occupant?: string }
  >;
  cognition: Cognition;
  judgment?: Judgment;
  lastAction: ActionKind;
  lastActionLabel: string;
  speech?: { text: string; tick: number; targetId?: number };
  diedAt?: number;
}
export interface WorldEvent {
  id: string;
  tick: number;
  kind: string;
  text: string;
  actorId?: number;
  targetId?: number;
  position?: Point;
  success?: boolean;
}
export interface WorldConfig {
  size: number;
  population: number;
  ticksPerDay: number;
  elderAge: number;
  initialFood: number;
  foodRegen: number;
  costs: Record<string, number>;
  deliberationThreshold: number;
  top1Threshold: number;
  marginThreshold: number;
  thoughtCooldown: number;
  thoughtMaxAge: number;
  maxPopulation: number;
}
export interface Usage {
  unpricedRequests?: number;
  input: number;
  output: number;
  usd: number;
  requests: number;
  latencyMs: number;
  failures: number;
}
export interface WorldState {
  version: 2;
  id: string;
  name: string;
  seed: number;
  rng: number;
  tick: number;
  day: number;
  terrain: Terrain[][];
  food: boolean[][];
  agents: Agent[];
  events: WorldEvent[];
  config: WorldConfig;
  mode: "demo" | "jev" | "legacy_llm";
  narrativeLanguage?: "ja" | "en";
  usage: Record<"system1" | "thought" | "language" | "legacy", Usage>;
  disposition: string;
  createdAt: number;
}
export const ACTION_NAMES: Record<ActionKind, string> = {
  wait: "ひと休み",
  move: "歩く",
  take: "食料を拾う",
  eat: "食べる",
  give: "食料を分ける",
  attack: "攻撃する",
  embrace: "寄り添う",
  look: "遠くを眺める",
  reproduce_with: "命をつなぐ",
  speak: "話す",
  teach: "語り継ぐ",
};
export const DIRECTIONS = [
  { x: 0, y: -1, name: "北" },
  { x: 1, y: 0, name: "東" },
  { x: 0, y: 1, name: "南" },
  { x: -1, y: 0, name: "西" },
  { x: 1, y: -1, name: "北東" },
  { x: 1, y: 1, name: "南東" },
  { x: -1, y: 1, name: "南西" },
  { x: -1, y: -1, name: "北西" },
];
