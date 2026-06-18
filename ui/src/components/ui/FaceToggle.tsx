// components/FaceToggle.tsx — Source/Analysis face toggle with phase indicator.

import { onMount, onCleanup } from "solid-js";
import type { JSX } from "solid-js";

export type Face = "source" | "analysis";

interface FaceToggleProps {
  face: Face;
  phaseLabel: string;
  onToggle: (newFace: Face, scrollTop: number) => void;
  scrollAreaRef?: () => HTMLElement | undefined;
}

function isInputFocused(): boolean {
  const el = document.activeElement;
  return el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement;
}

export function FaceToggle(props: FaceToggleProps): JSX.Element {
  function toggle(): void {
    const scrollTop = props.scrollAreaRef?.()?.scrollTop ?? 0;
    props.onToggle(props.face === "source" ? "analysis" : "source", scrollTop);
  }

  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      if (e.key === "T" && !isInputFocused()) {
        e.preventDefault();
        toggle();
      }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  return (
    <div class="face-toggle" role="group" aria-label="Content face">
      <button
        class={`face-toggle-btn${props.face === "source" ? " active" : ""}`}
        onClick={() => props.face !== "source" && toggle()}
        aria-pressed={props.face === "source"}
      >
        Source
      </button>
      <button
        class={`face-toggle-btn${props.face === "analysis" ? " active" : ""}`}
        onClick={() => props.face !== "analysis" && toggle()}
        aria-pressed={props.face === "analysis"}
      >
        Analysis
      </button>
      <span class="phase-badge" aria-label={`Analysis depth: ${props.phaseLabel}`}>
        {props.phaseLabel}
      </span>
    </div>
  );
}
