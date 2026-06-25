// components/windows/Desktop.tsx — MDI desktop container.

import { For, Show, type JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { WindowFrame } from "./WindowFrame.js";
import { WindowRuntimeView } from "./WindowRuntimeView.js";

interface DesktopProps {
  store: Store<AppState, AppAction>;
}

export function Desktop(props: DesktopProps): JSX.Element {
  const snap = props.store.getState();

  const windows = () => snap().windowManager.windows;
  const activeId = () => snap().windowManager.activeWindowId;

  return (
    <div class="wm-desktop">
      <Show when={windows().length === 0}>
        <div class="wm-desktop-empty">
          No windows open. Launch an application to get started.
        </div>
      </Show>
      <For each={windows()}>
        {(win) => (
          <WindowFrame
            win={win}
            isActive={activeId() === win.id}
            store={props.store}
          >
            <WindowRuntimeView windowId={win.id} store={props.store} />
          </WindowFrame>
        )}
      </For>
    </div>
  );
}
