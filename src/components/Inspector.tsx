import { useI18n } from "../i18n/context";
import {
  Heart,
  Leaf,
  Zap,
  Sparkles,
  ChevronRight,
  X,
  BookOpen,
  Footprints,
} from "lucide-react";
import type { Agent, WorldState } from "../simulation/types";
import { ACTION_NAMES } from "../simulation/types";
import { goalProgress } from "../simulation/cognition";
export function Portrait({
  agent,
  size = 48,
}: {
  agent: Agent;
  size?: number;
}) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <defs>
        <radialGradient id={`p${agent.id}`}>
          <stop stopColor={agent.color} stopOpacity=".3" />
          <stop offset="1" stopColor={agent.color} stopOpacity=".05" />
        </radialGradient>
      </defs>
      <rect
        x="1"
        y="1"
        width="62"
        height="62"
        rx="19"
        fill={`url(#p${agent.id})`}
        stroke={agent.color}
        strokeOpacity=".2"
      />
      <ellipse cx="32" cy="53" rx="16" ry="4" fill="#000" opacity=".12" />
      <path d="M24 33h16l7 20H17Z" fill={agent.color} />
      <path d="M32 33h8l7 20H32Z" fill="#17252c" opacity=".13" />
      <circle cx="32" cy="26" r="11" fill="#ebc8a4" />
      <path
        d="M21 25c-5-20 31-21 23 1-2-7-10-4-16-11-1 8-5 6-7 10"
        fill={agent.id % 3 === 0 ? "#7a6854" : "#424b45"}
      />
      <circle cx="33" cy="27" r="1" fill="#33413e" />
      <circle cx="39" cy="27" r="1" fill="#33413e" />
      <path
        d="m35 32 3-.2"
        stroke="#a3745c"
        strokeWidth="1.2"
        strokeLinecap="round"
      />
    </svg>
  );
}
const percent = (v: number) => `${Math.round(v * 100)}%`;
export function Inspector({
  agent: a,
  world,
  onClose,
  onSelect,
}: {
  agent: Agent;
  world: WorldState;
  onClose: () => void;
  onSelect: (id: number) => void;
}) {
  const { locale, t } = useI18n();
  const alternatives = a.judgment
    ? Object.entries(a.judgment.probabilities)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 4)
    : [];
  const rels = Object.entries(a.relations)
    .sort((a, b) => Math.abs(b[1].affection) - Math.abs(a[1].affection))
    .slice(0, 3);
  return (
    <aside className="inspector panel">
      <div className="panel-heading">
        <span className="eyebrow">{t("ひとりの物語")}</span>
        <button aria-label={t("詳細を閉じる")} onClick={onClose}>
          <X size={16} />
        </button>
      </div>
      <div className="resident-heading">
        <Portrait agent={a} size={64} />
        <div>
          <h2>
            {a.name}
            <span>{a.gender === "female" ? "♀" : "♂"}</span>
          </h2>
          <p>
            {t("{age}日齢", { age: a.age })} <i />{" "}
            {t("第{count}世代", { count: a.generation })}{" "}
            {a.health <= 0 ? t("· 故人") : ""}
          </p>
        </div>
        <div
          className="alive-dot"
          style={{ background: a.health > 0 ? a.color : "#777" }}
        />
      </div>
      <div className="current-action">
        <Footprints size={14} />
        <span>{a.lastActionLabel}</span>
      </div>
      <div className="vitals">
        {[
          [Heart, t("体力"), a.health, "rose"],
          [Leaf, t("満腹"), a.hunger, "green"],
          [Zap, t("元気"), a.stamina, "gold"],
        ].map(([Icon, label, value, color]) => {
          const I = Icon as typeof Heart;
          return (
            <div key={String(label)}>
              <I size={13} />
              <span>{String(label)}</span>
              <div className={`meter ${color}`}>
                <i style={{ width: `${value}%` }} />
              </div>
              <b>{String(value)}</b>
            </div>
          );
        })}
      </div>
      <div className="traits">
        <span>
          {t("協調")}
          <b>{a.personality.cooperative}</b>
        </span>
        <span>
          {t("攻撃")}
          <b>{a.personality.aggressive}</b>
        </span>
        <span>
          {t("好奇")}
          <b>{a.personality.curious}</b>
        </span>
      </div>
      <section className="inspector-section">
        <div className="section-heading">
          <h3>
            <Sparkles size={14} />
            {t("いま、心が向く先")}
          </h3>
          <span className="tiny-pill">
            {world.mode === "demo"
              ? t("デモの選択傾向")
              : world.mode === "legacy_llm"
                ? "Luna"
                : "System 1"}
          </span>
        </div>
        {alternatives.length ? (
          <div className="alternatives">
            {alternatives.map(([id, p], i) => (
              <div className={i === 0 ? "chosen" : ""} key={id}>
                <div>
                  <span>{a.judgment!.labels[id]}</span>
                  <b>{percent(p)}</b>
                </div>
                <div className="probability">
                  <i style={{ width: percent(p) }} />
                </div>
              </div>
            ))}
          </div>
        ) : (
          <p className="empty-copy">
            {a.judgment?.source === "legacy"
              ? a.judgment.selected
              : t("次の瞬間に、何を選ぶだろう。")}
          </p>
        )}
        {world.mode !== "legacy_llm" && (
          <div className="deliberation">
            <span
              className={
                a.cognition.status === "thinking" ? "thinking-dot" : ""
              }
            />
            <span>
              {a.cognition.status === "thinking"
                ? t("これからのことを考えている")
                : t("考え直す必要性")}
            </span>
            <b>{a.judgment ? percent(a.judgment.needsDeliberation) : "—"}</b>
          </div>
        )}
        {a.judgment?.error && (
          <p className="inline-error">{a.judgment.error}</p>
        )}
      </section>
      <section className="inspector-section">
        <div className="section-heading">
          <h3>{t("小さな目標")}</h3>
          <span className="eyebrow">{t("GOAL")}</span>
        </div>
        <p className={a.cognition.goal ? "goal-copy" : "empty-copy"}>
          {a.cognition.goal?.description ?? t("まだ、目標は生まれていない。")}
        </p>
        {a.cognition.plan.length > 0 && (
          <ol className="plan">
            {a.cognition.plan.map((p, i) => (
              <li key={i}>{p}</li>
            ))}
          </ol>
        )}
        {goalProgress(a)
          ?.filter((p) => "progress" in p)
          .map((p, i) => (
            <div className="meter green" key={i}>
              <i
                style={{
                  width: `${("progress" in p ? Number(p.progress) : 0) * 100}%`,
                }}
              />
            </div>
          ))}
      </section>
      {rels.length > 0 && (
        <section className="inspector-section">
          <div className="section-heading">
            <h3>{t("つながり")}</h3>
            <span className="eyebrow">{t("BONDS")}</span>
          </div>
          {rels.map(([id, r]) => {
            const b = world.agents.find((b) => b.id === Number(id));
            return (
              b && (
                <button
                  className="relation-row"
                  key={id}
                  onClick={() => onSelect(b.id)}
                >
                  <Portrait agent={b} size={28} />
                  <span>{b.name}</span>
                  <div
                    className={`bond-line ${r.affection < 0 ? "negative" : ""}`}
                  >
                    <i style={{ width: `${Math.abs(r.affection)}%` }} />
                  </div>
                  <b>
                    {r.affection > 0 ? "+" : ""}
                    {r.affection}
                  </b>
                  <ChevronRight size={12} />
                </button>
              )
            );
          })}
        </section>
      )}
      <section className="inspector-section">
        <div className="section-heading">
          <h3>
            <BookOpen size={14} />
            {t("心に残ること")}
          </h3>
          <span className="eyebrow">{t("MEMORIES")}</span>
        </div>
        {a.memories.length ? (
          a.memories
            .slice(-3)
            .reverse()
            .map((m) => (
              <div className="memory" key={m.id}>
                <span>
                  T{m.tick} ·{" "}
                  {m.source === "heard"
                    ? t("聞いた話")
                    : m.source === "witnessed"
                      ? t("目にしたこと")
                      : t("自身の経験")}
                </span>
                <p>{m.text}</p>
              </div>
            ))
        ) : (
          <p className="empty-copy">{t("この世界での思い出を、これから。")}</p>
        )}
      </section>
    </aside>
  );
}
