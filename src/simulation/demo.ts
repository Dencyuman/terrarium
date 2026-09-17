// Explicitly a free local demonstration. These scores are not Jev predictions.
import type { Agent, Candidate, WorldState } from "./types";
import { availableActions } from "./actions";
import { alive, distance, hash } from "./world";
import { commitTick } from "./engine";
export function demoDecision(w: WorldState, a: Agent): Candidate {
  const candidates = availableActions(w, a);
  const scored = candidates
    .map((c) => {
      let score =
        0.1 +
        hash(a.id * 33 + w.tick, c.id.length * 11 + (c.targetId ?? 0), w.seed) *
          0.3;
      const b = w.agents.find((v) => v.id === c.targetId),
        rel = b ? (a.relations[b.id]?.affection ?? 0) : 0;
      if (c.kind === "eat") score += (100 - a.hunger) / 13;
      if (c.kind === "take")
        score += (3 - a.inventory) * 0.8 + (a.hunger < 45 ? 2 : 0);
      if (c.kind === "wait") score += (100 - a.stamina) / 20;
      if (c.kind === "move") {
        const target = { x: a.x + c.direction!.x, y: a.y + c.direction!.y };
        let nearest = 10,
          current = 10;
        for (
          let y = Math.max(0, a.y - 3);
          y <= Math.min(w.config.size - 1, a.y + 3);
          y++
        )
          for (
            let x = Math.max(0, a.x - 3);
            x <= Math.min(w.config.size - 1, a.x + 3);
            x++
          )
            if (w.food[y][x]) {
              nearest = Math.min(nearest, distance(target, { x, y }));
              current = Math.min(current, distance(a, { x, y }));
            }
        score += 0.3 + a.personality.curious / 150;
        if (a.inventory === 0 && nearest < current)
          score += 2 + (100 - a.hunger) / 30;
        if (a.libido > 65) {
          const mate = w.agents
            .filter(
              (b) =>
                alive(b) &&
                b.id !== a.id &&
                b.gender !== a.gender &&
                distance(a, b) <= 3,
            )
            .sort((b, c) => distance(a, b) - distance(a, c))[0];
          if (mate && distance(target, mate) < distance(a, mate)) score += 1.2;
        }
      }
      if (c.kind === "give" && b)
        score +=
          a.personality.cooperative / 55 +
          (100 - b.hunger) / 45 +
          rel / 100 -
          (a.hunger < 30 ? 4 : 0);
      if (c.kind === "embrace")
        score += a.personality.cooperative / 70 + rel / 70;
      if (c.kind === "speak")
        score +=
          (a.personality.cooperative / 100) * 0.5 +
          (w.tick % 9 === a.id % 9 ? 2.5 : 0);
      if (c.kind === "attack")
        score +=
          a.aggression / 25 + a.personality.aggressive / 120 - 1.2 - rel / 50;
      if (c.kind === "teach")
        score +=
          a.memories.length > 3 ? 0.7 + (w.tick % 13 === a.id % 13 ? 3 : 0) : 0;
      if (c.kind === "reproduce_with") score += a.libido / 22 - 2;
      if (c.kind === "look") score += a.personality.curious / 130;
      return { c, score: Math.exp(Math.max(-5, score)) };
    })
    .sort((a, b) => b.score - a.score);
  const total = scored.reduce((s, v) => s + v.score, 0);
  const selected = scored[0].c;
  a.judgment = {
    tick: w.tick,
    selected: selected.id,
    probabilities: Object.fromEntries(
      scored.map((v) => [v.c.id, v.score / total]),
    ),
    labels: Object.fromEntries(candidates.map((c) => [c.id, c.label])),
    confidence: scored[0].score / total,
    needsDeliberation: a.health < 50 ? 0.85 : 0.08,
    source: "demo",
  };
  if (selected.kind === "speak")
    selected.text = [
      "風が気持ちいいね。",
      "向こうの森も見てみたいな。",
      "一緒に少し歩かない？",
      "食べ物、足りてる？",
      "ここ、落ち着くね。",
      "また会えたね。",
    ][(w.tick + a.id) % 6];
  if (selected.kind === "teach")
    selected.text =
      a.memories.at(-1)?.text.slice(0, 100) ||
      "疲れたときは、少し休むと元気が戻るよ。";
  return selected;
}
export function demoTick(w: WorldState) {
  const decisions = new Map<number, Candidate[]>();
  for (const a of w.agents.filter(alive))
    decisions.set(a.id, [demoDecision(w, a)]);
  commitTick(w, decisions);
}
