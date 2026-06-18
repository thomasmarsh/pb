import type { JSX } from "solid-js";

interface BackButtonProps {
  label: string;
  onClick: () => void;
}

export function BackButton(props: BackButtonProps): JSX.Element {
  return (
    <button class="back-btn" onClick={props.onClick}>
      {"←"} Back to {props.label}
    </button>
  );
}
