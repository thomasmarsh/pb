import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import { FaceToggle, type Face } from "../ui/FaceToggle.js";

interface DetailHeaderProps {
  name: string;
  badgeClass: string;
  badgeLabel: string;
  face: Face;
  store: Store<AppState, AppAction>;
  onToggle: (face: Face, scrollTop: number) => void;
  scrollAreaRef?: () => HTMLElement | undefined;
  subtitle?: JSX.Element;
}

export function DetailHeader(props: DetailHeaderProps): JSX.Element {
  return (
    <div class="detail-header">
      <div>
        <h2 style={{ "margin": "0", "font-size": "20px" }}>
          {props.name} <span class={`badge ${props.badgeClass}`}>{props.badgeLabel}</span>
        </h2>
        {props.subtitle}
      </div>
      <FaceToggle
        face={props.face}
        onToggle={props.onToggle}
        scrollAreaRef={props.scrollAreaRef}
      />
    </div>
  );
}
