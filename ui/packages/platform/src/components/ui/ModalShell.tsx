import { Show, type JSX, type ParentProps } from "solid-js";

interface ModalShellProps {
  open: boolean;
  onClose: () => void;
  label: string;
  width?: string;
}

export function ModalShell(props: ParentProps<ModalShellProps>): JSX.Element {
  return (
    <Show when={props.open}>
      <div class="gs-backdrop" onClick={props.onClose} />
      <div
        class="gs-panel"
        role="dialog"
        aria-label={props.label}
        aria-modal="true"
        style={props.width ? { "max-width": props.width } : undefined}
      >
        {props.children}
      </div>
    </Show>
  );
}
