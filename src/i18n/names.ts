import cast from "../../data/names.json";
import type { Locale } from "./messages";

const readings = [
  "モミ",
  "シイ",
  "キリ",
  "ヒイラギ",
  "カエデ",
  "レン",
  "カスミ",
  "サク",
  "フジ",
  "リン",
  "ハギ",
  "ツバキ",
  "シズク",
  "ソウ",
  "アンズ",
  "ハシバミ",
  "タチバナ",
  "アズサ",
  "アカネ",
  "ムクゲ",
];
const originals = Object.fromEntries(
  cast.agents.map((a, i) => [a.name, { ja: readings[i], en: a.romaji }]),
);
const descendants: Record<string, { ja: string; en: string }> = {
  澪: { ja: "ミオ", en: "Mio" },
  凪: { ja: "ナギ", en: "Nagi" },
  紡: { ja: "ツムギ", en: "Tsumugi" },
  翠: { ja: "ミドリ", en: "Midori" },
  暁: { ja: "アカツキ", en: "Akatsuki" },
  結: { ja: "ユイ", en: "Yui" },
};

// Names are display aliases: IDs, saved names and AI memories keep their identity.
export function residentName(name: string, locale: Locale): string {
  if (Object.hasOwn(originals, name)) return originals[name][locale];
  const child = /^(澪|凪|紡|翠|暁|結)(\d+)$/.exec(name);
  if (child) return `${descendants[child[1]][locale]} ${child[2]}`;
  return name;
}
