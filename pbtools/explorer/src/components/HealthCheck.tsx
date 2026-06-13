// HealthCheck.tsx — Polls backend, shows reconnect modal when disconnected.

import { createSignal, onMount, onCleanup, Show } from "solid-js";

const POLL_INTERVAL = 5000;
const CHECK_URL = "/api/stats";

export function HealthCheck() {
  const [connected, setConnected] = createSignal(true);
  const [retrying, setRetrying] = createSignal(false);

  let timer: ReturnType<typeof setInterval> | undefined;

  async function check(): Promise<void> {
    try {
      const r = await fetch(CHECK_URL, { signal: AbortSignal.timeout(3000) });
      if (r.ok) {
        setConnected(true);
        return;
      }
    } catch {
      // fall through
    }
    setConnected(false);
  }

  async function retry(): Promise<void> {
    setRetrying(true);
    await check();
    setRetrying(false);
  }

  onMount(() => {
    check();
    timer = setInterval(check, POLL_INTERVAL);
  });

  onCleanup(() => {
    if (timer) clearInterval(timer);
  });

  return (
    <Show when={!connected()}>
      <div class="health-overlay">
        <div class="health-modal">
          <div class="health-icon">⚠</div>
          <h3>Connection lost</h3>
          <p>Unable to reach the backend server.</p>
          <button
            class="filter-pill active"
            onClick={retry}
            disabled={retrying()}
          >
            {retrying() ? "Retrying..." : "Reconnect"}
          </button>
        </div>
      </div>
    </Show>
  );
}
