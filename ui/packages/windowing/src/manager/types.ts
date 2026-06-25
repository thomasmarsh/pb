// features/window-manager/types.ts — Window manager state and actions.
// Pure UI concern: position, size, z-order for managed windows.

export interface ManagedWindow {
  id: string;
  title: string;
  x: number;
  y: number;
  width: number;
  height: number;
  zIndex: number;
  minimized: boolean;
  maximized: boolean;
  runtimeWindowName: string;
}

export interface WindowManagerState {
  windows: ManagedWindow[];
  activeWindowId: string | null;
  nextZIndex: number;
}

export type WindowManagerAction =
  | { tag: "open-window"; id: string; title: string; runtimeWindowName: string }
  | { tag: "close-window"; id: string }
  | { tag: "focus-window"; id: string }
  | { tag: "move-window"; id: string; x: number; y: number }
  | { tag: "resize-window"; id: string; width: number; height: number }
  | { tag: "minimize-window"; id: string }
  | { tag: "maximize-window"; id: string }
  | { tag: "restore-window"; id: string };
