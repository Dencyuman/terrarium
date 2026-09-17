import { DurableObject } from "cloudflare:workers";
import { applyThought, type Thought } from "../src/simulation/thought";
import type { Agent, Candidate, WorldState } from "../src/simulation/types";
import { alive, createWorld, DEFAULT_CONFIG } from "../src/simulation/world";
import { commitTick, emit } from "../src/simulation/engine";
import { observation, shouldThink } from "../src/simulation/cognition";
import {
  snapshotTables,
  readSnapshot,
  readHistory,
  saveSnapshot,
} from "./snapshots";
import {
  generate,
  jev,
  language,
  legacy,
  thoughtInstruction,
  writingObservation,
  THOUGHT_SCHEMA,
  type AIEnv,
  type Meter,
} from "./ai";
interface Env extends AIEnv {
  WORLDS: DurableObjectNamespace<TerrariumWorld>;
  ADMIN_TOKEN?: string;
  MAX_AI_TICKS_PER_DAY?: string;
}
const json = (data: unknown, status = 200) =>
  Response.json(data, { status, headers: { "Cache-Control": "no-store" } });
const authorized = (request: Request, env: Env) => {
  const host = new URL(request.url).hostname;
  return env.ADMIN_TOKEN
    ? request.headers.get("Authorization") === `Bearer ${env.ADMIN_TOKEN}`
    : ["127.0.0.1", "localhost"].includes(host);
};
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/api/status")
      return json({
        jev: Boolean(env.TYPESAFE_API_KEY),
        language: Boolean(env.OPENAI_API_KEY),
        requiresToken: Boolean(env.ADMIN_TOKEN),
        cloud: true,
        maxTicksPerDay: Number(env.MAX_AI_TICKS_PER_DAY || 500),
      });
    if (!authorized(request, env))
      return json({ error: "観察室の合言葉を設定してください。" }, 401);
    if (
      request.method !== "GET" &&
      request.headers.get("Origin") &&
      request.headers.get("Origin") !== url.origin
    )
      return json({ error: "許可されていない送信元です" }, 403);
    if (url.pathname === "/api/worlds" && request.method === "POST") {
      if (Number(request.headers.get("Content-Length") || 0) > 10000)
        return json({ error: "設定が大きすぎます" }, 413);
      let body: Record<string, unknown>;
      try {
        const raw = await request.text();
        if (raw.length > 10000)
          return json({ error: "設定が大きすぎます" }, 413);
        body = JSON.parse(raw);
        if (!body || Array.isArray(body)) throw new Error();
      } catch {
        return json({ error: "設定を読み取れません" }, 400);
      }
      if (
        body.mode === "legacy_llm" ? !env.OPENAI_API_KEY : !env.TYPESAFE_API_KEY
      )
        return json({ error: "選択したAIのキーが未設定です" }, 503);
      const id = crypto.randomUUID(),
        stub = env.WORLDS.get(env.WORLDS.idFromName(id));
      return stub.fetch(
        new Request(`${url.origin}/init`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ...body, id }),
        }),
      );
    }
    const match = url.pathname.match(
      /^\/api\/worlds\/([a-f0-9-]{36})(?:\/(tick|history))?$/,
    );
    if (!match) return json({ error: "見つかりません" }, 404);
    if (match[2] === "tick" && request.method === "POST") {
      const quota = env.WORLDS.get(env.WORLDS.idFromName("global-budget"));
      const allowed = await quota.fetch(
        new Request(`${url.origin}/quota`, { method: "POST" }),
      );
      if (!allowed.ok) return allowed;
    }
    return env.WORLDS.get(env.WORLDS.idFromName(match[1])).fetch(
      new Request(`${url.origin}/${match[2] ?? "state"}`, request),
    );
  },
} satisfies ExportedHandler<Env>;
export class TerrariumWorld extends DurableObject<Env> {
  world: WorldState | null = null;
  busy = false;
  completions: Thought[] = [];
  thinking = new Set<number>();
  lastStep = 0;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      snapshotTables(ctx.storage.sql);
      this.world =
        readSnapshot(ctx.storage.sql) ??
        (await ctx.storage.get<WorldState>("world")) ??
        null;
      if (this.world)
        for (const a of this.world.agents)
          if (a.cognition.status === "thinking") {
            a.cognition.status = "discarded";
            a.cognition.note = "接続を再開しました。次の判断から再考します。";
          }
      ctx.storage.sql.exec(
        "CREATE TABLE IF NOT EXISTS memories (id TEXT PRIMARY KEY, owner INTEGER, tick INTEGER, data TEXT)",
      );
      ctx.storage.sql.exec(
        "CREATE INDEX IF NOT EXISTS memories_owner ON memories(owner, tick)",
      );
      ctx.storage.sql.exec(
        "CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, tick INTEGER, data TEXT)",
      );
    });
  }
  async fetch(request: Request) {
    const path = new URL(request.url).pathname;
    if (path === "/quota") {
      const day = new Date().toISOString().slice(0, 10);
      let q = (await this.ctx.storage.get<{ day: string; count: number }>(
        "quota",
      )) ?? { day, count: 0 };
      if (q.day !== day) q = { day, count: 0 };
      if (q.count >= Number(this.env.MAX_AI_TICKS_PER_DAY || 500))
        return json(
          {
            error:
              "今日のAI実行上限に達しました。無料の観察デモは続けられます。",
          },
          429,
        );
      q.count++;
      await this.ctx.storage.put("quota", q);
      return json({ ok: true });
    }
    if (path === "/init" && request.method === "POST") {
      if (this.world) return json({ error: "既に存在しています" }, 409);
      let body: any;
      try {
        const raw = await request.text();
        if (raw.length > 10000)
          return json({ error: "設定が大きすぎます" }, 413);
        body = JSON.parse(raw);
      } catch {
        return json({ error: "設定を読み取れません" }, 400);
      }
      const seed = Number(body.seed ?? 541119842);
      if (!Number.isSafeInteger(seed))
        return json({ error: "シードが不正です" }, 400);
      this.world = createWorld(
        seed,
        String(body.name || "こもれびの庭").slice(0, 40),
        {
          population: Math.max(2, Math.min(40, Number(body.population) || 20)),
        },
      );
      this.world.id = String(body.id);
      this.world.mode = body.mode === "legacy_llm" ? "legacy_llm" : "jev";
      this.world.narrativeLanguage = body.language === "en" ? "en" : "ja";
      // Public identifier is the original request's newly generated UUID, returned to the browser.
      await this.save();
      return json({ world: this.world, storageId: this.ctx.id.toString() });
    }
    if (!this.world) return json({ error: "世界が見つかりません" }, 404);
    if (path === "/state" && request.method === "GET")
      return json({ world: this.world });
    if (path === "/history" && request.method === "GET")
      return json({
        snapshots: readHistory(this.ctx.storage.sql),
      });
    if (path !== "/tick" || request.method !== "POST")
      return json({ error: "見つかりません" }, 404);
    if (this.busy) return json({ error: "まだ判断中です" }, 409);
    if (Date.now() - this.lastStep < 700)
      return json({ error: "次の判断まで少し待ってください" }, 429);
    let body: any;
    try {
      body = await request.json();
    } catch {
      return json({ error: "リクエストが不正です" }, 400);
    }
    if (body.expectedTick !== this.world.tick)
      return json({ world: this.world, conflict: true }, 409);
    this.busy = true;
    this.lastStep = Date.now();
    try {
      this.applyThoughts();
      const w = this.world;
      if (body.language === "en" || body.language === "ja")
        w.narrativeLanguage = body.language;
      const snapshot = structuredClone(w),
        decisions = new Map<number, Candidate[]>();
      const cohort = snapshot.agents.filter(alive);
      let cursor = 0;
      await Promise.all(
        Array.from({ length: Math.min(20, cohort.length) }, async () => {
          while (cursor < cohort.length) {
            const a = cohort[cursor++],
              actual = w.agents.find((b) => b.id === a.id)!;
            // Retrieve this individual's own older memories; never use the world's event log as perception.
            const related = JSON.stringify([
              ...snapshot.agents
                .filter(
                  (b) =>
                    b.id !== a.id &&
                    Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y)) <= 3,
                )
                .map((b) => b.id),
              ...(a.cognition.goal?.relevantAgentIds ?? []),
            ]);
            const rows = [
              ...this.ctx.storage.sql.exec<{ data: string }>(
                `SELECT data FROM memories WHERE owner = ? ORDER BY CASE WHEN EXISTS (SELECT 1 FROM json_each(json_extract(memories.data, '$.relatedIds')) r WHERE r.value IN (SELECT value FROM json_each(?))) THEN 1 ELSE 0 END DESC, tick DESC LIMIT 64`,
                a.id,
                related,
              ),
            ];
            const memories = new Map(
              [...rows.map((r) => JSON.parse(r.data)), ...a.memories].map(
                (m) => [m.id, m],
              ),
            );
            a.memories = [...memories.values()];
            let role: Meter["role"] =
              w.mode === "legacy_llm" ? "legacy" : "system1";
            try {
              if (w.mode === "legacy_llm") {
                const actions = await legacy(snapshot, a, this.env, (m) =>
                  this.meter(m),
                );
                decisions.set(a.id, actions);
                actual.judgment = {
                  tick: w.tick,
                  selected: actions.map((c) => c.label).join(" → "),
                  probabilities: {},
                  labels: {},
                  confidence: 0,
                  needsDeliberation: 0,
                  source: "legacy",
                };
                continue;
              }
              const result = await jev(snapshot, a, this.env, (m) =>
                this.meter(m),
              );
              actual.judgment = result.judgment;
              actual.cognition.assessments = result.judgment.goalAssessments;
              let action = result.action;
              if (
                shouldThink(w, actual) &&
                this.env.OPENAI_API_KEY &&
                this.thinking.size < 2
              )
                this.startThought(snapshot, a, actual);
              if (action.kind === "speak" || action.kind === "teach") {
                role = "language";
                action = await language(snapshot, a, action, this.env, (m) =>
                  this.meter(m),
                );
              }
              decisions.set(a.id, [action]);
            } catch (error) {
              const message =
                error instanceof Error ? error.message : "判断に失敗しました";
              actual.judgment = {
                tick: w.tick,
                selected: "wait",
                probabilities: {},
                labels: {},
                confidence: 0,
                needsDeliberation: 0,
                source: w.mode === "legacy_llm" ? "legacy" : "jev",
                error: message,
              };
              w.usage[role].failures++;
              decisions.set(a.id, [
                { id: "wait", kind: "wait", label: "接続を待っている" },
              ]);
              emit(w, "error", `${a.name}: ${message}`, actual);
            }
          }
        }),
      );
      commitTick(w, decisions);
      this.applyThoughts();
      await this.save();
      return json({ world: w });
    } finally {
      this.busy = false;
    }
  }
  meter(m: Meter) {
    if (!this.world) return;
    const u = this.world.usage[m.role];
    u.input += m.input;
    u.output += m.output;
    if (m.usd === null) u.unpricedRequests = (u.unpricedRequests ?? 0) + 1;
    else u.usd += m.usd;
    u.requests++;
    u.latencyMs = m.latencyMs;
  }
  startThought(snapshot: WorldState, a: Agent, actual: Agent) {
    const w = this.world!;
    this.thinking.add(a.id);
    actual.cognition.status = "thinking";
    actual.cognition.lastThoughtTick = w.tick;
    const task: Thought = {
      agentId: a.id,
      revision: a.cognition.revision,
      worldId: w.id,
      started: w.tick,
      health: a.health,
      knownAlive: snapshot.agents
        .filter(
          (b) =>
            alive(b) && Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y)) <= 3,
        )
        .map((b) => b.id),
    };
    emit(
      w,
      "thought_started",
      `${a.name}が、これからのことを考えはじめた`,
      actual,
    );
    this.ctx.waitUntil(
      (async () => {
        try {
          task.result = await generate(
            this.env,
            writingObservation(snapshot, a),
            thoughtInstruction(snapshot),
            THOUGHT_SCHEMA,
            "thought",
            (m) => this.meter(m),
          );
        } catch (error) {
          w.usage.thought.failures++;
          task.error =
            error instanceof Error ? error.message : "熟考に失敗しました";
        }
        this.completions.push(task);
        this.thinking.delete(a.id);
      })(),
    );
  }
  applyThoughts() {
    for (const task of this.completions.splice(0))
      applyThought(this.world!, task);
  }
  async save() {
    const w = this.world!;
    this.ctx.storage.transactionSync(() => {
      for (const a of w.agents)
        for (const m of a.memories.filter((m) => m.tick >= w.tick - 1))
          this.ctx.storage.sql.exec(
            "INSERT OR IGNORE INTO memories (id, owner, tick, data) VALUES (?, ?, ?, ?)",
            m.id,
            a.id,
            m.tick,
            JSON.stringify(m),
          );
      for (const e of w.events.filter((e) => e.tick >= w.tick - 1))
        this.ctx.storage.sql.exec(
          "INSERT OR IGNORE INTO events (id, tick, data) VALUES (?, ?, ?)",
          e.id,
          e.tick,
          JSON.stringify(e),
        );
      saveSnapshot(this.ctx.storage.sql, w);
    });
  }
}
