import type {
  Agent,
  Candidate,
  Judgment,
  WorldState,
} from "../src/simulation/types";
import { availableActions } from "../src/simulation/actions";
import { observation } from "../src/simulation/cognition";
import { ACTION_NAMES } from "../src/simulation/types";
import { residentName } from "../src/i18n/names";
export interface AIEnv {
  TYPESAFE_API_KEY?: string;
  OPENAI_API_KEY?: string;
  OPENAI_MODEL?: string;
}
export interface Meter {
  role: keyof WorldState["usage"];
  input: number;
  output: number;
  usd: number | null;
  latencyMs: number;
}
export type MeterFn = (m: Meter) => void;
export function writingObservation(w: WorldState, a: Agent) {
  const state = observation(w, a);
  const known = new Set([
    a.id,
    ...state.nearby.flatMap((tile) =>
      tile.occupant ? [tile.occupant.id] : [],
    ),
    ...a.memories.flatMap((memory) => memory.relatedIds),
  ]);
  return {
    ...state,
    name_spellings: w.agents
      .filter((person) => known.has(person.id))
      .map((person) => ({
        id: person.id,
        original: person.name,
        display: residentName(person.name, w.narrativeLanguage ?? "ja"),
      })),
  };
}
const outputLanguage = (w: WorldState) =>
  w.narrativeLanguage === "en" ? "English" : "Japanese";
