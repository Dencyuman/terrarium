import { afterEach, describe, expect, it, vi } from "vitest";
import {
  english,
  japanese,
  translate,
  type MessageKey,
} from "../src/i18n/messages";
import { residentName } from "../src/i18n/names";
import { localizedWorld, worldText, worldName } from "../src/i18n/world";
import { createWorld } from "../src/simulation/world";
import { availableActions } from "../src/simulation/actions";
import { language, thoughtInstruction, writingObservation } from "../worker/ai";

afterEach(() => vi.unstubAllGlobals());
describe("Japanese and English presentation", () => {
  it("keeps interpolation fields identical across both languages", () => {
    const fields = (text: string) =>
      [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
    for (const key of Object.keys(english) as MessageKey[]) {
      expect(fields(english[key]), key).toEqual(fields(japanese[key] ?? key));
    }
    expect(translate("en", "{count}人", { count: 20 })).toBe("20 residents");
    expect(translate("en", "{count}人", { count: 1 })).toBe("1 resident");
    expect(translate("en", "{age}日齢", { age: 1 })).toBe("1 day old");
  });
  it("makes old and descendant names readable without renaming custom names", () => {
    expect(residentName("樅", "ja")).toBe("モミ");
    expect(residentName("槿", "en")).toBe("Mukuge");
    expect(residentName("紡12", "ja")).toBe("ツムギ 12");
    expect(residentName("紡12", "en")).toBe("Tsumugi 12");
    expect(residentName("My own name", "ja")).toBe("My own name");
    expect(residentName("constructor", "en")).toBe("constructor");
    expect(worldText("toString", "en")).toBe("toString");
    expect(worldName("My own world", "ja")).toBe("My own world");
  });
  it("localizes saved actions, events and memories while preserving simulation identity", () => {
    const world = createWorld(4);
    const a = world.agents[0];
    a.lastActionLabel = "蓮を攻撃する。相手の体力が減る";
    a.memories.push({
      id: "m",
      tick: 0,
      source: "witnessed",
      relatedIds: [0, 5],
      position: { x: 0, y: 0 },
      text: "樅が蓮を攻撃した",
    });
    a.speech = { text: "一緒に少し歩かない？", tick: 0 };
    const original = structuredClone(world);
    const en = localizedWorld(world, "en"),
      ja = localizedWorld(world, "ja");
    expect(en.agents[0].lastActionLabel).toBe(
      "Attack Ren, reducing their health",
    );
    expect(en.agents[0].memories[0].text).toBe("Momi attacked Ren");
    expect(en.agents[0].speech?.text).toBe("Want to take a walk together?");
    expect(ja.agents[0].memories[0].text).toBe("モミがレンを攻撃した");
    expect(en.agents.map((a) => a.id)).toEqual(
      original.agents.map((a) => a.id),
    );
    expect(world).toEqual(original);
  });
  it("covers all candidate types, birth/death and quoted demo memories", () => {
    const w = createWorld(4),
      a = w.agents[0],
      b = w.agents[1];
    a.x = 5;
    a.y = 5;
    b.x = 6;
    b.y = 5;
    a.age = b.age = 10;
    a.inventory = 1;
    for (const candidate of availableActions(w, a)) {
      expect(worldText(candidate.label, "en"), candidate.label).not.toMatch(
        /[\u3040-\u30ff\u3400-\u9fff]/,
      );
    }
    expect(worldText("樅と椎の間に、紡12が生まれた", "en")).toBe(
      "Tsumugi 12 was born to Momi and Shii",
    );
    expect(worldText("樅が蓮の攻撃で倒れた。", "en")).toBe(
      "Momi died after Ren's attack.",
    );
    expect(worldText("椎「樅が蓮を攻撃した」", "en")).toBe(
      "Shii: “Momi attacked Ren”",
    );
    expect(worldText("AIが以前書いた自由な文章。", "en")).toBe(
      "AIが以前書いた自由な文章。",
    );
  });
  it("requests new AI writing in the selected language without exposing unknown people", async () => {
    const w = createWorld(4),
      a = w.agents[0];
    a.x = 1;
    a.y = 1;
    w.agents[1].x = 18;
    w.agents[1].y = 18;
    w.narrativeLanguage = "en";
    const fetcher = vi.fn(async () =>
      Response.json({
        status: "completed",
        output: [
          {
            type: "message",
            content: [
              {
                type: "output_text",
                text: JSON.stringify({ text: "Let's rest here." }),
              },
            ],
          },
        ],
      }),
    );
    vi.stubGlobal("fetch", fetcher);
    await language(
      w,
      a,
      { id: "speak", kind: "speak", label: "周囲へ言葉を投げかける" },
      { OPENAI_API_KEY: "test" },
      () => {},
    );
    const body = JSON.parse(fetcher.mock.calls[0][1].body as string);
    expect(body.instructions).toContain("short natural English");
    expect(thoughtInstruction(w)).toContain("Output short English");
    const state = writingObservation(w, a);
    expect(state.name_spellings.find((p) => p.id === a.id)?.display).toBe(
      "Momi",
    );
    expect(state.name_spellings.some((p) => p.id === 1)).toBe(false);
    w.narrativeLanguage = "ja";
    expect(thoughtInstruction(w)).toContain("Output short Japanese");
  });
});
