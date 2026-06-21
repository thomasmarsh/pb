// features/window-manager/reducer.ts — Pure window manager reducer.
// No env dependencies — all state mutations are synchronous.

import type { WindowManagerState, WindowManagerAction, ManagedWindow } from "./types.js";
import type { Reducer } from "../../core/reducer.js";
import { Effect } from "../../core/effect.js";

const DEFAULT_WIDTH = 800;
const DEFAULT_HEIGHT = 600;
const MIN_WIDTH = 200;
const MIN_HEIGHT = 150;
const DESKTOP_PADDING = 40;

function centerPosition(state: WindowManagerState): { x: number; y: number } {
  const offset = (state.windows.length % 5) * 30;
  return { x: DESKTOP_PADDING + offset, y: DESKTOP_PADDING + offset };
}

function findWindow(state: WindowManagerState, id: string): ManagedWindow | undefined {
  return state.windows.find(w => w.id === id);
}

function updateWindow(
  state: WindowManagerState,
  id: string,
  patch: Partial<ManagedWindow>,
): void {
  const idx = state.windows.findIndex(w => w.id === id);
  if (idx >= 0) {
    state.windows[idx] = { ...state.windows[idx]!, ...patch };
  }
}

function reduce(
  draft: WindowManagerState,
  action: WindowManagerAction,
): Effect<WindowManagerAction> | null {
  switch (action.tag) {
    case "open-window": {
      const pos = centerPosition(draft);
      draft.windows.push({
        id: action.id,
        title: action.title,
        x: pos.x,
        y: pos.y,
        width: DEFAULT_WIDTH,
        height: DEFAULT_HEIGHT,
        zIndex: draft.nextZIndex,
        minimized: false,
        maximized: false,
        runtimeWindowName: action.runtimeWindowName,
      });
      draft.activeWindowId = action.id;
      draft.nextZIndex++;
      return null;
    }
    case "close-window": {
      draft.windows = draft.windows.filter(w => w.id !== action.id);
      if (draft.activeWindowId === action.id) {
        const top = draft.windows.length > 0
          ? draft.windows.reduce((a, b) => a.zIndex > b.zIndex ? a : b)
          : null;
        draft.activeWindowId = top?.id ?? null;
      }
      return null;
    }
    case "focus-window": {
      const w = findWindow(draft, action.id);
      if (w) {
        w.zIndex = draft.nextZIndex;
        draft.nextZIndex++;
        draft.activeWindowId = action.id;
      }
      return null;
    }
    case "move-window": {
      updateWindow(draft, action.id, { x: action.x, y: action.y });
      return null;
    }
    case "resize-window": {
      updateWindow(draft, action.id, {
        width: Math.max(MIN_WIDTH, action.width),
        height: Math.max(MIN_HEIGHT, action.height),
      });
      return null;
    }
    case "minimize-window": {
      updateWindow(draft, action.id, { minimized: true });
      if (draft.activeWindowId === action.id) {
        const visible = draft.windows.filter(w => !w.minimized && w.id !== action.id);
        const top = visible.length > 0
          ? visible.reduce((a, b) => a.zIndex > b.zIndex ? a : b)
          : null;
        draft.activeWindowId = top?.id ?? null;
      }
      return null;
    }
    case "maximize-window": {
      updateWindow(draft, action.id, { maximized: true, minimized: false });
      draft.activeWindowId = action.id;
      return null;
    }
    case "restore-window": {
      updateWindow(draft, action.id, { maximized: false, minimized: false });
      draft.activeWindowId = action.id;
      return null;
    }
  }
}

export const windowManagerReducer: Reducer<WindowManagerState, WindowManagerAction, void> = reduce;