async function request(url: string, init: RequestInit, timeout: number) {
  const response = await fetch(url, {
    ...init,
    signal: AbortSignal.timeout(timeout),
  });
  if (!response.ok) throw new Error(`API HTTP ${response.status}`);
  return response.json() as Promise<Record<string, any>>;
}
export async function jev(
  w: WorldState,
  a: Agent,
  env: AIEnv,
  meter: MeterFn,
): Promise<{ action: Candidate; judgment: Judgment }> {
  if (!env.TYPESAFE_API_KEY) throw new Error("TypeSafe API キーが未設定です");
  const candidates = availableActions(w, a, Boolean(env.OPENAI_API_KEY)),
    state = observation(w, a);
  const questions: Record<string, unknown> = {
    next_action: {
      type: "choice",
      instructions:
        "Select the most natural immediate physical action for this individual, considering body, personality, memories, current goal and relationships. Every offered action is physically available in this observation. Do not impose cooperation or morality. Choose exactly one.",
      criteria: Object.fromEntries(candidates.map((c) => [c.id, c.label])),
    },
    needs_deliberation: {
      type: "noul",
      instructions:
        "Does this individual need to reconsider their higher-level goal, beliefs, priorities or plan now? Routine movement, eating or multiple equally acceptable directions alone do not require deliberation. Consider major personal events, conflicting priorities, invalidated goals or a missing goal in a meaningful situation.",
    },
  };
  a.cognition.goal?.successConditions.forEach((condition, i) => {
    if (condition.type === "semantic")
      questions[`goal_condition_${i}`] = {
        type: "noul",
        instructions: `Based ONLY on this individual's current observation and their memories, has this goal condition been achieved? If there is not enough evidence, do not assume success. Condition: ${condition.description}`,
      };
  });
  let data: Record<string, any> | undefined;
  const started = Date.now();
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      data = await request(
        "https://api.typesafe.ai/v1/systemone",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.TYPESAFE_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ model: "jev-latest", state, questions }),
        },
        12000,
      );
      break;
    } catch (error) {
      if (attempt === 2 || !/HTTP (429|529|50[0234])/.test(String(error)))
        throw error;
      await new Promise((r) => setTimeout(r, 300 * 2 ** attempt));
    }
  }
  if (!data) throw new Error("Jev の応答がありません");
  const input = Number(data.usage?.input_tokens ?? 0),
    output = Number(data.usage?.output_tokens ?? 0);
  meter({
    role: "system1",
    input,
    output,
    usd: (input * 0.042) / 1e6,
    latencyMs: Date.now() - started,
  });
  const answer = data.answers?.next_action,
    action = candidates.find((c) => c.id === answer?.choice),
    p = answer?.probabilities;
  if (
    !action ||
    answer.type !== "choice" ||
    !p ||
    typeof p !== "object" ||
    candidates.some(
      (c) =>
        typeof p[c.id] !== "number" ||
        !Number.isFinite(p[c.id]) ||
        p[c.id] < 0 ||
        p[c.id] > 1,
    ) ||
    Object.keys(p).some((id) => !candidates.some((c) => c.id === id)) ||
    Math.abs(Object.values(p).reduce<number>((s, v) => s + Number(v), 0) - 1) >
      0.025
  )
    throw new Error("Jev の選択肢・確率が不正です");
  const confidence = answer.confidence;
  if (
    typeof confidence !== "number" ||
    !Number.isFinite(confidence) ||
    confidence < 0 ||
    confidence > 1
  )
    throw new Error("Jev の confidence が不正です");
  const noul = data.answers?.needs_deliberation;
  const valid =
    noul?.type === "noul" &&
    typeof noul.noul === "number" &&
    Number.isFinite(noul.noul) &&
    noul.noul >= 0 &&
    noul.noul <= 1;
  const goalAssessments: Record<number, { tick: number; probability: number }> =
    {};
  a.cognition.goal?.successConditions.forEach((c, i) => {
    const v = data!.answers?.[`goal_condition_${i}`];
    if (
      c.type === "semantic" &&
      v?.type === "noul" &&
      typeof v.noul === "number" &&
      Number.isFinite(v.noul) &&
      v.noul >= 0 &&
      v.noul <= 1
    )
      goalAssessments[i] = { tick: w.tick, probability: v.noul };
  });
  return {
    action,
    judgment: {
      goalAssessments,
      tick: w.tick,
      selected: action.id,
      probabilities: p,
      labels: Object.fromEntries(candidates.map((c) => [c.id, c.label])),
      confidence,
      needsDeliberation: valid ? noul.noul : 0,
      source: "jev",
      ...(!valid ? { error: "再考判定を取得できませんでした" } : {}),
    },
  };
}
export async function generate(
  env: AIEnv,
  state: unknown,
  instruction: string,
  schema: object,
  role: Meter["role"],
  meter: MeterFn,
) {
  if (!env.OPENAI_API_KEY) throw new Error("生成 LLM のキーが未設定です");
  const started = Date.now();
  const model = env.OPENAI_MODEL || "gpt-5.6-luna";
  const data = await request(
    "https://api.openai.com/v1/responses",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model,
        instructions: instruction,
        input: [{ role: "user", content: JSON.stringify(state) }],
        reasoning: { effort: "none" },
        service_tier: "default",
        store: false,
        max_output_tokens: 900,
        text: {
          verbosity: "low",
          format: { type: "json_schema", name: role, strict: true, schema },
        },
      }),
    },
    role === "language" ? 10000 : 25000,
  );
  const input = Number(data.usage?.input_tokens ?? 0),
    // Responses output_tokens already includes reasoning tokens.
    output = Number(data.usage?.output_tokens ?? 0),
    cached = Number(data.usage?.input_tokens_details?.cached_tokens ?? 0),
    writes = Number(data.usage?.input_tokens_details?.cache_write_tokens ?? 0);
  const priced =
    model === "gpt-5.6-luna" &&
    data.usage &&
    [input, output, cached, writes].every(
      (n) => Number.isInteger(n) && n >= 0,
    ) &&
    cached + writes <= input;
  // Standard Luna USD / 1M tokens, including cache writes and long context.
  // https://developers.openai.com/api/docs/pricing
  meter({
    role,
    input,
    output,
    usd: priced
      ? ((input - cached - writes + cached * 0.1 + writes * 1.25) *
          (input > 272000 ? 0.4 : 0.2) +
          output * (input > 272000 ? 1.8 : 1.2)) /
        1e6
      : null,
    latencyMs: Date.now() - started,
  });
  if (data.status === "incomplete") throw new Error("生成が途中で終了しました");
  if (data.status !== "completed") throw new Error("生成に失敗しました");
  const content = (data.output ?? [])
    .filter((item: { type: string }) => item.type === "message")
    .flatMap(
      (item: { content: { type: string; text?: string }[] }) => item.content,
    );
  if (content.some((part: { type: string }) => part.type === "refusal"))
    throw new Error("生成が拒否されました");
  const text = content
    .filter((part: { type: string }) => part.type === "output_text")
    .map((part: { text?: string }) => part.text ?? "")
    .join("");
  if (!text) throw new Error("生成内容が空です");
  return JSON.parse(text);
}
function objectSchema(properties: Record<string, object>) {
  return {
    type: "object",
    properties,
    required: Object.keys(properties),
    additionalProperties: false,
  };
}
export async function language(
  w: WorldState,
  a: Agent,
  action: Candidate,
  env: AIEnv,
  meter: MeterFn,
) {
  const result = await generate(
    env,
    { observation: writingObservation(w, a), selected_action: action },
    `Write only the spoken content for the already selected action and addressee, in short natural ${outputLanguage(w)} (maximum 120 characters). Use name_spellings.display when mentioning a person. Speak as this individual based on their personality, memories and goals. For teach, transmit something they know, believe, or heard; do not invent omniscient facts. Do not choose another action or addressee.`,
    objectSchema({ text: { type: "string" } }),
    "language",
    meter,
  );
  if (
    typeof result.text !== "string" ||
    !result.text.trim() ||
    result.text.length > 160
  )
    throw new Error("発話内容が不正です");
  return { ...action, text: result.text };
}
export const THOUGHT_SCHEMA = objectSchema({
  goal: objectSchema({
    description: { type: "string" },
    priority: { type: "number", minimum: 0, maximum: 1 },
    successConditions: {
      type: "array",
      maxItems: 6,
      items: {
        anyOf: [
          objectSchema({
            type: { type: "string", enum: ["inventory_count"] },
            value: { type: "integer", minimum: 0 },
          }),
          objectSchema({
            type: { type: "string", enum: ["position"] },
            x: { type: "integer", minimum: 0 },
            y: { type: "integer", minimum: 0 },
          }),
          objectSchema({
            type: { type: "string", enum: ["health"] },
            value: { type: "number", minimum: 0, maximum: 100 },
          }),
          objectSchema({
            type: { type: "string", enum: ["semantic"] },
            description: { type: "string" },
          }),
        ],
      },
    },
    constraints: { type: "array", items: { type: "string" }, maxItems: 6 },
    relevantAgentIds: { type: "array", items: { type: "integer" } },
  }),
  beliefs: { type: "array", items: { type: "string" }, maxItems: 8 },
  priorities: { type: "array", items: { type: "string" }, maxItems: 8 },
  plan: { type: "array", items: { type: "string" }, maxItems: 8 },
});
export const THOUGHT_INSTRUCTION =
  "You are this individual reflecting on their life. Reconsider higher-level goal, beliefs, priorities, and plan using only their observation and memories. Output short Japanese. Do not select the next physical action or control the body. Preserve beliefs when unchanged. Plans are broad intentions. Use supported achievable numeric success conditions, or semantic conditions for ambiguous goals. inventory_count must not exceed capacity. Coordinates must be inside the world. Refer only to known agent IDs. At most 6 success conditions and constraints, and 8 short items each in beliefs, priorities and plan.";
