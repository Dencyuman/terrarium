import { useI18n } from "./i18n/context";
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  useMemo,
  type CSSProperties,
} from "react";
import {
  ArrowUpRight,
  BookOpen,
  ChevronDown,
  ChevronRight,
  Download,
  GitFork,
  Leaf,
  LoaderCircle,
  Network,
  Pause,
  Play,
  Plus,
  Settings2,
  SkipForward,
  Sparkles,
  Sprout,
  Users,
  Volume2,
  VolumeX,
  X,
  RotateCcw,
  Cloud,
  HardDrive,
  Search,
} from "lucide-react";
import type { Agent, WorldState } from "./simulation/types";
import { alive, createWorld } from "./simulation/world";
import { demoTick } from "./simulation/demo";
import { parseWorld } from "./simulation/import";
import { WorldCanvas } from "./components/WorldCanvas";
import { Inspector, Portrait } from "./components/Inspector";
import { Connections } from "./components/Connections";
import {
  atmosphereAt,
  atmosphereText,
  WEATHER_LABELS,
  worldTime,
  type Weather,
} from "./game/atmosphere";
import { listLocal, saveLocal } from "./storage";
import { localizedWorld, errorText, worldName } from "./i18n/world";
import { residentName } from "./i18n/names";
import { translate, type Locale } from "./i18n/messages";
import "./styles.css";
type Tab = "world" | "relations" | "family" | "chronicle";
const icons: Record<string, string> = {
  birth: "✧",
  death: "◇",
  speak: "“",
  teach: "⌁",
  give: "❋",
  embrace: "♡",
  attack: "↯",
  thought_started: "◌",
  thought_completed: "✦",
  origin: "✧",
  error: "!",
};
function App() {
  const { locale, setLocale, t } = useI18n();
  const [world, setWorld] = useState(() => createWorld()),
    [hydrated, setHydrated] = useState(false),
    [selected, setSelected] = useState<number | null>(
      window.innerWidth > 960 ? 4 : null,
    ),
    [running, setRunning] = useState(true),
    [speed, setSpeed] = useState(1),
    [tab, setTab] = useState<Tab>("world"),
    [cinematic, setCinematic] = useState(false),
    [modal, setModal] = useState<"create" | "settings" | "worlds" | null>(null),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [search, setSearch] = useState(""),
    [eventFilter, setEventFilter] = useState("all");
  const [status, setStatus] = useState<{
      jev: boolean;
      language: boolean;
      requiresToken: boolean;
      maxTicksPerDay: number;
    } | null>(null),
    [token, setToken] = useState(
      () => sessionStorage.getItem("terrarium-token") || "",
    ),
    [saved, setSaved] = useState<WorldState[]>([]),
    [history, setHistory] = useState<WorldState[]>([]),
    [replay, setReplay] = useState<number | null>(null),
    [audio, setAudio] = useState(false);
  const [weather, setWeather] = useState<Weather>(() => {
    try {
      const saved = localStorage.getItem("terrarium-weather");
      return saved === "cloudy" || saved === "rainy" ? saved : "sunny";
    } catch {
      return "sunny";
    }
  });
  const changeWeather = (next: Weather) => {
    setWeather(next);
    try {
      localStorage.setItem("terrarium-weather", next);
    } catch {
      // The appearance still works for this session if storage is unavailable.
    }
  };
  const stateRef = useRef(world),
    busyRef = useRef(false),
    generation = useRef(0),
    audioRef = useRef<AudioContext | null>(null),
    init = useRef(false),
    fileInput = useRef<HTMLInputElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const [newName, setNewName] = useState(t("こもれびの庭")),
    [newSeed, setNewSeed] = useState("541119842"),
    [newPopulation, setNewPopulation] = useState(20),
    [newMode, setNewMode] = useState<"demo" | "jev" | "legacy_llm">("demo");
  useEffect(() => {
    stateRef.current = world;
  }, [world]);
  useEffect(() => {
    if (init.current) return;
    init.current = true;
    fetch("/api/status")
      .then((r) => r.json())
      .then((data) => setStatus(data as NonNullable<typeof status>))
      .catch(() => {});
    listLocal()
      .then((ws) => {
        setSaved(ws);
        const id = localStorage.getItem("terrarium-current");
        const previous = ws.find((w) => w.id === id);
        if (previous) {
          setWorld(previous);
          setRunning(previous.mode === "demo");
          setSelected(previous.agents.find(alive)?.id ?? null);
        }
      })
      .catch(() =>
        setError(
          t("保存領域を開けませんでした。このタブでは観察を続けられます。"),
        ),
      )
      .finally(() => setHydrated(true));
  }, []);
  useEffect(() => {
    if (!modal) return;
    const prior = document.activeElement as HTMLElement;
    const dialog = dialogRef.current;
    const nodes = () =>
      Array.from(
        dialog?.querySelectorAll<HTMLElement>(
          "button:not(:disabled),input:not([hidden]),select,a[href]",
        ) ?? [],
      );
    nodes()[0]?.focus();
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setModal(null);
        return;
      }
      if (e.key === "Tab") {
        const list = nodes(),
          first = list[0],
          last = list.at(-1);
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last?.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first?.focus();
        }
      }
    };
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("keydown", key);
      prior?.focus();
    };
  }, [modal]);
  const remember = useCallback(
    (next: WorldState) => {
      stateRef.current = next;
      setWorld(next);
      setHistory((h) => {
        const latest = structuredClone(next);
        const result = [latest];
        let size = JSON.stringify(latest).length;
        for (let i = h.length - 1; i >= 0 && result.length < 80; i--) {
          size += JSON.stringify(h[i]).length;
          if (size > 4 * 1024 * 1024) break;
          result.unshift(h[i]);
        }
        return result;
      });
      localStorage.setItem("terrarium-current", next.id);
      saveLocal(next).catch(() =>
        setError(
          t("保存できませんでした。世界を書き出して手元に残してください。"),
        ),
      );
    },
    [t],
  );
  const api = useCallback(
    async (path: string, body?: unknown) => {
      const res = await fetch(path, {
        method: body === undefined ? "GET" : "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const data: any = await res.json();
      if (!res.ok && !data.world)
        throw new Error(data.error || t("接続できませんでした"));
      return data;
    },
    [token, t],
  );
  const step = useCallback(async () => {
    if (busyRef.current) return;
    const current = stateRef.current;
    if (!current.agents.some(alive)) {
      setRunning(false);
      return;
    }
    const gen = generation.current;
    busyRef.current = true;
    setBusy(true);
    try {
      let next: WorldState;
      if (current.mode === "demo") {
        next = structuredClone(current);
        next.narrativeLanguage = locale;
        demoTick(next);
      } else {
        const result = await api(`/api/worlds/${current.id}/tick`, {
          expectedTick: current.tick,
          language: locale,
        });
        next = result.world;
      }
      if (gen === generation.current) {
        remember(next);
        setError("");
      }
    } catch (e) {
      if (gen === generation.current) {
        setError(e instanceof Error ? e.message : t("接続を確認してください"));
        setRunning(false);
      }
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }, [api, remember, locale, t]);
  useEffect(() => {
    if (!hydrated || !running || replay !== null || modal) return;
    const id = setInterval(
      () => {
        if (!document.hidden) void step();
      },
      Math.max(world.mode === "demo" ? 0 : 750, 1500 / speed),
    );
    return () => clearInterval(id);
  }, [hydrated, running, speed, step, replay, modal, world.mode]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement).matches("input,textarea,select") || modal)
        return;
      if (e.code === "Space") {
        e.preventDefault();
        setRunning((v) => !v);
        setReplay(null);
      }
      if (e.key === "Escape") {
        setCinematic(false);
        setSelected(null);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [modal]);
  useEffect(
    () => () => {
      void audioRef.current?.close();
    },
    [],
  );
  const toggleAudio = () => {
    if (audioRef.current) {
      void audioRef.current.close();
      audioRef.current = null;
      setAudio(false);
      return;
    }
    const ctx = new AudioContext();
    audioRef.current = ctx;
    const gain = ctx.createGain();
    gain.gain.value = 0.013;
    gain.connect(ctx.destination);
    [130.81, 196, 261.63, 329.63].forEach((f, i) => {
      const osc = ctx.createOscillator();
      osc.type = "sine";
      osc.frequency.value = f;
      const g = ctx.createGain();
      g.gain.value = i ? 0.2 : 0.3;
      osc.connect(g);
      g.connect(gain);
      osc.start();
    });
    setAudio(true);
  };
  const load = async (w: WorldState) => {
    generation.current++;
    setRunning(false);
    setReplay(null);
    setHistory([]);
    try {
      const latest =
        w.mode === "demo" ? w : (await api(`/api/worlds/${w.id}`)).world;
      remember(latest);
      if (w.mode !== "demo") {
        const savedHistory = await api(`/api/worlds/${w.id}/history`);
        setHistory(
          savedHistory.snapshots
            .map((s: { state: WorldState }) => s.state)
            .reverse(),
        );
      }
      setSelected(latest.agents.find(alive)?.id ?? null);
      setModal(null);
    } catch (e) {
      setError(String(e));
    }
  };
  const create = async (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setRunning(false);
    generation.current++;
    try {
      let next: WorldState;
      if (newMode !== "demo") {
        const data = await api("/api/worlds", {
          name: newName,
          seed: Number(newSeed),
          population: newPopulation,
          mode: newMode,
          language: locale,
        });
        next = data.world;
      } else
        next = createWorld(Number(newSeed), newName, {
          population: newPopulation,
        });
      next.narrativeLanguage = locale;
      setHistory([]);
      setReplay(null);
      remember(next);
      setSelected(next.agents[0]?.id ?? null);
      setModal(null);
      setTab("world");
      setRunning(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };
  const exportWorld = () => {
    const url = URL.createObjectURL(
      new Blob([JSON.stringify(world, null, 2)], { type: "application/json" }),
    );
    const a = document.createElement("a");
    a.href = url;
    a.download = `terrarium-${world.name}-t${world.tick}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };
  const canonicalDisplayed =
    replay === null ? world : (history[replay] ?? world);
  const displayed = useMemo(
    () => localizedWorld(canonicalDisplayed, locale),
    [canonicalDisplayed, locale],
  );
  const time = worldTime(displayed.tick, displayed.config.ticksPerDay);
  const sceneText = atmosphereText(atmosphereAt(time.hour, weather));
  const agent = displayed.agents.find((a) => a.id === selected),
    population = displayed.agents.filter(alive),
    events = displayed.events.filter(
      (e) => e.success !== false && e.kind !== "error",
    );
  const totalCost = Object.values(world.usage).reduce((s, u) => s + u.usd, 0);
  const unpriced = Object.values(world.usage).some((u) => u.unpricedRequests);
  const latest = events.slice(-4).reverse();
  const openWorlds = () => {
    listLocal()
      .then(setSaved)
      .catch(() => {});
    setModal("worlds");
  };
  const changeLanguage = (next: Locale) => {
    if (newName === translate(locale, "こもれびの庭"))
      setNewName(translate(next, "こもれびの庭"));
    setLocale(next);
  };
  return (
    <div
      className={`observatory ${cinematic ? "cinematic" : ""} ${agent ? "has-inspector" : ""}`}
    >
      <header className="topbar">
        <a
          className="brand"
          href="/"
          onClick={(e) => {
            e.preventDefault();
            setTab("world");
          }}
        >
          <img src="/terrarium.svg" alt="" />
          <span>
            TERRARIUM<small>{t("小さな世界の観察室")}</small>
          </span>
        </a>
        <nav aria-label={t("観察ビュー")}>
          {[
            ["world", Leaf, t("箱庭")],
            ["relations", Network, t("つながり")],
            ["family", GitFork, t("家系")],
            ["chronicle", BookOpen, t("年代記")],
          ].map(([id, Icon, label]) => {
            const I = Icon as typeof Leaf;
            return (
              <button
                key={String(id)}
                aria-label={String(label)}
                className={tab === id ? "active" : ""}
                onClick={() => setTab(id as Tab)}
              >
                <I size={15} />
                <span>{String(label)}</span>
              </button>
            );
          })}
        </nav>
        <div className="top-actions">
          <select
            className="language-select"
            aria-label="Language / 言語"
            value={locale}
            onChange={(e) => changeLanguage(e.target.value as Locale)}
          >
            <option value="ja">日本語</option>
            <option value="en">English</option>
          </select>
          <button
            title={audio ? t("環境音を止める") : t("環境音を流す")}
            aria-label={audio ? t("環境音を止める") : t("環境音を流す")}
            onClick={toggleAudio}
          >
            {audio ? <Volume2 size={17} /> : <VolumeX size={17} />}
          </button>
          <button
            title={t("観察の設定")}
            aria-label={t("観察の設定")}
            onClick={() => setModal("settings")}
          >
            <Settings2 size={17} />
          </button>
          <span className="mode-status">
            <i />
            {world.mode === "demo"
              ? t("観察デモ")
              : world.mode === "jev"
                ? t("Jev 接続")
                : t("Luna 接続")}
          </span>
        </div>
      </header>
      <aside className="residents">
        <div className="world-switch">
          <button onClick={openWorlds}>
            <div className="world-icon">
              <Sprout size={21} />
            </div>
            <span>
              {worldName(world.name, locale)}
              <small>
                {world.mode === "demo"
                  ? t("このブラウザに保存")
                  : t(
                      ["localhost", "127.0.0.1"].includes(
                        window.location.hostname,
                      )
                        ? "ローカルに保存"
                        : "クラウドに保存",
                    )}
              </small>
            </span>
            <ChevronDown size={14} />
          </button>
        </div>
        <div className="population-title">
          <h2>{t("この世界の住人")}</h2>
          <span>
            {population.length}
            <small> / {displayed.agents.length}</small>
          </span>
        </div>
        <label className="resident-search">
          <Search size={13} />
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t("住人を探す")}
            aria-label={t("住人を探す")}
          />
          <kbd>⌕</kbd>
        </label>
        <div className="resident-list">
          {displayed.agents
            .filter((a) => {
              const original = canonicalDisplayed.agents.find(
                (person) => person.id === a.id,
              )!.name;
              return [
                original,
                residentName(original, "ja"),
                residentName(original, "en"),
              ].some((name) =>
                name.toLocaleLowerCase().includes(search.toLocaleLowerCase()),
              );
            })
            .map((a) => (
              <button
                key={a.id}
                className={`resident ${a.id === selected ? "selected" : ""} ${a.health <= 0 ? "departed" : ""}`}
                onClick={() => setSelected(a.id)}
              >
                <Portrait agent={a} size={38} />
                <span>
                  <b>
                    {a.name}
                    <i>{a.gender === "female" ? "♀" : "♂"}</i>
                  </b>
                  <small>
                    {a.health <= 0 ? t("物語を終えた") : a.lastActionLabel}
                  </small>
                </span>
                <span
                  className="resident-status"
                  style={{ background: a.health <= 0 ? "#788885" : a.color }}
                />
              </button>
            ))}
        </div>
        <button
          className="new-world"
          onClick={() => {
            setNewSeed(String(Math.floor(Math.random() * 1e9)));
            setModal("create");
          }}
        >
          <Plus size={15} />
          {t("新しい世界をつくる")}
          <ArrowUpRight size={13} />
        </button>
      </aside>
      <main
        className="main-stage"
        style={
          {
            "--scene-ink": sceneText.ink,
            "--scene-muted": sceneText.muted,
          } as CSSProperties
        }
      >
        <div className="world-stats panel">
          <span>
            <b>
              {t("{day}日目", {
                day: String(displayed.day + 1).padStart(2, "0"),
              })}
            </b>
            <small>
              {time.label} · {t(time.phase)}
            </small>
          </span>
          <i />
          <span>
            <Users size={14} />
            <b>{population.length}</b>
            <small>{t("人", { count: population.length })}</small>
          </span>
          <i />
          <span>
            <Sprout size={14} />
            <b>{Math.max(...displayed.agents.map((a) => a.generation))}</b>
            <small>
              {t("世代", {
                count: Math.max(...displayed.agents.map((a) => a.generation)),
              })}
            </small>
          </span>
          <i />
          <span className="tick-label">
            {t("TICK")}
            <b>{String(displayed.tick).padStart(4, "0")}</b>
          </span>
        </div>
        {tab === "world" ? (
          <WorldCanvas
            world={displayed}
            selected={selected}
            onSelect={setSelected}
            cinematic={cinematic}
            onCinematic={() => setCinematic((v) => !v)}
            weather={weather}
            onWeatherSettings={() => setModal("settings")}
          />
        ) : tab === "relations" || tab === "family" ? (
          <Connections
            world={displayed}
            family={tab === "family"}
            onSelect={setSelected}
          />
        ) : (
          <section className="chronicle-view">
            <header>
              <span className="eyebrow">{t("EVERY LIFE LEAVES A TRACE")}</span>
              <h1>{t("この世界の年代記")}</h1>
              <p>{t("何気ないひとことも、大切な出会いも。")}</p>
            </header>
            <div className="event-filters">
              {[
                ["all", t("すべて")],
                ["speak", t("会話")],
                ["birth", t("誕生")],
                ["death", t("旅立ち")],
                ["teach", t("伝承")],
                ["thought_completed", t("目標")],
              ].map(([id, label]) => (
                <button
                  key={id}
                  className={eventFilter === id ? "active" : ""}
                  onClick={() => setEventFilter(id)}
                >
                  {label}
                </button>
              ))}
            </div>
            <div className="chronicle-events">
              {events
                .filter((e) => eventFilter === "all" || e.kind === eventFilter)
                .slice()
                .reverse()
                .map((e) => (
                  <button
                    key={e.id}
                    onClick={() =>
                      e.actorId !== undefined && setSelected(e.actorId)
                    }
                  >
                    <span className={`event-symbol ${e.kind}`}>
                      {icons[e.kind] || "·"}
                    </span>
                    <time>
                      {t("{day}日目", {
                        day: Math.floor(e.tick / world.config.ticksPerDay) + 1,
                      })}
                      <small>T{String(e.tick).padStart(4, "0")}</small>
                    </time>
                    <p>{e.text}</p>
                    <ChevronRight size={14} />
                  </button>
                ))}
            </div>
          </section>
        )}
        {tab === "world" && !cinematic && (
          <section className="live-notes">
            <div>
              <span className="eyebrow">{t("いま、この世界で")}</span>
              <button onClick={() => setTab("chronicle")}>
                {t("年代記へ")}
                <ArrowUpRight size={12} />
              </button>
            </div>
            {latest.map((e) => (
              <button
                className="live-note"
                key={e.id}
                onClick={() =>
                  e.actorId !== undefined && setSelected(e.actorId)
                }
              >
                <span className={`event-symbol ${e.kind}`}>
                  {icons[e.kind] || "·"}
                </span>
                <p>{e.text}</p>
                <time>T{e.tick}</time>
              </button>
            ))}
          </section>
        )}
        {error && (
          <div className="error-toast" role="alert">
            <span>{errorText(error, locale)}</span>
            <button aria-label={t("通知を閉じる")} onClick={() => setError("")}>
              <X size={15} />
            </button>
          </div>
        )}
      </main>
      {agent && (
        <Inspector
          agent={agent}
          world={displayed}
          onClose={() => setSelected(null)}
          onSelect={setSelected}
        />
      )}
      <footer className="playback">
        <div className="playback-left">
          <span className={`status-dot ${running ? "running" : ""}`} />
          <span>
            {replay !== null
              ? t("過去を観察中")
              : busy
                ? t("住人たちが考えています")
                : running
                  ? t("物語が進んでいます")
                  : t("ひとやすみ中")}
            <small>
              {world.mode === "demo"
                ? t("ローカルデモ · API利用なし")
                : `${t("{model} · 推定 ${cost}", { model: world.mode === "jev" ? "Jev" : "Luna", cost: totalCost.toFixed(4) })}${unpriced ? ` · ${t("一部未集計")}` : ""}`}
            </small>
          </span>
        </div>
        <div className="play-controls">
          <button
            className="step-button"
            title={t("1 tick 進める")}
            aria-label={t("1 tick 進める")}
            disabled={busy || replay !== null}
            onClick={() => {
              setRunning(false);
              void step();
            }}
          >
            <SkipForward size={17} />
          </button>
          <button
            className="play-button"
            aria-label={running ? t("一時停止") : t("再生")}
            onClick={() => {
              setReplay(null);
              setRunning((v) => !v);
            }}
          >
            {busy ? (
              <LoaderCircle size={19} className="spin" />
            ) : running ? (
              <Pause size={19} fill="currentColor" />
            ) : (
              <Play size={19} fill="currentColor" />
            )}
          </button>
          <div className="speed-controls">
            {[1, 2, 4].map((s) => (
              <button
                key={s}
                aria-label={t("{speed}倍速", { speed: s })}
                className={speed === s ? "active" : ""}
                onClick={() => setSpeed(s)}
              >
                {s}×
              </button>
            ))}
          </div>
        </div>
        <div className="timeline">
          <label htmlFor="history-range">
            {replay === null ? t("LIVE") : `T${displayed.tick}`}
          </label>
          <input
            id="history-range"
            aria-label={t("観察履歴")}
            type="range"
            min="0"
            max={Math.max(0, history.length - 1)}
            value={replay ?? Math.max(0, history.length - 1)}
            disabled={history.length < 2}
            onChange={(e) => {
              setRunning(false);
              setReplay(Number(e.target.value));
            }}
          />
          <button
            title={t("現在に戻る")}
            aria-label={t("現在に戻る")}
            onClick={() => setReplay(null)}
          >
            <RotateCcw size={13} />
          </button>
        </div>
        <button className="export-button" onClick={exportWorld}>
          <Download size={15} />
          <span>{t("世界を書き出す")}</span>
        </button>
      </footer>
      {cinematic && (
        <button
          className="exit-cinematic panel"
          onClick={() => setCinematic(false)}
        >
          <X size={16} />
          {t("観察室に戻る")}
        </button>
      )}
      {modal && (
        <div
          className="modal-shade"
          onClick={(e) => {
            if (e.target === e.currentTarget) setModal(null);
          }}
        >
          <section
            ref={dialogRef}
            className="modal panel"
            role="dialog"
            aria-modal="true"
            aria-labelledby="modal-title"
          >
            <button
              className="modal-close"
              aria-label={t("閉じる")}
              onClick={() => setModal(null)}
            >
              <X size={20} />
            </button>
            <span className="eyebrow">{t("TERRARIUM OBSERVATORY")}</span>
            <h2 id="modal-title">
              {modal === "create"
                ? t("まだ見ぬ物語を、ひとつ。")
                : modal === "worlds"
                  ? t("あなたの小さな世界")
                  : t("観察の設定")}
            </h2>
            {modal === "create" ? (
              <form onSubmit={create}>
                <label>
                  {t("世界の名前")}
                  <input
                    required
                    maxLength={40}
                    value={newName}
                    onChange={(e) => setNewName(e.target.value)}
                  />
                </label>
                <div className="form-row">
                  <label>
                    {t("地形のシード")}
                    <input
                      type="number"
                      required
                      value={newSeed}
                      onChange={(e) => setNewSeed(e.target.value)}
                    />
                  </label>
                  <label>
                    {t("はじめの住人")}
                    <select
                      value={newPopulation}
                      onChange={(e) => setNewPopulation(Number(e.target.value))}
                    >
                      {[10, 20, 30, 40].map((n) => (
                        <option key={n} value={n}>
                          {t("{count}人", { count: n })}
                        </option>
                      ))}
                    </select>
                  </label>
                </div>
                <label>
                  {t("住人の知能")}
                  <select
                    value={newMode}
                    onChange={(e) =>
                      setNewMode(
                        e.target.value as "demo" | "jev" | "legacy_llm",
                      )
                    }
                  >
                    <option value="demo">
                      {t("観察デモ — 無料・このブラウザで動作")}
                    </option>
                    <option value="jev" disabled={!status?.jev}>
                      {t("Jev — AIがその瞬間を判断")}
                    </option>
                    <option value="legacy_llm" disabled={!status?.language}>
                      {t("Luna — 毎tickの行動生成（従来方式）")}
                    </option>
                  </select>
                </label>
                <p className="form-note">
                  {newMode === "demo"
                    ? t("行動ルールによるデモです。API料金はかかりません。")
                    : t("目標や関係を踏まえて、住人が行動を選びます。")}
                  {newMode === "jev" && !status?.language
                    ? t(
                        "現在は生成LLMが未設定のため、熟考・発話・教育は停止しています。",
                      )
                    : ""}
                </p>
                <button className="primary-button" type="submit">
                  <Sprout size={17} />
                  {t("世界をひらく")}
                </button>
              </form>
            ) : modal === "worlds" ? (
              <>
                <div className="saved-worlds">
                  {saved.map((w) => (
                    <button key={w.id} onClick={() => void load(w)}>
                      <div className="world-icon">
                        <Sprout size={20} />
                      </div>
                      <span>
                        <b>{worldName(w.name, locale)}</b>
                        <small>
                          {t("{day}日目", { day: w.day + 1 })} ·{" "}
                          {t("{count}人", {
                            count: w.agents.filter(alive).length,
                          })}{" "}
                          ·{" "}
                          {w.mode === "demo"
                            ? t("デモ")
                            : w.mode === "jev"
                              ? "Jev"
                              : "Luna"}
                        </small>
                      </span>
                      <ChevronRight size={17} />
                    </button>
                  ))}
                </div>
                <button
                  className="primary-button"
                  onClick={() => setModal("create")}
                >
                  <Plus size={17} />
                  {t("新しい世界")}
                </button>
              </>
            ) : (
              <>
                <label>
                  {t("言語")}
                  <select
                    value={locale}
                    onChange={(e) => changeLanguage(e.target.value as Locale)}
                  >
                    <option value="ja">日本語</option>
                    <option value="en">English</option>
                  </select>
                </label>
                <p className="form-note">
                  {t(
                    "表示と新しく生成する文章の言語です。過去にAIが書いた文章は元の言語で残ります。",
                  )}
                </p>
                <label>
                  {t("天気")}
                  <select
                    value={weather}
                    onChange={(e) => changeWeather(e.target.value as Weather)}
                  >
                    {Object.entries(WEATHER_LABELS).map(([value, label]) => (
                      <option key={value} value={value}>
                        {t(label)}
                      </option>
                    ))}
                  </select>
                </label>
                <p className="form-note">
                  {t(
                    "朝・昼・夕方・夜の背景は、世界の時刻に合わせて移り変わります。",
                  )}
                </p>
                <div className="connection-status">
                  <div>
                    <Cloud size={18} />
                    <span>
                      {t("即時判断 · Jev")}
                      <small>
                        {status?.jev
                          ? t("接続設定済み")
                          : t("サーバーの TYPESAFE_API_KEY を設定してください")}
                      </small>
                    </span>
                    <i className={status?.jev ? "ready" : ""} />
                  </div>
                  <div>
                    <Sparkles size={18} />
                    <span>
                      {t("熟考・言葉 · Luna")}
                      <small>
                        {status?.language
                          ? t("接続設定済み")
                          : t("サーバーの OPENAI_API_KEY を設定してください")}
                      </small>
                    </span>
                    <i className={status?.language ? "ready" : ""} />
                  </div>
                </div>
                <label>
                  {t("観察室の合言葉")}
                  <input
                    type="password"
                    autoComplete="off"
                    value={token}
                    onChange={(e) => {
                      setToken(e.target.value);
                      sessionStorage.setItem("terrarium-token", e.target.value);
                    }}
                    placeholder={t("公開サーバーへ接続するとき")}
                  />
                </label>
                <p className="form-note">
                  {t(
                    "世界は見ている間だけ進みます。タブを閉じると停止し、次回は続きから。生成AIの利用料金はCloudflareとは別です。",
                  )}
                </p>
                <div className="settings-actions">
                  <button onClick={openWorlds}>
                    <Sprout size={16} />
                    {t("世界を選ぶ")}
                  </button>
                  <button onClick={() => setModal("create")}>
                    <Plus size={16} />
                    {t("新しい世界")}
                  </button>
                </div>
                <div className="settings-actions">
                  <button onClick={exportWorld}>
                    <Download size={16} />
                    {t("世界を書き出す")}
                  </button>
                  <button onClick={() => fileInput.current?.click()}>
                    <HardDrive size={16} />
                    {t("世界を読み込む")}
                  </button>
                </div>
                <input
                  ref={fileInput}
                  hidden
                  type="file"
                  accept="application/json"
                  onChange={async (e) => {
                    try {
                      const file = e.target.files?.[0];
                      if (!file) return;
                      if (file.size > 10000000)
                        throw new Error(t("ファイルが大きすぎます"));
                      const w = parseWorld(JSON.parse(await file.text()));
                      for (const a of w.agents)
                        if (a.cognition.status === "thinking")
                          a.cognition.status = "discarded";
                      await load({
                        ...w,
                        id: crypto.randomUUID(),
                        mode: "demo",
                      });
                    } catch (e) {
                      setError(String(e));
                    }
                  }}
                />
                <button
                  className="primary-button"
                  onClick={() => setModal(null)}
                >
                  {t("観察に戻る")}
                </button>
              </>
            )}
            {error && (
              <p className="inline-error" role="alert">
                {errorText(error, locale)}
              </p>
            )}
          </section>
        </div>
      )}
    </div>
  );
}
export default App;
