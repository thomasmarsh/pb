// components/windows/WindowControls.tsx — Close/min/max/restore buttons for window title bar.

import type { JSX } from "solid-js";
import { X, Minus, Maximize2, Minimize2 } from "../../utils/icons.js";

interface WindowControlsProps {
  minimized: boolean;
  maximized: boolean;
  onMinimize: () => void;
  onMaximize: () => void;
  onRestore: () => void;
  onClose: () => void;
}

export function WindowControls(props: WindowControlsProps): JSX.Element {
  return (
    <div class="wm-controls">
      <button
        class="wm-control-btn"
        title="Minimize"
        onClick={props.onMinimize}
      >
        <Minus size={12} />
      </button>
      {props.maximized ? (
        <button
          class="wm-control-btn"
          title="Restore"
          onClick={props.onRestore}
        >
          <Minimize2 size={12} />
        </button>
      ) : (
        <button
          class="wm-control-btn"
          title="Maximize"
          onClick={props.onMaximize}
        >
          <Maximize2 size={12} />
        </button>
      )}
      <button
        class="wm-control-btn wm-control-close"
        title="Close"
        onClick={props.onClose}
      >
        <X size={12} />
      </button>
    </div>
  );
}
