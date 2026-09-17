import type { WorldState } from "../src/simulation/types";

// SQLite rows are limited to 2 MiB. Split UTF-8 bytes, preserving multibyte text.
const PART_BYTES = 512 * 1024;
export function encodeSnapshot(world: WorldState): ArrayBuffer[] {
  const bytes = new TextEncoder().encode(JSON.stringify(world));
  const parts: ArrayBuffer[] = [];
  for (let i = 0; i < bytes.length; i += PART_BYTES)
    parts.push(bytes.slice(i, i + PART_BYTES).buffer);
  return parts;
}
export function decodeSnapshot(parts: ArrayBuffer[]): WorldState {
  const decoder = new TextDecoder();
  const text =
    parts.map((part) => decoder.decode(part, { stream: true })).join("") +
    decoder.decode();
  return JSON.parse(text) as WorldState;
}
export function snapshotTables(sql: SqlStorage) {
  sql.exec(
    "CREATE TABLE IF NOT EXISTS history (tick INTEGER PRIMARY KEY, data TEXT)",
  );
  sql.exec(
    "CREATE TABLE IF NOT EXISTS snapshots (tick INTEGER, part INTEGER, data BLOB, PRIMARY KEY (tick, part))",
  );
}
export function saveSnapshot(sql: SqlStorage, world: WorldState) {
  const parts = encodeSnapshot(world);
  sql.exec("DELETE FROM snapshots WHERE tick = ?", world.tick);
  parts.forEach((data, part) =>
    sql.exec(
      "INSERT INTO snapshots (tick, part, data) VALUES (?, ?, ?)",
      world.tick,
      part,
      data,
    ),
  );
  sql.exec("DELETE FROM snapshots WHERE tick < ?", world.tick - 119);
  sql.exec("DELETE FROM history WHERE tick < ?", world.tick - 119);
}
export function readSnapshot(
  sql: SqlStorage,
  tick?: number,
): WorldState | null {
  if (tick === undefined)
    tick =
      [
        ...sql.exec<{ tick: number | null }>(
          "SELECT MAX(tick) AS tick FROM (SELECT tick FROM snapshots UNION ALL SELECT tick FROM history)",
        ),
      ][0]?.tick ?? undefined;
  if (tick === undefined) return null;
  const parts = [
    ...sql.exec<{ data: ArrayBuffer }>(
      "SELECT data FROM snapshots WHERE tick = ? ORDER BY part",
      tick,
    ),
  ];
  if (parts.length) return decodeSnapshot(parts.map((r) => r.data));
  const legacy = [
    ...sql.exec<{ data: string }>(
      "SELECT data FROM history WHERE tick = ?",
      tick,
    ),
  ][0];
  return legacy ? JSON.parse(legacy.data) : null;
}
export function readHistory(sql: SqlStorage) {
  const rows = [
    ...sql.exec<{ tick: number; bytes: number }>(
      "SELECT tick, SUM(bytes) AS bytes FROM (SELECT tick, LENGTH(data) AS bytes FROM snapshots UNION ALL SELECT tick, LENGTH(CAST(data AS BLOB)) AS bytes FROM history WHERE tick NOT IN (SELECT tick FROM snapshots)) GROUP BY tick ORDER BY tick DESC LIMIT 120",
    ),
  ];
  const snapshots: { tick: number; state: WorldState }[] = [];
  let bytes = 0;
  for (const row of rows) {
    if (snapshots.length && bytes + row.bytes > 8 * 1024 * 1024) break;
    const state = readSnapshot(sql, row.tick);
    if (state) snapshots.push({ tick: row.tick, state });
    bytes += row.bytes;
  }
  return snapshots;
}
