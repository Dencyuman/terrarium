import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { translate, type Locale, type MessageKey } from "./messages";

type I18n = {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: MessageKey, params?: Record<string, string | number>) => string;
};
const Context = createContext<I18n | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocale] = useState<Locale>(() => {
    try {
      const saved = localStorage.getItem("terrarium-language");
      if (saved === "en" || saved === "ja") return saved;
    } catch {
      /* Use the browser's language if storage is unavailable. */
    }
    return navigator.language.startsWith("ja") ? "ja" : "en";
  });
  useEffect(() => {
    document.documentElement.lang = locale;
    document.title = `Terrarium — ${translate(locale, "小さな世界の観察室")}`;
    document
      .querySelector('meta[name="description"]')
      ?.setAttribute(
        "content",
        translate(
          locale,
          "小さな命の、終わらない物語。AIが生きる箱庭を観察するTerrarium。",
        ),
      );
    try {
      localStorage.setItem("terrarium-language", locale);
    } catch {
      /* Keep this session usable. */
    }
  }, [locale]);
  const value = useMemo<I18n>(
    () => ({
      locale,
      setLocale,
      t: (key, params) => translate(locale, key, params),
    }),
    [locale],
  );
  return <Context.Provider value={value}>{children}</Context.Provider>;
}

export function useI18n() {
  const value = useContext(Context);
  if (!value) throw new Error("I18nProvider is missing");
  return value;
}
