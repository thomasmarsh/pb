import type { JSX } from "solid-js";
import { ArrowLeft } from "@pb/platform";

interface BackButtonProps {
  label: string;
  onClick: () => void;
}

export function BackButton(props: BackButtonProps): JSX.Element {
  return (
    <button class="back-btn" onClick={props.onClick}>
      <ArrowLeft size={14} /> Back to {props.label}
    </button>
  );
}
