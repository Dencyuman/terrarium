import { describe, it, expect } from "vitest";
import { DatabaseSync } from "node:sqlite";
import { createWorld } from "../src/simulation/world";
import { demoTick } from "../src/simulation/demo";
import { parseWorld } from "../src/simulation/import";
import {
  snapshotTables,
  saveSnapshot,
  readSnapshot,
  readHistory,
  encodeSnapshot,
} from "../worker/snapshots";

describe("world persistence", () => {
  it("restores an evolved world and rejects malformed imports before simulation", () => {
    const w = createWorld(42);
    for (let i = 0; i < 70; i++) demoTick(w);
    expect(parseWorld(JSON.parse(JSON.stringify(w)))).toEqual(w);
    const corruptions = [
      (v: any) => {
        v.food[0] = [];
      },
      (v: any) => {
        v.agents[0].x = -1;
      },
      (v: any) => {
        v.agents[0].cognition.plan = null;
      },
      (v: any) => {
        delete v.config.costs.move_stamina;
      },
      (v: any) => {
        v.config.ticksPerDay = 0;
      },
      (v: any) => {
        v.agents[1].id = v.agents[0].id;
      },
    ];
    for (const corrupt of corruptions) {
      const value = structuredClone(w);
      corrupt(value);
      expect(() => parseWorld(value)).toThrow();
    }
  });
  it("stores worlds larger than a SQLite row and retains 120 ticks atomically", () => {
    const db = new DatabaseSync(":memory:");
    const sql = {
      exec(query: string, ...args: any[]) {
        return db
          .prepare(query)
          .all(
            ...args.map((v) =>
              v instanceof ArrayBuffer ? new Uint8Array(v) : v,
            ),
          );
      },
    } as unknown as SqlStorage;
    try {
      snapshotTables(sql);
      const w = createWorld(9);
      w.disposition = "森と住人🌱".repeat(150000);
      expect(
        new TextEncoder().encode(JSON.stringify(w)).length,
      ).toBeGreaterThan(2 * 1024 * 1024);
      expect(encodeSnapshot(w).every((p) => p.byteLength <= 512 * 1024)).toBe(
        true,
      );
      saveSnapshot(sql, w);
      expect(readSnapshot(sql)).toEqual(w);
      w.disposition = "小さな世界";
      for (w.tick = 1; w.tick <= 121; w.tick++) saveSnapshot(sql, w);
      expect(readSnapshot(sql)?.tick).toBe(121);
      expect(readSnapshot(sql, 0)).toBeNull();
      const history = readHistory(sql);
      expect(history).toHaveLength(120);
      expect(history.at(-1)?.tick).toBe(2);
    } finally {
      db.close();
    }
  });
});
