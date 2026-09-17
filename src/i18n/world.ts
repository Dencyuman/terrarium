import type { WorldState } from "../simulation/types";
import { ACTION_NAMES } from "../simulation/types";
import { residentName } from "./names";
import { english, translate, type Locale, type MessageKey } from "./messages";

const fixed: Record<string, string> = {
  世界を見渡している: "Looking around",
  "休む。元気を回復する": "Rest to recover energy",
  足元の食料を拾う: "Pick up food here",
  食料を食べて満腹度を回復する: "Eat to satisfy hunger",
  周囲へ言葉を投げかける: "Speak to everyone nearby",
  "状況が変わり、行動できなかった":
    "Could not act because the situation changed",
  判断を待つ: "Waiting for a decision",
  接続を待っている: "Waiting for a connection",
  "風が気持ちいいね。": "The breeze feels nice.",
  "向こうの森も見てみたいな。": "I'd like to explore that forest.",
  "一緒に少し歩かない？": "Want to take a walk together?",
  "食べ物、足りてる？": "Do you have enough food?",
  "ここ、落ち着くね。": "It's peaceful here.",
  "また会えたね。": "Nice to see you again.",
  "疲れたときは、少し休むと元気が戻るよ。":
    "Rest for a while when you're tired. Your energy will return.",
  まだない: "None yet",
};
const directions: Record<string, string> = {
  北: "north",
  南: "south",
  東: "east",
  西: "west",
  北東: "northeast",
  北西: "northwest",
  南東: "southeast",
  南西: "southwest",
};
const actions = [
  "Rest",
  "Walk",
  "Gather food",
  "Eat",
  "Share food",
  "Attack",
  "Embrace",
  "Look around",
  "Have a child",
  "Speak",
  "Teach",
];
const legacyActions = Object.fromEntries(
  Object.values(ACTION_NAMES).map((name, i) => [name, actions[i]]),
);

// Older saves contain Japanese sentences. Translate only known system templates;
// custom world names and free-form AI writing remain the user's original content.
export function worldText(text: string, locale: Locale): string {
  const name = (value: string) => residentName(value, locale);
  const prose = (value: string) => worldText(value, locale);
  const choose = (ja: string, en: string) => (locale === "ja" ? ja : en);
  if (Object.hasOwn(english, text))
    return translate(locale, text as MessageKey);
  if (Object.hasOwn(fixed, text)) return locale === "en" ? fixed[text] : text;
  if (Object.hasOwn(legacyActions, text))
    return locale === "en" ? legacyActions[text] : text;
  let m: RegExpExecArray | null;
  if (
    (m =
      /^(北東|北西|南東|南西|北|南|東|西)(へ歩く|の食料を拾う|の遠くを観察する)$/.exec(
        text,
      ))
  ) {
    if (locale === "ja") return text;
    return m[2] === "へ歩く"
      ? `Walk ${directions[m[1]]}`
      : m[2] === "の食料を拾う"
        ? `Gather food to the ${directions[m[1]]}`
        : `Look to the ${directions[m[1]]}`;
  }
  const targetActions: Array<[string, (name: string) => string]> = [
    ["に食料を分ける", (n) => `Share food with ${n}`],
    ["に話しかける", (n) => `Speak to ${n}`],
    [
      "を攻撃する。相手の体力が減る",
      (n) => `Attack ${n}, reducing their health`,
    ],
    [
      "に寄り添う。関係と相手の元気が変わる",
      (n) => `Embrace ${n}, affecting your bond and their energy`,
    ],
    ["に経験や伝聞を語り継ぐ", (n) => `Pass on a story to ${n}`],
    [
      "と子をもうける試み。成功は確率による",
      (n) => `Try to have a child with ${n}`,
    ],
  ];
  for (const [suffix, en] of targetActions)
    if (text.endsWith(suffix)) {
      const target = name(text.slice(0, -suffix.length));
      return choose(`${target}${suffix}`, en(target));
    }
  if ((m = /^(\d+)人の、小さな物語がはじまる。$/.exec(text)))
    return choose(text, `A little story begins with ${m[1]} residents.`);
  if ((m = /^(.+)と(.+)の間に、(.+)が生まれた$/.exec(text)))
    return choose(
      `${name(m[1])}と${name(m[2])}の間に、${name(m[3])}が生まれた`,
      `${name(m[3])} was born to ${name(m[1])} and ${name(m[2])}`,
    );
  if ((m = /^(.+)との子、(.+)が生まれた$/.exec(text)))
    return choose(
      `${name(m[1])}との子、${name(m[2])}が生まれた`,
      `My child with ${name(m[1])}, ${name(m[2])}, was born`,
    );
  if ((m = /^(.+)が(.+)に「([\s\S]*)」と語り継いだ$/.exec(text)))
    return choose(
      `${name(m[1])}が${name(m[2])}に「${prose(m[3])}」と語り継いだ`,
      `${name(m[1])} told ${name(m[2])}: “${prose(m[3])}”`,
    );
  if ((m = /^(.+?)「([\s\S]*)」$/.exec(text)))
    return choose(
      `${name(m[1])}「${prose(m[2])}」`,
      `${name(m[1])}: “${prose(m[2])}”`,
    );
  const events: Array<
    [RegExp, (a: string, b: string) => string, (a: string, b: string) => string]
  > = [
    [
      /^(.+)が(.+)に食料を分けた$/,
      (a, b) => `${a}が${b}に食料を分けた`,
      (a, b) => `${a} shared food with ${b}`,
    ],
    [
      /^(.+)が(.+)を攻撃した$/,
      (a, b) => `${a}が${b}を攻撃した`,
      (a, b) => `${a} attacked ${b}`,
    ],
    [
      /^(.+)が(.+)に寄り添った$/,
      (a, b) => `${a}が${b}に寄り添った`,
      (a, b) => `${a} embraced ${b}`,
    ],
    [
      /^(.+)と(.+)が命をつなごうとした$/,
      (a, b) => `${a}と${b}が命をつなごうとした`,
      (a, b) => `${a} and ${b} tried to have a child`,
    ],
    [
      /^(.+)が(.+)の攻撃で倒れた。$/,
      (a, b) => `${a}が${b}の攻撃で倒れた。`,
      (a, b) => `${a} died after ${b}'s attack.`,
    ],
  ];
  for (const [pattern, ja, en] of events)
    if ((m = pattern.exec(text)))
      return choose(ja(name(m[1]), name(m[2])), en(name(m[1]), name(m[2])));
  if ((m = /^(.+)が(飢えで倒れた|静かに生涯を終えた)。$/.exec(text)))
    return choose(
      `${name(m[1])}が${m[2]}。`,
      `${name(m[1])} ${m[2] === "飢えで倒れた" ? "died of starvation" : "passed away peacefully"}.`,
    );
  if ((m = /^(.+)が、これからのことを考えはじめた$/.exec(text)))
    return choose(
      `${name(m[1])}が、これからのことを考えはじめた`,
      `${name(m[1])} began reflecting on what comes next`,
    );
  if ((m = /^(.+)の目標: ([\s\S]*) → ([\s\S]*)$/.exec(text)))
    return choose(
      `${name(m[1])}の目標: ${prose(m[2])} → ${prose(m[3])}`,
      `${name(m[1])}'s goal: ${prose(m[2])} → ${prose(m[3])}`,
    );
  if ((m = /^(.+) → (.+)$/.exec(text)) && Object.hasOwn(legacyActions, m[1]))
    return `${prose(m[1])} → ${name(m[2])}`;
  if ((m = /^(.+): (.+)$/.exec(text)) && Object.hasOwn(errors, m[2]))
    return `${name(m[1])}: ${choose(m[2], errors[m[2]])}`;
  return text;
}

