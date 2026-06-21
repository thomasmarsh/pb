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

  function handleLaunch(): void {
    const appName = selectedApp();
    const id = `${appName}-${Date.now()}`;
    props.store.dispatch({
      tag: "windowManager",
      action: {
        tag: "open-window",
        id,
        title: `${appName} — MDI Frame`,
        runtimeWindowName: appName,
      },
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
            <button class="launch-btn" onClick={handleLaunch}>
              Launch
            </button>
          </div>
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
