// features/window-manager/initial.ts — Initial window manager state.

import type { WindowManagerState } from "./types.js";

export const initialWindowManagerState: WindowManagerState = {
  windows: [],
  activeWindowId: null,
  nextZIndex: 1,
};