const errors: Record<string, string> = {
  "観察室の合言葉を設定してください。": "Enter the access token in Settings.",
  世界ファイルの形式や値が不正です:
    "This world file has an invalid format or values.",
  "今日のAI実行上限に達しました。無料の観察デモは続けられます。":
    "Today's AI limit has been reached. You can continue with the free demo.",
  選択したAIのキーが未設定です: "The selected AI's API key is not configured.",
  世界が見つかりません: "World not found",
  見つかりません: "Not found",
  まだ判断中です: "A decision is still in progress",
  次の判断まで少し待ってください: "Please wait briefly before the next tick",
  リクエストが不正です: "Invalid request",
  設定が大きすぎます: "Settings are too large",
  設定を読み取れません: "Could not read the settings",
  シードが不正です: "Invalid terrain seed",
  既に存在しています: "This world already exists",
  許可されていない送信元です: "This origin is not allowed",
  再考判定を取得できませんでした: "Could not evaluate the need to reflect",
  "TypeSafe API キーが未設定です": "The TypeSafe API key is not configured",
  "生成 LLM のキーが未設定です":
    "The language model's API key is not configured",
  "Jev の応答がありません": "No response from Jev",
  "Jev の選択肢・確率が不正です":
    "Jev returned an invalid action or probabilities",
  "Jev の confidence が不正です": "Jev returned invalid confidence",
  生成が途中で終了しました: "The generated response was incomplete",
  生成に失敗しました: "Generation failed",
  生成が拒否されました: "The model declined to generate a response",
  生成内容が空です: "The generated response was empty",
  発話内容が不正です: "Invalid speech content",
  発話が不正です: "Invalid speech",
  行動列が不正です: "Invalid action list",
  不明な行動です: "Unknown action",
  方向が不正です: "Invalid direction",
  相手が不正です: "Invalid recipient",
  判断に失敗しました: "The decision failed",
  "考えている間に、重要な前提が変わった":
    "An important assumption changed while thinking",
  熟考結果を採用できなかった: "The reflection could not be applied",
  熟考に失敗しました: "Reflection failed",
};
export function errorText(text: string, locale: Locale) {
  const value = text.replace(/^Error: /, "");
  return locale === "en"
    ? Object.hasOwn(errors, value)
      ? errors[value]
      : worldText(value, locale)
    : value;
}

export function worldName(name: string, locale: Locale) {
  return name === "こもれびの庭" || name === "Sunlit Grove"
    ? translate(locale, "こもれびの庭")
    : name;
}

/** A display-only projection. Never save it or send it back to the simulator. */
export function localizedWorld(world: WorldState, locale: Locale): WorldState {
  const text = (value: string) => worldText(value, locale);
  return {
    ...world,
    name: worldName(world.name, locale),
    agents: world.agents.map((a) => ({
      ...a,
      name: residentName(a.name, locale),
      lastActionLabel: text(a.lastActionLabel),
      speech: a.speech ? { ...a.speech, text: text(a.speech.text) } : undefined,
      judgment: a.judgment
        ? {
            ...a.judgment,
            selected:
              a.judgment.source === "legacy"
                ? a.judgment.selected
                    .split(" → ")
                    .map((value) => residentName(text(value), locale))
                    .join(" → ")
                : a.judgment.selected,
            labels: Object.fromEntries(
              Object.entries(a.judgment.labels).map(([key, value]) => [
                key,
                text(value),
              ]),
            ),
            error: a.judgment.error
              ? errorText(a.judgment.error, locale)
              : undefined,
          }
        : undefined,
      memories: a.memories.map((m) => ({ ...m, text: text(m.text) })),
    })),
    events: world.events.map((e) => ({ ...e, text: text(e.text) })),
  };
}
