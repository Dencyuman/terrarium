import type { Agent, Candidate, Memory, WorldEvent, WorldState } from "./types";
import { ACTION_NAMES, DIRECTIONS } from "./types";
import {
  adjacent,
  alive,
  clamp,
  distance,
  inside,
  makeAgent,
  random,
} from "./world";
import { availableActions, destination } from "./actions";
export function emit(
  w: WorldState,
  kind: string,
  text: string,
  a?: Agent,
  b?: Agent,
  success = true,
): WorldEvent {
  const e = {
    id: `${w.id}:${w.tick}:${w.events.length}:${a?.id ?? "world"}:${kind}`,
    tick: w.tick,
    kind,
    text,
    actorId: a?.id,
    targetId: b?.id,
    position: a ? { x: a.x, y: a.y } : undefined,
    success,
  };
  w.events.push(e);
  return e;
}
export function remember(
  w: WorldState,
  a: Agent,
  text: string,
  source: Memory["source"],
  ids: number[],
  sourceId?: number,
) {
  a.memories.push({
    id: `${a.id}:${w.tick}:${a.memories.length}:${text.slice(0, 18)}`,
    tick: w.tick,
    text,
    source,
    sourceId,
    relatedIds: ids,
    position: { x: a.x, y: a.y },
  });
}
function relate(a: Agent, b: Agent, affection: number, trust: number) {
  const r = a.relations[b.id] ?? { affection: 0, trust: 50 };
  a.relations[b.id] = {
    affection: clamp(r.affection + affection, -100, 100),
    trust: clamp(r.trust + trust),
  };
}
function death(w: WorldState, a: Agent, cause: string, killer?: Agent) {
  a.diedAt = w.tick;
  for (const d of [{ x: 0, y: 0 }, ...DIRECTIONS]) {
    const p = { x: a.x + d.x, y: a.y + d.y };
    if (!a.inventory) break;
    if (
      inside(w, p) &&
      ["grass", "forest"].includes(w.terrain[p.y][p.x]) &&
      !w.food[p.y][p.x]
    ) {
      w.food[p.y][p.x] = true;
      a.inventory--;
    }
  }
  a.inventory = 0;
  const text = `${a.name}が${cause}。`;
  emit(w, "death", text, a, killer);
  for (const b of w.agents)
    if (alive(b) && distance(a, b) <= 3) {
      remember(w, b, text, "witnessed", [a.id, ...(killer ? [killer.id] : [])]);
      b.aggression = clamp(b.aggression + w.config.costs.aggr_on_witness_death);
    }
}
export function applyAction(
  w: WorldState,
  a: Agent,
  action: Candidate,
  pairs = new Set<string>(),
): boolean {
  if (!alive(a)) return false;
  const allowed = availableActions(w, a).some((v) => v.id === action.id);
  if (
    !allowed ||
    ((action.kind === "speak" || action.kind === "teach") &&
      !action.text?.trim())
  ) {
    a.lastAction = "wait";
    a.lastActionLabel = "状況が変わり、行動できなかった";
    emit(
      w,
      "failed",
      `${a.name}: ${action.label}は不成立`,
      a,
      undefined,
      false,
    );
    return false;
  }
  const c = w.config.costs,
    b = w.agents.find((b) => b.id === action.targetId);
  const spend = (n: number) => {
    a.stamina = clamp(a.stamina - n);
  };
  a.lastAction = action.kind;
  a.lastActionLabel = action.label;
  switch (action.kind) {
    case "wait":
      a.stamina = clamp(a.stamina + c.wait_stamina_restore);
      a.aggression = clamp(a.aggression - c.aggr_decay_on_wait);
      break;
    case "move": {
      const p = destination(w, a, action.direction!);
      if (!p) return false;
      a.x = p.x;
      a.y = p.y;
      spend(c.move_stamina);
      a.hunger = clamp(a.hunger - c[`${w.terrain[a.y][a.x]}_move_hunger`]);
      break;
    }
    case "take": {
      const d = action.direction!;
      w.food[a.y + d.y][a.x + d.x] = false;
      a.inventory++;
      spend(c.take_stamina);
      break;
    }
    case "eat":
      if (a.inventory > 0) a.inventory--;
      else w.food[a.y][a.x] = false;
      a.hunger = clamp(a.hunger + c.eat_hunger_restore);
      spend(c.eat_stamina);
      a.aggression = clamp(a.aggression - c.aggr_on_eat);
      break;
    case "give":
      a.inventory--;
      b!.inventory++;
      spend(c.give_stamina);
      relate(b!, a, 10, 5);
      relate(a, b!, 1, 0);
      a.aggression = clamp(a.aggression - c.aggr_on_give);
      break;
    case "attack":
      b!.health = clamp(b!.health - c.attack_health_damage);
      b!.stamina = clamp(b!.stamina - c.attack_stamina_target_drain);
      spend(c.attack_stamina_cost);
      relate(b!, a, -20, -15);
      a.aggression = clamp(a.aggression - c.aggr_discharge_on_attack);
      b!.aggression = clamp(b!.aggression + c.aggr_on_attacked);
      for (const witness of w.agents)
        if (
          alive(witness) &&
          witness.id !== a.id &&
          witness.id !== b!.id &&
          distance(witness, a) <= 3
        ) {
          remember(w, witness, `${a.name}が${b!.name}を攻撃した`, "witnessed", [
            a.id,
            b!.id,
          ]);
          witness.aggression = clamp(
            witness.aggression + c.aggr_on_witness_attack,
          );
          relate(witness, a, -5, 0);
        }
      if (!alive(b!)) death(w, b!, `${a.name}の攻撃で倒れた`, a);
      break;
    case "embrace":
      spend(c.embrace_stamina_cost);
      b!.stamina = clamp(b!.stamina + c.embrace_stamina_gift);
      b!.aggression = clamp(b!.aggression - c.aggr_on_embrace_received);
      relate(a, b!, 5, 2);
      relate(b!, a, 5, 2);
      break;
    case "look": {
      const d = action.direction!;
      for (let k = 1; k <= 5; k++)
        for (let side = -1; side <= 1; side++) {
          const p = {
            x: a.x + d.x * k - d.y * side,
            y: a.y + d.y * k + d.x * side,
          };
          if (!inside(w, p)) continue;
          a.scouted.push({
            ...p,
            tick: w.tick,
            terrain: w.terrain[p.y][p.x],
            food: w.food[p.y][p.x],
            occupant: w.agents.find((b) => b.x === p.x && b.y === p.y)?.name,
          });
        }
      a.scouted = a.scouted.slice(-24);
      spend(c.look_stamina);
      break;
    }
    case "speak":
      a.speech = { text: action.text!, tick: w.tick, targetId: b?.id };
      spend(c.speak_stamina);
      a.hunger = clamp(a.hunger - c.speak_hunger);
      a.aggression = clamp(a.aggression - c.aggr_on_speak);
      for (const listener of w.agents)
        if (
          listener.id !== a.id &&
          alive(listener) &&
          distance(listener, a) <= 3
        ) {
          remember(
            w,
            listener,
            `${a.name}「${action.text}」`,
            "heard",
            [a.id, ...(b ? [b.id] : [])],
            a.id,
          );
          if (b?.id === listener.id) relate(listener, a, 1, 1);
        }
      break;
    case "teach":
      spend(c.teach_stamina);
      a.speech = { text: action.text!, tick: w.tick, targetId: b!.id };
      remember(w, b!, action.text!, "heard", [a.id], a.id);
      break;
    case "reproduce_with": {
      const key = [a.id, b!.id].sort((x, y) => x - y).join(":");
      if (pairs.has(key)) {
        emit(w, "failed", `${a.name}: 同じ組み合わせでの重複`, a, b, false);
        return false;
      }
      pairs.add(key);
      spend(c.reproduce_stamina_cost);
      a.hunger = clamp(a.hunger - c.reproduce_hunger_cost);
      if (random(w) > c.reproduce_success_prob) {
        a.libido = clamp(a.libido - c.libido_fail_penalty);
        break;
      }
      a.libido = b!.libido = 0;
      let pos;
      for (const parent of [a, b!]) {
        for (const d of DIRECTIONS) {
          const p = { x: parent.x + d.x, y: parent.y + d.y };
          if (
            inside(w, p) &&
            w.terrain[p.y][p.x] !== "water" &&
            !w.agents.some((v) => v.x === p.x && v.y === p.y)
          ) {
            pos = p;
            break;
          }
        }
        if (pos) break;
      }
      if (pos && w.agents.filter(alive).length < w.config.maxPopulation) {
        const id = Math.max(...w.agents.map((a) => a.id)) + 1;
        const child = makeAgent(id, pos.x, pos.y, w);
        child.age = 0;
        child.parents = [a.id, b!.id];
        child.generation = Math.max(a.generation, b!.generation) + 1;
        child.gender = random(w) < 0.5 ? "female" : "male";
        child.inventory = 0;
        child.libido = 0;
        for (const k of ["cooperative", "aggressive", "curious"] as const)
          child.personality[k] = clamp(
            Math.round(
              (a.personality[k] + b!.personality[k]) / 2 + random(w) * 20 - 10,
            ),
          );
        w.agents.push(child);
        emit(
          w,
          "birth",
          `${a.name}と${b!.name}の間に、${child.name}が生まれた`,
          a,
          child,
        );
        remember(
          w,
          a,
          `${b!.name}との子、${child.name}が生まれた`,
          "experienced",
          [b!.id, child.id],
        );
        remember(
          w,
          b!,
          `${a.name}との子、${child.name}が生まれた`,
          "experienced",
          [a.id, child.id],
        );
      }
      break;
    }
  }
  if (!["move", "wait", "look", "take", "eat"].includes(action.kind)) {
    const text =
      action.kind === "speak"
        ? `${a.name}「${action.text}」`
        : action.kind === "teach"
          ? `${a.name}が${b?.name}に「${action.text}」と語り継いだ`
          : action.kind === "give"
            ? `${a.name}が${b?.name}に食料を分けた`
            : action.kind === "attack"
              ? `${a.name}が${b?.name}を攻撃した`
              : action.kind === "embrace"
                ? `${a.name}が${b?.name}に寄り添った`
                : `${a.name}と${b?.name}が命をつなごうとした`;
    emit(w, action.kind, text, a, b);
    remember(w, a, text, "experienced", b ? [b.id] : []);
    if (b && action.kind !== "teach" && action.kind !== "speak")
      remember(w, b, text, "experienced", [a.id]);
  }
  return true;
}
export function commitTick(w: WorldState, decisions: Map<number, Candidate[]>) {
  const cohort = w.agents
      .filter(alive)
      .slice()
      .sort((a, b) => a.id - b.id),
    pairs = new Set<string>();
  const caps: Record<string, number> = {
    wait: 1,
    move: 3,
    take: 5,
    eat: 2,
    give: 2,
    attack: 2,
    embrace: 2,
    look: 1,
    reproduce_with: 1,
    speak: 1,
    teach: 1,
  };
  for (const a of cohort) {
    if (!alive(a)) continue;
    const counts: Record<string, number> = {};
    for (const action of (
      decisions.get(a.id) ?? [{ id: "wait", kind: "wait", label: "判断を待つ" }]
    ).slice(0, 5)) {
      if ((counts[action.kind] ?? 0) >= caps[action.kind]) continue;
      counts[action.kind] = (counts[action.kind] ?? 0) + 1;
      applyAction(w, a, action, pairs);
    }
    a.hunger = clamp(a.hunger - w.config.costs.tick_base_hunger);
    if (!a.hunger)
      a.health = clamp(a.health - w.config.costs.starving_health_drain);
    if (a.age >= w.config.elderAge)
      a.health = clamp(a.health - w.config.costs.elder_health_drain);
    if (!alive(a))
      death(w, a, a.hunger === 0 ? "飢えで倒れた" : "静かに生涯を終えた");
  }
  for (let y = 0; y < w.config.size; y++)
    for (let x = 0; x < w.config.size; x++)
      if (
        !w.food[y][x] &&
        ["grass", "forest"].includes(w.terrain[y][x]) &&
        random(w) < w.config.foodRegen * (w.terrain[y][x] === "forest" ? 2 : 1)
      )
        w.food[y][x] = true;
  w.tick++;
  w.day = Math.floor(w.tick / w.config.ticksPerDay);
  for (const a of w.agents) {
    if (alive(a)) {
      if (w.tick % w.config.ticksPerDay === 0) a.age++;
      if (a.age >= w.config.costs.puberty_age_days)
        a.libido = clamp(
          Math.max(a.libido, w.config.costs.libido_initial) +
            w.config.costs.libido_gain_per_tick,
        );
      if (!a.hunger)
        a.aggression = clamp(a.aggression + w.config.costs.aggr_starving_gain);
    }
    a.memories = a.memories.slice(-256);
  }
  w.events = w.events.slice(-300);
}