export function thoughtInstruction(w: WorldState) {
  return THOUGHT_INSTRUCTION.replace(
    "Output short Japanese.",
    `Output short ${outputLanguage(w)}. Use name_spellings.display when mentioning a person.`,
  );
}
export async function legacy(
  w: WorldState,
  a: Agent,
  env: AIEnv,
  meter: MeterFn,
): Promise<Candidate[]> {
  const kinds = [
    "wait",
    "move",
    "take",
    "eat",
    "give",
    "attack",
    "embrace",
    "look",
    "reproduce_with",
    "speak",
    "teach",
  ];
  const schema = objectSchema({
    actions: {
      type: "array",
      maxItems: 5,
      items: objectSchema({
        kind: { type: "string", enum: kinds },
        x: { type: ["integer", "null"], minimum: -1, maximum: 1 },
        y: { type: ["integer", "null"], minimum: -1, maximum: 1 },
        targetId: { type: ["integer", "null"] },
        text: { type: ["string", "null"] },
      }),
    },
  });
  const result = await generate(
    env,
    writingObservation(w, a),
    `Choose up to five ordered physical actions for this individual this tick. Follow their body, personality, memories, goals. Do not impose social rules. move uses x/y as an offset -1..1 (not both zero), water and edges block; occupied tiles slide to the next free tile. take reaches your tile (x=0,y=0) or 8 adjacent tiles. eat inventory first else own tile. give targets a living person in radius 3. attack, embrace, reproduce_with and teach require cardinal adjacency; reproduction also requires opposite gender and puberty. look uses a cardinal offset. speak and teach require short ${outputLanguage(w)} text (<=120 chars); use name_spellings.display for names. targetId refers to an observed person; speak with null targetId is broadcast. Use null for unused x/y, targetId and text. Physical failure does not cancel later actions. Caps: move3; take5; eat/give/attack/embrace2; others1. Return only the action list.`,
    schema,
    "legacy",
    meter,
  );
  if (!Array.isArray(result.actions) || result.actions.length > 5)
    throw new Error("行動列が不正です");
  return result.actions.map((r: any): Candidate => {
    if (!kinds.includes(r.kind)) throw new Error("不明な行動です");
    const kind = r.kind as Candidate["kind"];
    const dir = ["move", "take", "look"].includes(kind)
      ? { x: r.x ?? 0, y: r.y ?? 0 }
      : undefined;
    if (
      dir &&
      (!Number.isInteger(dir.x) ||
        !Number.isInteger(dir.y) ||
        Math.abs(dir.x) > 1 ||
        Math.abs(dir.y) > 1)
    )
      throw new Error("方向が不正です");
    const targetId = r.targetId ?? undefined;
    if (
      targetId !== undefined &&
      (!Number.isInteger(targetId) || !w.agents.some((b) => b.id === targetId))
    )
      throw new Error("相手が不正です");
    if (
      (kind === "speak" || kind === "teach") &&
      (typeof r.text !== "string" || !r.text.trim() || r.text.length > 160)
    )
      throw new Error("発話が不正です");
    const id = `${kind}${targetId === undefined ? (dir ? `:${dir.x}:${dir.y}` : "") : `:${targetId}`}`;
    return {
      id,
      kind,
      direction: dir,
      targetId,
      text: r.text ?? undefined,
      label: `${ACTION_NAMES[kind]}${targetId === undefined ? "" : ` → ${w.agents.find((b) => b.id === targetId)?.name}`}`,
    };
  });
}
