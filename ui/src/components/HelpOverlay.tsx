// components/HelpOverlay.tsx — Keyboard shortcuts help overlay.

import { For } from "solid-js";
import type { Store } from "../core/store.js";
import type { AppState } from "../app/state.js";
import type { AppAction } from "../app/actions.js";
import { ModalShell } from "./ModalShell.js";

interface Shortcut {
  key: string;
  scope: string;
  action: string;
}

const SHORTCUTS: Shortcut[] = [
  { key: "/",         scope: "Global",          action: "Open search overlay" },
  { key: "?",         scope: "Global",          action: "Show keyboard shortcuts (this panel)" },
  { key: "[",         scope: "Navigation",      action: "Go back one step" },
  { key: "]",         scope: "Navigation",      action: "Go forward one step" },
  { key: "1",         scope: "Sidebar",         action: "Focus Source Tree group" },
  { key: "2",         scope: "Sidebar",         action: "Focus Entity Navigation group" },
  { key: "3",         scope: "Sidebar",         action: "Focus Analysis Navigation group" },
  { key: "G then D",  scope: "Go-to chord",     action: "Go to Dashboard" },
  { key: "G then A",  scope: "Go-to chord",     action: "Go to Ask" },
  { key: "G then E",  scope: "Go-to chord",     action: "Go to Diagnostics" },
  { key: "T",         scope: "Entity Detail",   action: "Toggle Source / Analysis face" },
  { key: "Esc",       scope: "Overlay",         action: "Close overlay" },
];

export function HelpOverlay(props: { store: Store<AppState, AppAction> }) {
  const snap = props.store.getState();
  const isOpen = () => snap().explore.helpOverlayOpen;

  function close(): void {
    props.store.dispatch({ tag: "explore", action: { tag: "help-overlay-toggle" } });
  }

  return (
    <ModalShell open={isOpen()} onClose={close} label="Keyboard shortcuts" width="480px">
      <div class="help-panel-header">
        <h2>Keyboard Shortcuts</h2>
        <button class="help-close-btn" onClick={close} aria-label="Close">×</button>
      </div>
      <table class="data-table help-table">
        <thead>
          <tr><th>Key</th><th>Scope</th><th>Action</th></tr>
        </thead>
        <tbody>
          <For each={SHORTCUTS}>
            {(s) => (
              <tr>
                <td><kbd class="kbd">{s.key}</kbd></td>
                <td style={{ color: "var(--text-muted)" }}>{s.scope}</td>
                <td>{s.action}</td>
              </tr>
            )}
          </For>
        </tbody>
      </table>
      <div class="help-panel-footer">
        Shortcuts are inactive when an input field is focused.
      </div>
    </ModalShell>
  );
}
