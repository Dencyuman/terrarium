import type { Agent, Point, WorldState } from "../simulation/types";
import { hash, alive } from "../simulation/world";
import {
  atmosphereAt,
  blendAtmosphere,
  color,
  worldTime,
  type Atmosphere,
  type Weather,
} from "./atmosphere";
type Options = {
  selected: number | null;
  names: boolean;
  relations: boolean;
  reducedMotion: boolean;
  zoom: number;
  pan: Point;
  weather: Weather;
  cinematic: boolean;
};
type Sprite = { x: number; y: number; moving: number };
const mix = (a: number, b: number, p: number) => a + (b - a) * p;
const TAU = Math.PI * 2;
export class WorldRenderer {
  ctx: CanvasRenderingContext2D;
  width = 0;
  height = 0;
  scale = 1;
  origin = { x: 0, y: 0 };
  time = 0;
  lastTime = 0;
  sprites = new Map<number, Sprite>();
  hitPoints: { id: number; x: number; y: number }[] = [];
  frame = 0;
  state: WorldState;
  options: Options;
  raf = 0;
  lastTick = -1;
  atmosphere: Atmosphere;
  atmosphereUpdated = 0;
  effects: {
    x: number;
    y: number;
    color: string;
    started: number;
    kind: string;
  }[] = [];
  constructor(
    public canvas: HTMLCanvasElement,
    state: WorldState,
    options: Options,
  ) {
    this.ctx = canvas.getContext("2d")!;
    this.state = state;
    this.options = options;
    this.atmosphere = atmosphereAt(
      worldTime(state.tick, state.config.ticksPerDay).hour,
      options.weather,
    );
  }
  start() {
    const draw = (now: number) => {
      this.raf = requestAnimationFrame(draw);
      if (
        document.hidden ||
        now - this.lastTime < (this.options.reducedMotion ? 120 : 30)
      )
        return;
      this.lastTime = now;
      this.time = this.options.reducedMotion ? 0 : now / 1000;
      this.render();
    };
    this.raf = requestAnimationFrame(draw);
  }
  stop() {
    cancelAnimationFrame(this.raf);
  }
  project(x: number, y: number, z = 0): Point {
    return {
      x: this.origin.x + (x - y) * 20 * this.scale,
      y: this.origin.y + (x + y) * 10 * this.scale - z * this.scale,
    };
  }
  pick(x: number, y: number) {
    return (
      this.hitPoints
        .map((p) => ({ ...p, d: Math.hypot(p.x - x, p.y - y) }))
        .filter((p) => p.d < Math.max(18, 14 * this.scale))
        .sort((a, b) => a.d - b.d)[0]?.id ?? null
    );
  }
  path(points: number[][], color: string, stroke?: string) {
    const c = this.ctx;
    c.beginPath();
    points.forEach(([x, y], i) => (i ? c.lineTo(x, y) : c.moveTo(x, y)));
    c.closePath();
    c.fillStyle = color;
    c.fill();
    if (stroke) {
      c.strokeStyle = stroke;
      c.lineWidth = 0.6;
      c.stroke();
    }
  }
  ellipse(x: number, y: number, rx: number, ry: number, color: string) {
    const c = this.ctx;
    c.beginPath();
    c.ellipse(x, y, rx, ry, 0, 0, TAU);
    c.fillStyle = color;
    c.fill();
  }
  tile(x: number, y: number, color: string, z = 0) {
    const p = this.project(x, y, z),
      s = this.scale;
    this.path(
      [
        [p.x, p.y],
        [p.x + 20 * s, p.y + 10 * s],
        [p.x, p.y + 20 * s],
        [p.x - 20 * s, p.y + 10 * s],
      ],
      color,
    );
  }
  render() {
    const c = this.ctx,
      rect = this.canvas.getBoundingClientRect(),
      dpr = Math.min(window.devicePixelRatio || 1, 2);
    if (this.width !== rect.width || this.height !== rect.height) {
      this.width = rect.width;
      this.height = rect.height;
      this.canvas.width = rect.width * dpr;
      this.canvas.height = rect.height * dpr;
    }
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, this.width, this.height);
    const w = this.state,
      n = w.config.size;
    const now = performance.now();
    const target = atmosphereAt(
      worldTime(w.tick, w.config.ticksPerDay).hour,
      this.options.weather,
    );
    // Ease each new tick into its light; no wall-clock time advances the world.
    this.atmosphere = blendAtmosphere(
      this.atmosphere,
      target,
      this.options.reducedMotion || !this.atmosphereUpdated
        ? 1
        : 1 - Math.exp(-(now - this.atmosphereUpdated) / 360),
    );
    this.atmosphereUpdated = now;
    const atmosphere = this.atmosphere;
    if (w.tick !== this.lastTick) {
      if (this.lastTick >= 0 && !this.options.reducedMotion)
        for (const a of w.agents) {
          if (
            [
              "take",
              "eat",
              "give",
              "attack",
              "embrace",
              "reproduce_with",
            ].includes(a.lastAction)
          )
            this.effects.push({
              x: a.x + 0.5,
              y: a.y + 0.5,
              color:
                a.lastAction === "attack"
                  ? "#eaa294"
                  : a.lastAction === "eat" || a.lastAction === "take"
                    ? "#ded690"
                    : "#ebc0ce",
              started: this.time,
              kind: a.lastAction,
            });
        }
      this.lastTick = w.tick;
    }
    this.effects = this.effects.filter((e) => this.time - e.started < 1.5);
    this.scale =
      Math.min(
        (this.width - 40) / (n * 40),
        (this.height - 150) / (n * 20 + 90),
      ) * this.options.zoom;
    this.scale = Math.max(this.scale, 0.32);
    this.origin = {
      x: this.width / 2 + this.options.pan.x,
      y: this.height / 2 - n * 10 * this.scale + 14 + this.options.pan.y,
    };
    const center = this.project(n / 2, n / 2);
    const bg = c.createLinearGradient(0, 0, 0, this.height);
    bg.addColorStop(0, color(atmosphere.sky));
    bg.addColorStop(0.7, color(atmosphere.horizon));
    bg.addColorStop(1, color(atmosphere.sky));
    c.fillStyle = bg;
    c.fillRect(0, 0, this.width, this.height);
    this.drawSky();
    c.save();
    c.translate(center.x, center.y + 90 * this.scale);
    c.scale(1, 0.4);
    const shadowRadius = n * 24 * this.scale;
    const shadow = c.createRadialGradient(0, 0, 0, 0, 0, shadowRadius);
    shadow.addColorStop(0, "#172d4266");
    shadow.addColorStop(0.55, "#172d4233");
    shadow.addColorStop(1, "#172d4200");
    c.fillStyle = shadow;
    c.fillRect(
      -shadowRadius,
      -shadowRadius,
      shadowRadius * 2,
      shadowRadius * 2,
    );
    c.restore();
    // Layers of earth make the world a physical specimen suspended in the observatory.
    for (let y = 0; y < n; y++)
      for (let x = 0; x < n; x++) {
        const p = this.project(x, y),
          s = this.scale,
          h = 42 + hash(x, y, w.seed) * 11;
        if (x === n - 1) {
          this.path(
            [
              [p.x + 20 * s, p.y + 10 * s],
              [p.x, p.y + 20 * s],
              [p.x, p.y + (20 + h) * s],
              [p.x + 20 * s, p.y + (10 + h) * s],
            ],
            "#43504a",
          );
          this.path(
            [
              [p.x + 20 * s, p.y + 16 * s],
              [p.x, p.y + 26 * s],
              [p.x, p.y + 31 * s],
              [p.x + 20 * s, p.y + 21 * s],
            ],
            "#69705a",
          );
        }
        if (y === n - 1) {
          this.path(
            [
              [p.x - 20 * s, p.y + 10 * s],
              [p.x, p.y + 20 * s],
              [p.x, p.y + (20 + h) * s],
              [p.x - 20 * s, p.y + (10 + h) * s],
            ],
            "#303e3b",
          );
          this.path(
            [
              [p.x - 20 * s, p.y + 17 * s],
              [p.x, p.y + 27 * s],
              [p.x, p.y + 31 * s],
              [p.x - 20 * s, p.y + 21 * s],
            ],
            "#4c5945",
          );
        }
        const hsh = hash(x, y, w.seed),
          t = w.terrain[y][x];
        const shade =
          t === "forest"
            ? ["#667e5b", "#6c845d", "#728860"]
            : t === "rock"
              ? ["#899485", "#859182", "#939a87"]
              : t === "water"
                ? ["#457e83", "#497f82", "#508789"]
                : ["#91a574", "#98aa79", "#8da174", "#9dad7a"];
        this.tile(x, y, shade[Math.floor(hsh * shade.length)]);
        const m = this.project(x + 0.5, y + 0.5);
        if (t === "water") {
          c.strokeStyle = "#abd8cb45";
          c.lineWidth = s * 0.8;
          c.beginPath();
          const r = Math.sin(this.time * 1.3 + x * 4 + y) * 3;
          c.moveTo(m.x - (7 + r) * s, m.y);
          c.lineTo(m.x + (4 + r) * s, m.y - s);
          c.stroke();
          if (hsh > 0.84) {
            this.ellipse(m.x + 5 * s, m.y + 2 * s, 5 * s, 2.2 * s, "#719979");
            this.ellipse(m.x + 7 * s, m.y, 1.5 * s, 1.4 * s, "#dac7ab");
          }
        } else {
          for (let k = 0; k < 3; k++) {
            const ox = (hash(x + k, y, w.seed + 8) - 0.5) * 18 * s,
              oy = (hash(x, y + k, w.seed + 9) - 0.5) * 7 * s;
            this.ellipse(
              m.x + ox,
              m.y + oy,
              0.8 * s,
              0.5 * s,
              hsh > 0.4 ? "#c7cb9265" : "#4c734855",
            );
          }
        }
      }
    // Render entities in depth order, so residents really walk behind the trees.
    const items: { depth: number; draw: () => void }[] = [];
    for (let y = 0; y < n; y++)
      for (let x = 0; x < n; x++) {
        const t = w.terrain[y][x],
          h = hash(x, y, w.seed),
          p = this.project(x + 0.5, y + 0.5);
        const occupied = w.agents.some(
          (a) => Math.abs(a.x - x) < 1 && Math.abs(a.y - y) < 1,
        );
        if (t === "forest" && h > 0.23)
          items.push({
            depth: x + y + 0.25,
            draw: () => this.tree(p.x, p.y, h, occupied ? 0.7 : 1),
          });
        if (t === "rock" && h > 0.62)
          items.push({
            depth: x + y + 0.2,
            draw: () => this.rock(p.x, p.y, h),
          });
        if (w.food[y][x])
          items.push({
            depth: x + y + 0.4,
            draw: () =>
              this.berry(p.x + 4 * this.scale, p.y + 2 * this.scale, h),
          });
        if (t === "grass" && h > 0.8)
          items.push({
            depth: x + y + 0.1,
            draw: () => this.flowers(p.x, p.y, h),
          });
      }
    if (this.options.relations) this.drawRelations();
    this.hitPoints = [];
    for (const a of w.agents) {
      let sprite = this.sprites.get(a.id);
      if (!sprite) {
        sprite = { x: a.x, y: a.y, moving: 0 };
        this.sprites.set(a.id, sprite);
      }
      const delta = Math.hypot(a.x - sprite.x, a.y - sprite.y);
      sprite.moving = delta > 0.02 ? 1 : 0;
      sprite.x = mix(sprite.x, a.x, this.options.reducedMotion ? 1 : 0.15);
      sprite.y = mix(sprite.y, a.y, this.options.reducedMotion ? 1 : 0.15);
      const p = this.project(sprite.x + 0.5, sprite.y + 0.5);
      this.hitPoints.push({ id: a.id, x: p.x, y: p.y - 10 * this.scale });
      items.push({
        depth: sprite.x + sprite.y + 0.7,
        draw: () => this.agent(a, p, sprite!),
      });
    }
    items.sort((a, b) => a.depth - b.depth).forEach((i) => i.draw());
    if (atmosphere.night > 0) {
      c.fillStyle = `rgba(15, 30, 66, ${atmosphere.night * 0.3})`;
      c.fillRect(0, 0, this.width, this.height);
    }
    if (atmosphere.clouds > 0) {
      c.fillStyle = `rgba(46, 62, 77, ${atmosphere.clouds * 0.14})`;
      c.fillRect(0, 0, this.width, this.height);
    }
    // Sunlight and slow atmospheric motes occupy the same palette as the miniature.
    if (atmosphere.daylight > 0) {
      c.save();
      c.globalCompositeOperation = "screen";
      c.globalAlpha = atmosphere.daylight * (1 - atmosphere.clouds * 0.9);
      const light = c.createLinearGradient(0, 0, this.width * 0.7, this.height);
      light.addColorStop(0, color(atmosphere.light, 0.2));
      light.addColorStop(0.8, color(atmosphere.light, 0));
      c.fillStyle = light;
      c.beginPath();
      c.moveTo(this.width * 0.2, 0);
      c.lineTo(this.width * 0.42, 0);
      c.lineTo(this.width * 0.8, this.height);
      c.lineTo(this.width * 0.55, this.height);
      c.fill();
      c.restore();
    }
    for (let i = 0; i < 34; i++) {
      const u = hash(i, 1, w.seed),
        v = hash(i, 2, w.seed);
      const px =
          (u * this.width + Math.sin(this.time * 0.2 + i) * 30) % this.width,
        py = v * this.height + Math.cos(this.time * 0.28 + i) * 16;
      const alpha =
        (0.15 + (Math.sin(this.time * 0.8 + i) + 1) * 0.16) *
        (1 - atmosphere.clouds);
      c.globalAlpha = alpha;
      this.ellipse(
        px,
        py,
        1 + atmosphere.night * 0.7,
        1 + atmosphere.night * 0.7,
        color(atmosphere.light),
      );
    }
    c.globalAlpha = 1;
    this.drawRain();
    for (const effect of this.effects) {
      const age = this.time - effect.started,
        p = this.project(effect.x, effect.y),
        s = this.scale;
      c.save();
      c.globalAlpha = Math.max(0, 1 - age / 1.5);
      for (let k = 0; k < 5; k++) {
        const angle = (k * TAU) / 5;
        const spread = (3 + age * 10) * s;
        this.ellipse(
          p.x + Math.cos(angle) * spread,
          p.y - 12 * s + Math.sin(angle) * spread * 0.4 - age * 14 * s,
          (1.8 - age * 0.7) * s,
          (1.8 - age * 0.7) * s,
          effect.color,
        );
      }
      c.restore();
    }
    this.drawLabels();
    this.frame++;
  }
  drawSky() {
    const c = this.ctx,
      a = this.atmosphere;
    c.save();
    c.globalAlpha = a.night * (1 - a.clouds);
    for (let i = 0; i < 55; i++) {
      this.ellipse(
        hash(i, 31, this.state.seed) * this.width,
        hash(i, 32, this.state.seed) * this.height * 0.55,
        0.5 + hash(i, 33, this.state.seed),
        0.8,
        "#d4e5f2",
      );
    }
    c.globalAlpha = a.clouds * 0.45;
    for (let i = 0; i < 6; i++) {
      const width = this.width * (0.22 + hash(i, 41, this.state.seed) * 0.22);
      const drift = this.time * (3 + i * 0.35);
      const x =
        ((hash(i, 42, this.state.seed) * (this.width + width * 2) + drift) %
          (this.width + width * 2)) -
        width;
      const y = this.height * (0.08 + hash(i, 43, this.state.seed) * 0.3);
      c.save();
      c.translate(x, y);
      c.scale(1, 0.25);
      const cloud = c.createRadialGradient(0, 0, 0, 0, 0, width);
      cloud.addColorStop(0, color(a.horizon, 0.9));
      cloud.addColorStop(0.55, color(a.horizon, 0.5));
      cloud.addColorStop(1, color(a.horizon, 0));
      c.fillStyle = cloud;
      c.fillRect(-width, -width, width * 2, width * 2);
      c.restore();
    }
    c.restore();
  }
  drawRain() {
    const c = this.ctx,
      rain = this.atmosphere.rain;
    if (rain < 0.01) return;
    c.save();
    c.globalAlpha = rain * 0.4;
    c.strokeStyle = "#dae7ee";
    c.lineWidth = 0.8;
    c.beginPath();
    const count = Math.min(180, Math.floor((this.width * this.height) / 4800));
    for (let i = 0; i < count; i++) {
      const speed = 210 + hash(i, 51, this.state.seed) * 140;
      const y =
        ((hash(i, 52, this.state.seed) * (this.height + 30) +
          this.time * speed) %
          (this.height + 30)) -
        15;
      const x =
        (hash(i, 53, this.state.seed) * (this.width + 60) - this.time * 35) %
        (this.width + 60);
      const wrappedX = ((x + this.width + 60) % (this.width + 60)) - 30;
      c.moveTo(wrappedX, y);
      c.lineTo(wrappedX - 3, y + 11);
    }
    c.stroke();
    c.restore();
  }
  tree(x: number, y: number, h: number, opacity: number) {
    const c = this.ctx,
      s = this.scale,
      k = 0.8 + h * 0.5,
      sway = Math.sin(this.time * 0.65 + h * 20) * s * 0.8;
    c.save();
    c.globalAlpha = opacity;
    this.ellipse(x + 7 * s, y + 4 * s, 13 * s * k, 5 * s, "#233e3440");
    c.fillStyle = "#655e43";
    c.fillRect(x - 1.8 * s, y - 25 * s * k, 3.6 * s, 25 * s * k);
    if (h > 0.55) {
      for (let i = 0; i < 4; i++) {
        const yy = y - (12 + i * 8) * s * k,
          ww = (15 - i * 2.7) * s * k;
        this.path(
          [
            [x + sway, yy - 18 * s * k],
            [x + ww + sway, yy + 3 * s],
            [x + sway, yy + 7 * s],
            [x - ww + sway, yy + 1 * s],
          ],
          ["#3c6352", "#47765b", "#598764", "#72966b"][i],
        );
        this.path(
          [
            [x + sway, yy - 18 * s * k],
            [x + ww + sway, yy + 3 * s],
            [x + sway, yy + 7 * s],
          ],
          "#172f321b",
        );
      }
    } else {
      const hues = ["#4c7555", "#5d865b", "#739761", "#81a368"];
      for (let i = 0; i < 5; i++) {
        const angle = i * 2.4;
        const cx = x + Math.cos(angle) * 7 * s * k + sway,
          cy = y - (25 + Math.sin(angle) * 7) * s * k;
        this.ellipse(cx, cy, 12 * s * k, 12 * s * k, hues[i % 4]);
        this.ellipse(cx - 3 * s, cy - 5 * s, 6 * s * k, 4 * s * k, "#b5c28525");
      }
      this.ellipse(x + sway, y - 40 * s * k, 10 * s * k, 10 * s * k, "#8ca873");
    }
    c.restore();
  }
  rock(x: number, y: number, h: number) {
    const s = this.scale,
      k = 0.7 + h;
    this.ellipse(x + 2 * s, y + 2 * s, 9 * s * k, 4 * s, "#334b3440");
    this.path(
      [
        [x - 8 * s * k, y],
        [x - 6 * s * k, y - 10 * s * k],
        [x + 2 * s * k, y - 14 * s * k],
        [x + 10 * s * k, y - 4 * s * k],
        [x + 7 * s * k, y + 2 * s * k],
      ],
      "#9ba395",
    );
    this.path(
      [
        [x + 2 * s * k, y - 14 * s * k],
        [x + 10 * s * k, y - 4 * s * k],
        [x + 7 * s * k, y + 2 * s * k],
        [x, y - 2 * s * k],
      ],
      "#798a82",
    );
    this.path(
      [
        [x - 8 * s * k, y],
        [x - 6 * s * k, y - 10 * s * k],
        [x + 2 * s * k, y - 14 * s * k],
        [x, y - 2 * s * k],
      ],
      "#b4b8a2",
    );
  }
  berry(x: number, y: number, h: number) {
    const s = this.scale;
    this.ellipse(x, y, 5 * s, 2.3 * s, "#456740");
    this.ellipse(x - 1.5 * s, y - 2 * s, 3 * s, 3 * s, "#678758");
    this.ellipse(x + 2 * s, y - 3 * s, 3 * s, 3 * s, "#73945f");
    for (let i = 0; i < 3; i++)
      this.ellipse(
        x + (i - 1) * 2.1 * s,
        y - (2.5 + (i % 2) * 1.5) * s,
        1.3 * s,
        1.3 * s,
        h > 0.4 ? "#d99069" : "#e4b07c",
      );
  }
  flowers(x: number, y: number, h: number) {
    const c = this.ctx,
      s = this.scale;
    for (let i = 0; i < 3; i++) {
      const xx = x + (i - 1) * 5 * s,
        yy = y + (i % 2) * 3 * s;
      c.strokeStyle = "#648354";
      c.lineWidth = s;
      c.beginPath();
      c.moveTo(xx, yy);
      c.lineTo(xx, yy - 4 * s);
      c.stroke();
      this.ellipse(
        xx,
        yy - 5 * s,
        1.4 * s,
        1.3 * s,
        h > 0.9 ? "#e2d3a6" : "#c4bbd6",
      );
    }
  }
  agent(a: Agent, p: Point, sprite: Sprite) {
    const c = this.ctx,
      s = this.scale,
      bob = sprite.moving
        ? Math.sin(this.time * 13 + a.id) * 1.5 * s
        : Math.sin(this.time * 2 + a.id) * 0.4 * s;
    if (!alive(a)) {
      this.ellipse(p.x, p.y, 6 * s, 2 * s, "#23393170");
      this.path(
        [
          [p.x - 4 * s, p.y],
          [p.x - 3 * s, p.y - 7 * s],
          [p.x + 3 * s, p.y - 9 * s],
          [p.x + 5 * s, p.y],
        ],
        "#9eab9b",
      );
      return;
    }
    this.ellipse(p.x + 2 * s, p.y + 2 * s, 6 * s, 2.5 * s, "#243b3e65");
    if (this.options.selected === a.id) {
      c.strokeStyle = "#f1ddb0";
      c.lineWidth = 1.5;
      c.beginPath();
      c.ellipse(p.x, p.y + 1 * s, 10 * s, 5 * s, 0, 0, TAU);
      c.stroke();
      c.strokeStyle = "#f1ddb044";
      c.beginPath();
      c.ellipse(p.x, p.y, 14 * s, 7 * s, 0, 0, TAU);
      c.stroke();
    }
    const size = a.age < 2 ? 0.75 : 1;
    c.save();
    c.translate(p.x, p.y + bob);
    c.scale(s * size, s * size);
    c.strokeStyle = "#4e5350";
    c.lineWidth = 2.3;
    c.lineCap = "round";
    c.beginPath();
    c.moveTo(-2, -3);
    c.lineTo(-2 + (sprite.moving ? Math.sin(this.time * 13 + a.id) * 2 : 0), 0);
    c.moveTo(2, -3);
    c.lineTo(2 - (sprite.moving ? Math.sin(this.time * 13 + a.id) * 2 : 0), 0);
    c.stroke();
    this.path(
      [
        [-3.5, -13],
        [3.5, -13],
        [6, -3],
        [-6, -3],
      ],
      a.color,
    );
    this.path(
      [
        [0, -13],
        [3.5, -13],
        [6, -3],
        [0, -3],
      ],
      "#33444828",
    );
    this.ellipse(0, -16.5, 4.5, 4.9, "#edccaa");
    this.ellipse(
      -0.6,
      -19,
      4.8,
      2.8,
      a.id % 3 === 0 ? "#65584b" : a.id % 3 === 1 ? "#464841" : "#826846",
    );
    c.fillStyle = "#35494a";
    c.fillRect(1, -17, 0.9, 0.9);
    c.fillRect(3, -17, 0.9, 0.9);
    if (a.inventory > 0) {
      this.ellipse(-5, -8, 2.4, 3, "#ac8c62");
      c.strokeStyle = "#e1c397";
      c.lineWidth = 0.6;
      c.strokeRect(-7, -9, 4, 2);
    }
    if (a.cognition.status === "thinking") {
      for (let i = 0; i < 3; i++)
        this.ellipse(
          -3 + i * 3,
          -29 + Math.sin(this.time * 4 + i) * 1,
          1,
          1,
          "#d9c2ef",
        );
    }
    if (["embrace", "give", "reproduce_with"].includes(a.lastAction)) {
      c.globalAlpha = 0.6 + (Math.sin(this.time * 3) + 1) * 0.2;
      this.ellipse(
        8,
        -24 - Math.sin(this.time * 2) * 2,
        2,
        2,
        a.lastAction === "give" ? "#e8cc84" : "#e4b4be",
      );
    }
    c.restore();
  }
  drawRelations() {
    const c = this.ctx;
    c.save();
    for (const a of this.state.agents)
      for (const [id, r] of Object.entries(a.relations)) {
        const b = this.state.agents.find((b) => b.id === Number(id));
        if (!b || a.id >= b.id || Math.abs(r.affection) < 5) continue;
        const p = this.project(a.x + 0.5, a.y + 0.5),
          q = this.project(b.x + 0.5, b.y + 0.5);
        c.strokeStyle = r.affection > 0 ? "#b9d6b18c" : "#e28c7d99";
        c.lineWidth = Math.min(2.5, Math.abs(r.affection) / 30 + 0.5);
        c.setLineDash(r.affection > 0 ? [] : [4, 4]);
        c.beginPath();
        c.moveTo(p.x, p.y);
        c.quadraticCurveTo(
          (p.x + q.x) / 2,
          (p.y + q.y) / 2 - 30 * this.scale,
          q.x,
          q.y,
        );
        c.stroke();
      }
    c.restore();
  }
  drawLabels() {
    const c = this.ctx,
      s = this.scale;
    const occupied: { x: number; y: number; w: number; h: number }[] = [];
    const place = (
      x: number,
      y: number,
      w: number,
      h: number,
      priority: boolean,
    ) => {
      if (
        !priority &&
        occupied.some(
          (r) =>
            x < r.x + r.w + 4 &&
            x + w + 4 > r.x &&
            y < r.y + r.h + 3 &&
            y + h + 3 > r.y,
        )
      )
        return false;
      occupied.push({ x, y, w, h });
      return true;
    };
    for (const a of this.state.agents
      .slice()
      .sort(
        (a, b) =>
          Number(b.id === this.options.selected) -
          Number(a.id === this.options.selected),
      )) {
      const sprite = this.sprites.get(a.id);
      if (!sprite || !alive(a)) continue;
      const p = this.project(sprite.x + 0.5, sprite.y + 0.5);
      if (this.options.names || a.id === this.options.selected) {
        c.font = `${Math.max(12, 11 * s)}px "Noto Sans JP Variable", sans-serif`;
        c.textAlign = "center";
        c.fillStyle = "#122a2acc";
        const tw = c.measureText(a.name).width;
        if (
          place(
            p.x - tw / 2 - 5,
            p.y + 5 * s,
            tw + 10,
            17,
            a.id === this.options.selected,
          )
        ) {
          c.beginPath();
          c.roundRect(p.x - tw / 2 - 5, p.y + 5 * s, tw + 10, 17, 5);
          c.fill();
          c.fillStyle = a.id === this.options.selected ? "#fff0cb" : "#e7ead7";
          c.fillText(a.name, p.x, p.y + 5 * s + 12.5);
        }
      }
      if (
        a.speech &&
        this.state.tick - a.speech.tick < 3 &&
        (a.id === this.options.selected || this.state.tick - a.speech.tick <= 1)
      ) {
        c.font = '11px "Noto Sans JP Variable", sans-serif';
        const letters = Array.from(a.speech.text);
        let text = letters.join("");
        while (letters.length && c.measureText(text).width > 190) {
          letters.pop();
          text = `${letters.join("")}…`;
        }
        const tw = c.measureText(text).width;
        const yy = p.y - 39 * s;
        if (
          !place(
            p.x - tw / 2 - 9,
            yy - 15,
            tw + 18,
            29,
            a.id === this.options.selected,
          )
        )
          continue;
        c.fillStyle = "#f0ead8ed";
        c.beginPath();
        c.roundRect(p.x - tw / 2 - 9, yy - 15, tw + 18, 24, 7);
        c.fill();
        this.path(
          [
            [p.x - 3, yy + 9],
            [p.x + 3, yy + 9],
            [p.x, yy + 14],
          ],
          "#f0ead8ed",
        );
        c.fillStyle = "#384943";
        c.textAlign = "center";
        c.fillText(text, p.x, yy + 1);
      }
    }
  }
}
