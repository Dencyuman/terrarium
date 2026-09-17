import React from "react";
import ReactDOM from "react-dom/client";
import "@fontsource-variable/cormorant-garamond";
import "@fontsource-variable/noto-sans-jp";
import "@fontsource/ibm-plex-mono/latin-400.css";
import App from "./App";
import { I18nProvider } from "./i18n/context";
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <I18nProvider>
      <App />
    </I18nProvider>
  </React.StrictMode>,
);
