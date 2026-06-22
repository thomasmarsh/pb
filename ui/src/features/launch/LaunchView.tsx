// features/launch/LaunchView.tsx — Launch view: app selector + MDI desktop.

import { createSignal, Show, type JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";
import { Desktop } from "../../components/windows/Desktop.js";

interface LaunchViewProps {
  store: Store<AppState, AppAction>;
}

const DEMO_APPS = [
  { name: "openpay", label: "OpenPay" },
];

export function LaunchView(props: LaunchViewProps): JSX.Element {
  const snap = props.store.getState();
  const [selectedApp, setSelectedApp] = createSignal<string>("openpay");

  const hasWindows = () => snap().windowManager.windows.length > 0;
  const launchStatus = () => snap().launch.status;

  function handleLaunch(): void {
    const appName = selectedApp();
    props.store.dispatch({
      tag: "launch",
      action: { tag: "load-app", sraName: appName },
    });
  }

  return (
    <div class="launch-view">
      <Show when={!hasWindows()}>
        <div class="launch-controls">
          <h2>Launch Application</h2>
          <div class="launch-form">
            <label class="launch-label">Application:</label>
            <select
              class="launch-select"
              value={selectedApp()}
              onChange={(e) => setSelectedApp(e.currentTarget.value)}
            >
              {DEMO_APPS.map(app => (
                <option value={app.name}>{app.label}</option>
              ))}
            </select>
            <button class="launch-btn" onClick={handleLaunch} disabled={launchStatus() === "loading"}>
              {launchStatus() === "loading" ? "Loading…" : "Launch"}
            </button>
          </div>
          <Show when={snap().launch.error}>
            <div class="launch-error" style={{ color: "var(--error)", "margin-top": "8px", "font-size": "12px" }}>
              {snap().launch.error}
            </div>
          </Show>
          <p class="launch-hint">
            Select a PowerBuilder application (.sra) and click Launch to open
            the MDI frame environment.
          </p>
        </div>
      </Show>
      <Desktop store={props.store} />
    </div>
  );
}
