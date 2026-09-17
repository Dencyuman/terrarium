import { useI18n } from "../i18n/context";
import type { WorldState } from "../simulation/types";
import { alive } from "../simulation/world";
export function Connections({
  world,
  family,
  onSelect,
}: {
  world: WorldState;
  family: boolean;
  onSelect: (id: number) => void;
}) {
  const { locale, t } = useI18n();
  const agents = family ? world.agents : world.agents.filter(alive),
    n = agents.length;
  const nodes = agents.map((a, i) => ({
    a,
    x: family
      ? 90 + (i % 8) * 95
      : 400 + Math.cos((i / n) * Math.PI * 2 - Math.PI / 2) * 245,
    y: family
      ? 100 + (a.generation - 1) * 130 + Math.floor(i / 8) * 70
      : 320 + Math.sin((i / n) * Math.PI * 2 - Math.PI / 2) * 225,
  }));
  const edges = family
    ? agents.flatMap((a) =>
        a.parents.map((id) => ({ from: id, to: a.id, value: 50 })),
      )
    : agents.flatMap((a) =>
        Object.entries(a.relations)
          .filter(([id, r]) => a.id < Number(id) && Math.abs(r.affection) > 0)
          .map(([id, r]) => ({
            from: a.id,
            to: Number(id),
            value: r.affection,
          })),
      );
  return (
    <section className="connections-view">
      <header>
        <span className="eyebrow">
          {family ? t("LIVES, INTERTWINED") : t("THE SPACE BETWEEN US")}
        </span>
        <h1>{family ? t("命のつづき") : t("見えないつながり")}</h1>
        <p>
          {family
            ? t("ひとつの出会いから、新しい世代へ。")
            : t("同じ世界に生きる。けれど、心の距離はひとりずつ違う。")}
        </p>
      </header>
      <svg
        viewBox={`0 0 800 ${family ? Math.max(650, world.agents.reduce((v, a) => Math.max(v, a.generation), 1) * 180) : 650}`}
        role="img"
        aria-label={family ? t("家系図") : t("関係性グラフ")}
      >
        {edges.map((e, i) => {
          const a = nodes.find((n) => n.a.id === e.from),
            b = nodes.find((n) => n.a.id === e.to);
          return (
            a &&
            b && (
              <path
                key={i}
                d={
                  family
                    ? `M${a.x},${a.y} C${a.x},${(a.y + b.y) / 2} ${b.x},${(a.y + b.y) / 2} ${b.x},${b.y}`
                    : `M${a.x},${a.y} Q400,320 ${b.x},${b.y}`
                }
                fill="none"
                stroke={e.value < 0 ? "#c77e75" : "#a5c3aa"}
                strokeOpacity={0.2 + Math.abs(e.value) / 180}
                strokeWidth={1 + Math.abs(e.value) / 40}
                strokeDasharray={e.value < 0 ? "5 5" : undefined}
              />
            )
          );
        })}
        {nodes.map(({ a, x, y }) => (
          <g
            key={a.id}
            className="graph-node"
            onClick={() => onSelect(a.id)}
            onKeyDown={(e) => {
              if (e.key === "Enter" || e.key === " ") onSelect(a.id);
            }}
            tabIndex={0}
            role="button"
            aria-label={t("{name}を観察", { name: a.name })}
            transform={`translate(${x},${y})`}
          >
            <circle
              r="25"
              fill="#20343c"
              stroke={a.color}
              strokeOpacity=".35"
            />
            <circle r="17" fill={a.color} opacity={a.health > 0 ? 0.2 : 0.05} />
            <text
              y="6"
              textAnchor="middle"
              fill={a.health > 0 ? a.color : "#86918d"}
              fontSize={a.name.length > 5 ? 11 : 13}
            >
              {a.name}
            </text>
            <text y="42" textAnchor="middle" fill="#8c9e9e" fontSize="10">
              {family
                ? t("第{count}世代", { count: a.generation })
                : a.lastActionLabel.length > 15
                  ? `${a.lastActionLabel.slice(0, 14)}…`
                  : a.lastActionLabel}
            </text>
          </g>
        ))}
      </svg>
      {!edges.length && (
        <p className="graph-note">
          {family
            ? t("まだ、最初の世代。新しい命が生まれると、家系がつながります。")
            : t("出会いを重ねると、ここに関係が描かれます。")}
        </p>
      )}
      <div className="graph-legend">
        <span>
          <i /> {family ? t("親から子へ") : t("好意・信頼")}
        </span>
        {!family && (
          <span>
            <i className="negative" />
            {t("距離・対立")}
          </span>
        )}
      </div>
    </section>
  );
}
