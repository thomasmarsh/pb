import { onMount, onCleanup } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";

export function useKeyboardShortcuts(store: Store<AppState, AppAction>): void {
  onMount(() => {
    let pendingChord: string | null = null;
    let chordTimer: ReturnType<typeof setTimeout> | null = null;

    function clearChord(): void {
      pendingChord = null;
      if (chordTimer) { clearTimeout(chordTimer); chordTimer = null; }
    }

    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      const inInput = t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable;
      if (inInput) { clearChord(); return; }

      if (pendingChord === "g") {
        clearChord();
        switch (e.key.toLowerCase()) {
          case "d":
            store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "dashboard" } } });
            return;
          case "a":
            store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "queries" } } });
            return;
          case "e":
            store.dispatch({ tag: "nav", action: { tag: "navigate", route: { view: "errors" } } });
            return;
        }
        return;
      }

      const snap = store.getState();

      switch (e.key) {
        case "/":
          e.preventDefault();
          store.dispatch({ tag: "search", action: { tag: "overlay-open" } });
          break;
        case "?":
          store.dispatch({ tag: "explore", action: { tag: "help-overlay-toggle" } });
          break;
        case "Escape":
          if (snap().search.overlayOpen) {
            store.dispatch({ tag: "search", action: { tag: "overlay-close" } });
          } else if (snap().explore.helpOverlayOpen) {
            store.dispatch({ tag: "explore", action: { tag: "help-overlay-toggle" } });
          }
          break;
        case "[":
          store.dispatch({ tag: "nav", action: { tag: "back" } });
          break;
        case "]":
          store.dispatch({ tag: "nav", action: { tag: "forward" } });
          break;
        case "g":
          pendingChord = "g";
          chordTimer = setTimeout(clearChord, 1000);
          break;
        case "1":
          store.dispatch({ tag: "explore", action: { tag: "sidebar-focus-group", group: "sourceTree" } });
          break;
        case "2":
          store.dispatch({ tag: "explore", action: { tag: "sidebar-focus-group", group: "entityNav" } });
          break;
        case "3":
          store.dispatch({ tag: "explore", action: { tag: "sidebar-focus-group", group: "analysisNav" } });
          break;
        case "T": {
          e.preventDefault();
          const s = snap();
          const route = s.nav.route;
          if (route.view === "tableDetail") {
            const face = s.tables.tableFace;
            store.dispatch({ tag: "tables", action: { tag: "set-table-face", name: route.name, face: face === "source" ? "analysis" : "source", scrollTop: 0 } });
          }
          break;
        }
      }
    }

    document.addEventListener("keydown", handleKey);
    onCleanup(() => {
      document.removeEventListener("keydown", handleKey);
      clearChord();
    });
  });
}
