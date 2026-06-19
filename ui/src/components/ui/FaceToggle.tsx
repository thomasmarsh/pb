// components/FaceToggle.tsx — Source/Analysis face toggle.

import type { JSX } from "solid-js";

export type Face = "source" | "analysis";

interface FaceToggleProps {
  face: Face;
  onToggle: (newFace: Face, scrollTop: number) => void;
  scrollAreaRef?: () => HTMLElement | undefined;
}

export function FaceToggle(props: FaceToggleProps): JSX.Element {
  function toggle(): void {
    const scrollTop = props.scrollAreaRef?.()?.scrollTop ?? 0;
    props.onToggle(props.face === "source" ? "analysis" : "source", scrollTop);
  }

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
    </div>
  );
}
