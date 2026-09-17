import { readFile, writeFile, chmod } from "node:fs/promises";
let cfg;
try {
  cfg = JSON.parse(
    await readFile(
      new URL("../data/config.local.json", import.meta.url),
      "utf8",
    ),
  ).llm;
} catch {
  console.error("data/config.local.json を読み取れません。");
  process.exit(1);
}
const entries = [
  ["TYPESAFE_API_KEY", cfg.typesafe_api_key],
  ["OPENAI_API_KEY", cfg.openai_api_key],
].filter(([, v]) => typeof v === "string" && v.trim());
if (!entries.length) {
  console.error("移せるキーがありません。");
  process.exit(1);
}
let current = "";
try {
  current = await readFile(".dev.vars", "utf8");
} catch {}
for (const [key, value] of entries) {
  current = current
    .split("\n")
    .filter((line) => !line.startsWith(key + "="))
    .join("\n")
    .trim();
  current += `\n${key}=${JSON.stringify(value)}\n`;
}
await writeFile(".dev.vars", current.trim() + "\n", { mode: 0o600 });
await chmod(".dev.vars", 0o600);
console.log(
  `${entries.map(([key]) => key).join(", ")} を .dev.vars に移しました（値は表示しません）。`,
);
