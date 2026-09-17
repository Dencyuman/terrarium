import { useI18n } from "../i18n/context";
import { useEffect, useRef, useState } from "react";
import {
  Minus,
  Plus,
  Maximize,
  Sun,
  Cloud,
  CloudRain,
  Tags,
  Network,
  Focus,
} from "lucide-react";
import type { WorldState } from "../simulation/types";
import { WorldRenderer } from "../game/renderer";
import { WEATHER_LABELS, worldTime, type Weather } from "../game/atmosphere";
export function WorldCanvas({
  world,
  selected,
  onSelect,
  cinematic,
  onCinematic,
  weather,
  onWeatherSettings,
}: {
  world: WorldState;
  selected: number | null;
  onSelect: (id: number | null) => void;
  cinematic: boolean;
  onCinematic: () => void;
  weather: Weather;
  onWeatherSettings: () => void;
}) {
  const { locale, t } = useI18n();
  const canvas = useRef<HTMLCanvasElement>(null),
    renderer = useRef<WorldRenderer | null>(null);
  const [zoom, setZoom] = useState(1.08),
    [names, setNames] = useState(true),
    [relations, setRelations] = useState(false),
    [pan, setPan] = useState({ x: 0, y: 0 });
  const drag = useRef<{
    x: number;
    y: number;
    px: number;
    py: number;
    moved: boolean;
  } | null>(null);
  const reducedMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches;
  useEffect(() => {
    const r = new WorldRenderer(canvas.current!, world, {
      selected,
      names,
      weather,
      relations,
      zoom,
      pan,
      reducedMotion,
      cinematic,
    });
    renderer.current = r;
    r.start();
    return () => r.stop();
  }, []);
  useEffect(() => {
    if (renderer.current) {
      renderer.current.state = world;
      renderer.current.options = {
        selected,
        names,
        weather,
        relations,
        zoom,
        pan,
        reducedMotion,
        cinematic,
      };
    }
  }, [
    world,
    selected,
    names,
    weather,
    relations,
    zoom,
    pan,
    cinematic,
    reducedMotion,
  ]);
  const adjust = (d: number) =>
    setZoom((v) => Math.min(2.5, Math.max(0.6, v + d)));
  const { phase } = worldTime(world.tick, world.config.ticksPerDay);
  const WeatherIcon =
    weather === "rainy" ? CloudRain : weather === "cloudy" ? Cloud : Sun;
  const caption = {
    朝: t("朝の光が、森をゆっくり起こす。"),
    昼: t("風が通り、物語が生まれる。"),
    夕方: t("夕色が、木々を包んでいく。"),
    夜: t("森が静かに、夜を迎える。"),
  };
  return (
    <section
      className="world-viewport"
      aria-label={t("箱庭のマップ")}
      data-time-of-day={phase}
      data-weather={weather}
    >
      <canvas
        ref={canvas}
        aria-label={t(
          "住人をクリックして観察。ドラッグで移動、ホイールで拡大縮小。住人一覧からも選択できます。",
        )}
        onPointerDown={(e) => {
          canvas.current!.setPointerCapture(e.pointerId);
          drag.current = {
            x: e.clientX,
            y: e.clientY,
            px: pan.x,
            py: pan.y,
            moved: false,
          };
        }}
        onPointerMove={(e) => {
          if (!drag.current) return;
          const d = drag.current,
            dx = e.clientX - d.x,
            dy = e.clientY - d.y;
          if (Math.abs(dx) + Math.abs(dy) > 4) d.moved = true;
          if (d.moved) setPan({ x: d.px + dx, y: d.py + dy });
        }}
        onPointerUp={(e) => {
          if (drag.current && !drag.current.moved) {
            const rect = canvas.current!.getBoundingClientRect();
            onSelect(
              renderer.current!.pick(
                e.clientX - rect.left,
                e.clientY - rect.top,
              ),
            );
          }
          drag.current = null;
        }}
        onPointerCancel={() => {
          drag.current = null;
        }}
        onWheel={(e) => adjust(e.deltaY > 0 ? -0.08 : 0.08)}
      />
      <div className="world-caption">
        <span className="eyebrow">
          {t("FIELD NOTES")} · {String(world.seed).slice(-6)}
        </span>
        <h1>{world.name}</h1>
        <p>{caption[phase]}</p>
      </div>
      <button
        className="world-weather"
        onClick={onWeatherSettings}
        aria-label={t("天気を設定：{weather}", {
          weather: t(WEATHER_LABELS[weather]),
        })}
      >
        <WeatherIcon
          className="weather-symbol"
          size={26}
          strokeWidth={1.25}
          aria-hidden="true"
        />
        <span>
          {t("天気")} · {t(WEATHER_LABELS[weather])}
          <small>
            {t("{size} × {size} の小さな世界", { size: world.config.size })}
          </small>
        </span>
      </button>
      <div className="compass" aria-hidden="true">
        <span>N</span>
        <svg viewBox="0 0 50 50">
          <path
            d="M25 7 31 25 25 43 19 25Z"
            fill="none"
            stroke="currentColor"
          />
          <path d="m25 7 6 18h-6Z" fill="currentColor" />
          <path d="M7 25h36" stroke="currentColor" opacity=".4" />
        </svg>
      </div>
      <div className="canvas-tools panel">
        <button
          title={t("縮小")}
          aria-label={t("縮小")}
          onClick={() => adjust(-0.15)}
        >
          <Minus size={16} />
        </button>
        <span>{Math.round(zoom * 100)}%</span>
        <button
          title={t("拡大")}
          aria-label={t("拡大")}
          onClick={() => adjust(0.15)}
        >
          <Plus size={16} />
        </button>
        <i />
        <button
          title={t("視点を戻す")}
          aria-label={t("視点を戻す")}
          onClick={() => {
            setPan({ x: 0, y: 0 });
            setZoom(1.08);
          }}
        >
          <Focus size={16} />
        </button>
        <button
          title={t("名前を表示")}
          aria-label={t("名前を表示")}
          aria-pressed={names}
          className={names ? "active" : ""}
          onClick={() => setNames((v) => !v)}
        >
          <Tags size={16} />
        </button>
        <button
          title={t("関係を表示")}
          aria-label={t("関係を表示")}
          aria-pressed={relations}
          className={relations ? "active" : ""}
          onClick={() => setRelations((v) => !v)}
        >
          <Network size={16} />
        </button>
        <i />
        <button
          title={t("没入モード")}
          aria-label={t("没入モード")}
          aria-pressed={cinematic}
          onClick={onCinematic}
        >
          <Maximize size={16} />
        </button>
      </div>
      <div className="map-hint">
        {t("ドラッグで移動")}
        <span>·</span>
        {t("住人をクリックして観察")}
      </div>
    </section>
  );
}
