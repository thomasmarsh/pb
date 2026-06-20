import { Show } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";

export type Face = "source" | "analysis";

interface DetailHeaderProps {
  name: string;
  badgeClass: string;
  badgeLabel: string;
  face?: Face;
  store?: Store<AppState, AppAction>;
  onToggle?: (face: Face, scrollTop: number) => void;
  scrollAreaRef?: () => HTMLElement | undefined;
  subtitle?: JSX.Element;
}

export function DetailHeader(props: DetailHeaderProps): JSX.Element {
  function toggle(): void {
    const scrollTop = props.scrollAreaRef?.()?.scrollTop ?? 0;
    const next: Face = (props.face ?? "source") === "source" ? "analysis" : "source";
    props.onToggle!(next, scrollTop);
  }

  return (
    <div class="detail-header">
      <div>
        <h2 style={{ "margin": "0", "font-size": "20px" }}>
          {props.name} <span class={`badge ${props.badgeClass}`}>{props.badgeLabel}</span>
        </h2>
        {props.subtitle}
      </div>
      <Show when={props.onToggle}>
        <div class="face-toggle" role="group" aria-label="Content face">
          <button
            class={`face-toggle-btn${(props.face ?? "source") === "source" ? " active" : ""}`}
            onClick={() => (props.face ?? "source") !== "source" && toggle()}
            aria-pressed={(props.face ?? "source") === "source"}
          >
            Source
          </button>
          <button
            class={`face-toggle-btn${(props.face ?? "source") === "analysis" ? " active" : ""}`}
            onClick={() => (props.face ?? "source") !== "analysis" && toggle()}
            aria-pressed={(props.face ?? "source") === "analysis"}
          >
            Analysis
          </button>
        </div>
      </Show>
    </div>
  );
}
