import { afterEach, describe, expect, it, vi } from "vitest";
import { createWorld } from "../src/simulation/world";
import { availableActions } from "../src/simulation/actions";
import { jev, language, generate, legacy, THOUGHT_SCHEMA } from "../worker/ai";
import { validateGoal } from "../src/simulation/cognition";
afterEach(() => vi.unstubAllGlobals());
const textSchema = {
  type: "object",
  properties: { text: { type: "string" } },
  required: ["text"],
  additionalProperties: false,
};
function response(
  value: unknown,
  usage = { input_tokens: 100, output_tokens: 30 },
) {
  return {
    status: "completed",
    usage,
    output: [
      { type: "reasoning", summary: [] },
      {
        type: "message",
        content: [{ type: "output_text", text: JSON.stringify(value) }],
      },
    ],
  };
}
function expectStrictSchema(schema: any) {
  if (schema.type === "object") {
    expect(schema.additionalProperties).toBe(false);
    expect(schema.required).toEqual(Object.keys(schema.properties));
    Object.values(schema.properties).forEach(expectStrictSchema);
  }
  if (schema.items) expectStrictSchema(schema.items);
  schema.anyOf?.forEach(expectStrictSchema);
}
function setup() {
  const w = createWorld(4),
    a = w.agents[0],
    c = availableActions(w, a, false);
  const answer = {
    answers: {
      next_action: {
        type: "choice",
        choice: "wait",
        probabilities: Object.fromEntries(
          c.map((x) => [x.id, x.id === "wait" ? 1 : 0]),
        ),
        confidence: 1,
      },
      needs_deliberation: { type: "noul", noul: 0.9 },
    },
    usage: { input_tokens: 100, output_tokens: 10 },
  };
  return { w, a, answer };
}
describe("typed TypeSafe decisions", () => {
  it("evaluates only semantic goal conditions with additional Noul questions", async () => {
    const { w, a, answer } = setup();
    a.cognition.goal = {
      description: "仲直りする",
      priority: 0.8,
      constraints: [],
      relevantAgentIds: [],
      createdAtTick: 0,
      successConditions: [
        { type: "semantic", description: "相手と仲直りした" },
        { type: "inventory_count", value: 2 },
      ],
    };
    const fetcher = vi.fn(async () =>
      Response.json({
        ...answer,
        answers: {
          ...answer.answers,
          goal_condition_0: { type: "noul", noul: 0.82 },
        },
      }),
    );
    vi.stubGlobal("fetch", fetcher);
    const result = await jev(w, a, { TYPESAFE_API_KEY: "secret" }, () => {});
    const sent = JSON.parse(fetcher.mock.calls[0][1].body as string);
    expect(sent.questions.goal_condition_0.type).toBe("noul");
    expect(sent.questions.goal_condition_1).toBeUndefined();
    expect(result.judgment.goalAssessments?.[0].probability).toBe(0.82);
  });
  it("uses Luna Responses and accounts for cached input, cache writes and inclusive output", async () => {
    const fetcher = vi.fn(async () =>
      Response.json({
        ...response({ text: "こんにちは" }),
        usage: {
          input_tokens: 100,
          output_tokens: 30,
          input_tokens_details: { cached_tokens: 40, cache_write_tokens: 20 },
          output_tokens_details: { reasoning_tokens: 10 },
        },
      }),
    );
    vi.stubGlobal("fetch", fetcher);
    const meter = vi.fn();
    expect(
      await generate(
        { OPENAI_API_KEY: "secret" },
        { memory: "hello" },
        "test",
        textSchema,
        "language",
        meter,
      ),
    ).toEqual({ text: "こんにちは" });
    const [url, init] = fetcher.mock.calls[0];
    const body = JSON.parse(init.body as string);
    expect(url).toBe("https://api.openai.com/v1/responses");
    expect(init.headers.Authorization).toBe("Bearer secret");
    expect(init.body).not.toContain("secret");
    expect(body).toMatchObject({
      model: "gpt-5.6-luna",
      instructions: "test",
      reasoning: { effort: "none" },
      service_tier: "default",
      store: false,
      max_output_tokens: 900,
      text: {
        format: { type: "json_schema", strict: true, schema: textSchema },
      },
    });
    expect(JSON.parse(body.input[0].content)).toEqual({ memory: "hello" });
    expect(meter.mock.calls[0][0]).toMatchObject({ input: 100, output: 30 });
    expect(meter.mock.calls[0][0].usd).toBeCloseTo(0.0000498, 12);
    await generate(
      { OPENAI_API_KEY: "secret", OPENAI_MODEL: "custom" },
      {},
      "test",
      textSchema,
      "language",
      meter,
    );
    expect(meter.mock.calls[1][0].usd).toBeNull();
  });
  it("applies Luna's long-context rates only above 272K input tokens", async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(
        Response.json(
          response(
            { text: "ok" },
            { input_tokens: 272000, output_tokens: 100 },
          ),
        ),
      )
      .mockResolvedValueOnce(
        Response.json(
          response(
            { text: "ok" },
            { input_tokens: 272001, output_tokens: 100 },
          ),
        ),
      );
    vi.stubGlobal("fetch", fetcher);
    const meter = vi.fn();
    for (let i = 0; i < 2; i++)
      await generate(
        { OPENAI_API_KEY: "test" },
        {},
        "test",
        textSchema,
        "language",
        meter,
      );
    expect(meter.mock.calls[0][0].usd).toBeCloseTo(
      (272000 * 0.2 + 100 * 1.2) / 1e6,
      12,
    );
    expect(meter.mock.calls[1][0].usd).toBeCloseTo(
      (272001 * 0.4 + 100 * 1.8) / 1e6,
      12,
    );
  });
  it.each([
    [
      {
        ...response({ text: "partial" }),
        status: "incomplete",
        incomplete_details: { reason: "max_output_tokens" },
      },
      "途中",
    ],
    [
      {
        ...response({}),
        output: [
          {
            type: "message",
            content: [{ type: "refusal", refusal: "declined" }],
          },
        ],
      },
      "拒否",
    ],
    [{ ...response({}), output: [] }, "空"],
    [{ ...response({}), status: "failed" }, "失敗"],
  ])(
    "rejects unusable output but still meters billed usage",
    async (data, error) => {
      vi.stubGlobal(
        "fetch",
        vi.fn(async () => Response.json(data)),
      );
      const meter = vi.fn();
      await expect(
        generate(
          { OPENAI_API_KEY: "test" },
          {},
          "test",
          textSchema,
          "language",
          meter,
        ),
      ).rejects.toThrow(error);
      expect(meter).toHaveBeenCalledWith(
        expect.objectContaining({ input: 100, output: 30 }),
      );
    },
  );
  it("keeps speech's selected action and recipient and uses a strict schema", async () => {
    const { w, a } = setup();
    const fetcher = vi.fn(async () =>
      Response.json(response({ text: "食べ物を分けよう。" })),
    );
    vi.stubGlobal("fetch", fetcher);
    const selected = {
      id: "teach:1",
      kind: "teach" as const,
      targetId: 1,
      label: "教える",
    };
    const result = await language(
      w,
      a,
      selected,
      { OPENAI_API_KEY: "test" },
      () => {},
    );
    expect(result).toEqual({ ...selected, text: "食べ物を分けよう。" });
    expectStrictSchema(
      JSON.parse(fetcher.mock.calls[0][1].body as string).text.format.schema,
    );
  });
  it("normalizes optional legacy fields from null and preserves physical action order", async () => {
    const { w, a } = setup();
    const actions = [
      { kind: "move", x: 1, y: 0, targetId: null, text: null },
      { kind: "speak", x: null, y: null, targetId: null, text: "こんにちは" },
      { kind: "give", x: null, y: null, targetId: 1, text: null },
    ];
    const fetcher = vi.fn(async () => Response.json(response({ actions })));
    vi.stubGlobal("fetch", fetcher);
    const result = await legacy(w, a, { OPENAI_API_KEY: "test" }, () => {});
    expect(result.map((c) => c.id)).toEqual(["move:1:0", "speak", "give:1"]);
    expect(result[0].direction).toEqual({ x: 1, y: 0 });
    expect(result[0].text).toBeUndefined();
    expect(result[1].targetId).toBeUndefined();
    expectStrictSchema(
      JSON.parse(fetcher.mock.calls[0][1].body as string).text.format.schema,
    );
  });
  it("keeps all four goal condition shapes compatible with domain validation", async () => {
    const { w, a } = setup();
    const goal = {
      description: "元気に暮らす",
      priority: 0.5,
      successConditions: [
        { type: "inventory_count", value: 1 },
        { type: "position", x: 1, y: 1 },
        { type: "health", value: 80 },
        { type: "semantic", description: "友だちと話した" },
      ],
      constraints: [],
      relevantAgentIds: [a.id],
    };
    const payload = { goal, beliefs: [], priorities: [], plan: [] };
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => Response.json(response(payload))),
    );
    const result = await generate(
      { OPENAI_API_KEY: "test" },
      {},
      "test",
      THOUGHT_SCHEMA,
      "thought",
      () => {},
    );
    expect(validateGoal(result.goal, a, w)?.successConditions).toEqual(
      goal.successConditions,
    );
    expectStrictSchema(THOUGHT_SCHEMA);
    expect(
      THOUGHT_SCHEMA.properties.goal.properties.successConditions.items.anyOf.map(
        (s: any) => s.properties.type.enum[0],
      ),
    ).toEqual(["inventory_count", "position", "health", "semantic"]);
  });
  it("returns action and Noul together, records usage, keeps credentials out of body", async () => {
    const { w, a, answer } = setup();
    const fetcher = vi.fn(async () => Response.json(answer));
    vi.stubGlobal("fetch", fetcher);
    const meter = vi.fn();
    const r = await jev(w, a, { TYPESAFE_API_KEY: "secret" }, meter);
    expect(r.action.kind).toBe("wait");
    expect(r.judgment.needsDeliberation).toBe(0.9);
    expect(meter).toHaveBeenCalledWith(
      expect.objectContaining({ input: 100, role: "system1" }),
    );
    expect(fetcher.mock.calls[0][1].body).not.toContain("secret");
  });
  it("rejects a fabricated action and malformed probability", async () => {
    const { w, a, answer } = setup();
    answer.answers.next_action.choice = "become_king";
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => Response.json(answer)),
    );
    await expect(
      jev(w, a, { TYPESAFE_API_KEY: "secret" }, () => {}),
    ).rejects.toThrow("選択肢");
  });
  it("preserves a valid action if only the Noul is broken", async () => {
    const { w, a, answer } = setup();
    answer.answers.needs_deliberation.noul = 2;
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => Response.json(answer)),
    );
    const r = await jev(w, a, { TYPESAFE_API_KEY: "secret" }, () => {});
    expect(r.action.id).toBe("wait");
    expect(r.judgment.error).toBeTruthy();
  });
  it("does not silently generate speech without a configured generator", async () => {
    const { w, a } = setup();
    await expect(
      language(
        w,
        a,
        { id: "speak", kind: "speak", label: "話す" },
        {},
        () => {},
      ),
    ).rejects.toThrow("キー");
  });
});
