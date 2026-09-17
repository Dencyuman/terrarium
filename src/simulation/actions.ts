import type { Agent, Candidate, Point, WorldState } from "./types";
import { DIRECTIONS } from "./types";
import { adjacent, alive, distance, inside } from "./world";
export function destination(w: WorldState, a: Agent, d: Point): Point | null {
  if ((!d.x && !d.y) || Math.abs(d.x) > 1 || Math.abs(d.y) > 1) return null;
  for (let k = 1; k <= w.config.size; k++) {
    const p = { x: a.x + d.x * k, y: a.y + d.y * k };
    if (!inside(w, p) || w.terrain[p.y][p.x] === "water") return null;
    if (!w.agents.some((b) => b.id !== a.id && b.x === p.x && b.y === p.y))
      return p;
  }
  return null;
}
export function availableActions(
  w: WorldState,
  a: Agent,
  language = true,
): Candidate[] {
  if (!alive(a)) return [];
  const out: Candidate[] = [
    { id: "wait", kind: "wait", label: "休む。元気を回復する" },
  ];
  const c = w.config.costs;
  const add = (
    kind: Candidate["kind"],
    label: string,
    targetId?: number,
    direction?: Point,
  ) =>
    out.push({
      id: `${kind}${targetId === undefined ? (direction ? `:${direction.x}:${direction.y}` : "") : `:${targetId}`}`,
      kind,
      label,
      targetId,
      direction,
    });
  for (const d of DIRECTIONS) {
    if (a.stamina >= c.move_stamina && destination(w, a, d))
      add("move", `${d.name}へ歩く`, undefined, d);
    const p = { x: a.x + d.x, y: a.y + d.y };
    if (
      inside(w, p) &&
      w.food[p.y][p.x] &&
      a.inventory < a.capacity &&
      a.stamina >= c.take_stamina
    )
      add("take", `${d.name}の食料を拾う`, undefined, d);
  }
  if (
    w.food[a.y][a.x] &&
    a.inventory < a.capacity &&
    a.stamina >= c.take_stamina
  )
    add("take", "足元の食料を拾う", undefined, { x: 0, y: 0 });
  if (a.inventory > 0 || w.food[a.y][a.x])
    add("eat", "食料を食べて満腹度を回復する");
  if (a.stamina >= c.look_stamina)
    for (const d of DIRECTIONS.slice(0, 4))
      if (inside(w, { x: a.x + d.x, y: a.y + d.y }))
        add("look", `${d.name}の遠くを観察する`, undefined, d);
  if (language && a.stamina >= c.speak_stamina)
    add("speak", "周囲へ言葉を投げかける");
  for (const b of w.agents) {
    if (a.id === b.id || !alive(b) || distance(a, b) > 3) continue;
    if (
      a.inventory > 0 &&
      b.inventory < b.capacity &&
      a.stamina >= c.give_stamina
    )
      add("give", `${b.name}に食料を分ける`, b.id);
    if (language && a.stamina >= c.speak_stamina)
      add("speak", `${b.name}に話しかける`, b.id);
    if (!adjacent(a, b)) continue;
    if (a.stamina >= c.attack_stamina_cost)
      add("attack", `${b.name}を攻撃する。相手の体力が減る`, b.id);
    if (a.stamina >= c.embrace_stamina_cost)
      add("embrace", `${b.name}に寄り添う。関係と相手の元気が変わる`, b.id);
    if (language && a.stamina >= c.teach_stamina)
      add("teach", `${b.name}に経験や伝聞を語り継ぐ`, b.id);
    if (
      a.gender !== b.gender &&
      a.age >= c.puberty_age_days &&
      b.age >= c.puberty_age_days &&
      a.stamina >= c.reproduce_stamina_cost
    )
      add(
        "reproduce_with",
        `${b.name}と子をもうける試み。成功は確率による`,
        b.id,
      );
  }
  if (out.length > 255) throw new Error("行動候補が255件を超えました");
  return out;
}
