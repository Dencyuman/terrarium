export type Weather = "sunny" | "cloudy" | "rainy";
export type TimeOfDay = "朝" | "昼" | "夕方" | "夜";
export const WEATHER_LABELS = {
  sunny: "晴れ",
  cloudy: "曇り",
  rainy: "雨",
} as const satisfies Record<Weather, string>;

export function worldTime(tick: number, ticksPerDay: number) {
  const hour =
    ((((tick % ticksPerDay) + ticksPerDay) % ticksPerDay) / ticksPerDay) * 24;
  const minutes = Math.floor(hour * 60 + 1e-8);
  const phase: TimeOfDay =
    hour < 5 || hour >= 20 ? "夜" : hour < 9 ? "朝" : hour < 16 ? "昼" : "夕方";
  return {
    hour,
    phase,
    label: `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`,
  };
}

type RGB = [number, number, number];
const rgb = (hex: string): RGB => [
  parseInt(hex.slice(1, 3), 16),
  parseInt(hex.slice(3, 5), 16),
  parseInt(hex.slice(5, 7), 16),
];
export const color = (value: RGB, alpha = 1) =>
  `rgba(${value.map(Math.round).join(",")},${alpha})`;
const mix = (a: number, b: number, p: number) => a + (b - a) * p;
const mixColor = (a: RGB, b: RGB, p: number): RGB => [
  mix(a[0], b[0], p),
  mix(a[1], b[1], p),
  mix(a[2], b[2], p),
];

export interface Atmosphere {
  sky: RGB;
  horizon: RGB;
  light: RGB;
  daylight: number;
  night: number;
  clouds: number;
  rain: number;
}

// Adjacent stops blend continuously, including across midnight.
const stops = [
  {
    hour: 0,
    sky: "#122337",
    horizon: "#304759",
    light: "#afcbe6",
    daylight: 0,
    night: 1,
  },
  {
    hour: 4,
    sky: "#1d3048",
    horizon: "#51596c",
    light: "#bec9e2",
    daylight: 0,
    night: 1,
  },
  {
    hour: 6,
    sky: "#94b2bf",
    horizon: "#edc7a4",
    light: "#ffe0b4",
    daylight: 0.65,
    night: 0.1,
  },
  {
    hour: 9,
    sky: "#83bdcf",
    horizon: "#d9e6d8",
    light: "#fff1c8",
    daylight: 1,
    night: 0,
  },
  {
    hour: 14,
    sky: "#78b5cc",
    horizon: "#cee2d5",
    light: "#fff2ca",
    daylight: 1,
    night: 0,
  },
  {
    hour: 17,
    sky: "#9697b1",
    horizon: "#edb785",
    light: "#ffc48e",
    daylight: 0.65,
    night: 0,
  },
  {
    hour: 18.5,
    sky: "#696a8c",
    horizon: "#d99178",
    light: "#ffb582",
    daylight: 0.3,
    night: 0.25,
  },
  {
    hour: 20,
    sky: "#25334f",
    horizon: "#5b5875",
    light: "#b6c6e6",
    daylight: 0,
    night: 0.85,
  },
  {
    hour: 24,
    sky: "#122337",
    horizon: "#304759",
    light: "#afcbe6",
    daylight: 0,
    night: 1,
  },
].map((stop) => ({
  ...stop,
  sky: rgb(stop.sky),
  horizon: rgb(stop.horizon),
  light: rgb(stop.light),
}));

export function blendAtmosphere(
  a: Atmosphere,
  b: Atmosphere,
  p: number,
): Atmosphere {
  return {
    sky: mixColor(a.sky, b.sky, p),
    horizon: mixColor(a.horizon, b.horizon, p),
    light: mixColor(a.light, b.light, p),
    daylight: mix(a.daylight, b.daylight, p),
    night: mix(a.night, b.night, p),
    clouds: mix(a.clouds, b.clouds, p),
    rain: mix(a.rain, b.rain, p),
  };
}

export function atmosphereAt(hour: number, weather: Weather): Atmosphere {
  hour = ((hour % 24) + 24) % 24;
  const end = stops.findIndex((stop) => stop.hour > hour);
  const a = stops[end - 1],
    b = stops[end];
  const progress = (hour - a.hour) / (b.hour - a.hour);
  const eased = progress * progress * (3 - 2 * progress);
  const atmosphere = blendAtmosphere(
    { ...a, clouds: 0, rain: 0 },
    { ...b, clouds: 0, rain: 0 },
    eased,
  );
  atmosphere.clouds = weather === "sunny" ? 0 : weather === "cloudy" ? 0.7 : 1;
  atmosphere.rain = weather === "rainy" ? 1 : 0;
  const overcast = mixColor(
    rgb("#283547"),
    rgb("#a3b4bb"),
    atmosphere.daylight,
  );
  atmosphere.sky = mixColor(atmosphere.sky, overcast, atmosphere.clouds * 0.8);
  atmosphere.horizon = mixColor(
    atmosphere.horizon,
    overcast,
    atmosphere.clouds * 0.7,
  );
  return atmosphere;
}

export function atmosphereText(atmosphere: Atmosphere) {
  const backdrop = mixColor(
    mixColor(
      mixColor(atmosphere.sky, atmosphere.horizon, 0.18),
      [15, 30, 66],
      atmosphere.night * 0.3,
    ),
    [46, 62, 77],
    atmosphere.clouds * 0.14,
  );
  const luminance = (value: RGB) =>
    value.reduce((sum, channel, i) => {
      const c = channel / 255;
      return (
        sum +
        (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4) *
          [0.2126, 0.7152, 0.0722][i]
      );
    }, 0);
  const background = luminance(backdrop);
  const contrast = (value: RGB) => {
    const foreground = luminance(value);
    return (
      (Math.max(background, foreground) + 0.05) /
      (Math.min(background, foreground) + 0.05)
    );
  };
  const dark = rgb("#152c36"),
    light = rgb("#f0f3ec");
  const useDark = contrast(dark) > contrast(light);
  const ink = useDark ? dark : light;
  const muted = useDark ? rgb("#324b56") : rgb("#dbe3df");
  return {
    ink: color(ink),
    muted: color(contrast(muted) >= 4.5 ? muted : ink),
  };
}
