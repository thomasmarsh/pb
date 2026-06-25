// components/windows/WindowFrame.tsx — Draggable/resizable window chrome.

import { createSignal, onCleanup, type JSX, type ParentProps } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { ManagedWindow } from "@pb/windowing";
import { WindowControls } from "./WindowControls.js";

const MIN_WIDTH = 200;
const MIN_HEIGHT = 150;

interface WindowFrameProps {
  win: ManagedWindow;
  isActive: boolean;
  store: Store<AppState, AppAction>;
}

export function WindowFrame(props: ParentProps<WindowFrameProps>): JSX.Element {
  const [dragging, setDragging] = createSignal(false);
  const [resizing, setResizing] = createSignal(false);
  let dragStartX = 0;
  let dragStartY = 0;
  let winStartX = 0;
  let winStartY = 0;

  function dispatch(action: { tag: string; id: string; [k: string]: unknown }): void {
    props.store.dispatch({ tag: "windowManager", action: action as never });
  }

  // Drag handlers
  function onDragStart(e: PointerEvent): void {
    e.preventDefault();
    setDragging(true);
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    winStartX = props.win.x;
    winStartY = props.win.y;
    document.addEventListener("pointermove", onDragMove);
    document.addEventListener("pointerup", onDragEnd);
  }

  function onDragMove(e: PointerEvent): void {
    const dx = e.clientX - dragStartX;
    const dy = e.clientY - dragStartY;
    dispatch({ tag: "move-window", id: props.win.id, x: winStartX + dx, y: winStartY + dy });
  }

  function onDragEnd(): void {
    setDragging(false);
    document.removeEventListener("pointermove", onDragMove);
    document.removeEventListener("pointerup", onDragEnd);
  }

  onCleanup(() => {
    document.removeEventListener("pointermove", onDragMove);
    document.removeEventListener("pointerup", onDragEnd);
  });

  // Resize handler for bottom-right corner
  let resizeStartX = 0;
  let resizeStartY = 0;
  let resizeStartW = 0;
  let resizeStartH = 0;

  function onResizeStart(e: PointerEvent): void {
    e.preventDefault();
    e.stopPropagation();
    setResizing(true);
    resizeStartX = e.clientX;
    resizeStartY = e.clientY;
    resizeStartW = props.win.width;
    resizeStartH = props.win.height;
    document.addEventListener("pointermove", onResizeMove);
    document.addEventListener("pointerup", onResizeEnd);
  }

  function onResizeMove(e: PointerEvent): void {
    const dx = e.clientX - resizeStartX;
    const dy = e.clientY - resizeStartY;
    dispatch({
      tag: "resize-window",
      id: props.win.id,
      width: Math.max(MIN_WIDTH, resizeStartW + dx),
      height: Math.max(MIN_HEIGHT, resizeStartH + dy),
    });
  }

  function onResizeEnd(): void {
    setResizing(false);
    document.removeEventListener("pointermove", onResizeMove);
    document.removeEventListener("pointerup", onResizeEnd);
  }

  onCleanup(() => {
    document.removeEventListener("pointermove", onResizeMove);
    document.removeEventListener("pointerup", onResizeEnd);
  });

  function handleFocus(): void {
    if (!props.isActive) {
      dispatch({ tag: "focus-window", id: props.win.id });
    }
  }

  const windowStyle = () => {
    if (props.win.maximized) {
      return {
        left: "0px",
        top: "0px",
        width: "100%",
        height: "100%",
        "z-index": props.win.zIndex,
      };
    }
    return {
      left: `${props.win.x}px`,
      top: `${props.win.y}px`,
      width: `${props.win.width}px`,
      height: `${props.win.height}px`,
      "z-index": props.win.zIndex,
    };
  };

  return (
    <div
      class={`wm-window${props.isActive ? " active" : ""}${props.win.minimized ? " minimized" : ""}${props.win.maximized ? " maximized" : ""}`}
      style={windowStyle()}
      onPointerDown={handleFocus}
    >
      <div
        class={`wm-titlebar${dragging() ? " dragging" : ""}`}
        onPointerDown={onDragStart}
      >
        <span class="wm-title">{props.win.title}</span>
        <WindowControls
          minimized={props.win.minimized}
          maximized={props.win.maximized}
          onMinimize={() => dispatch({ tag: "minimize-window", id: props.win.id })}
          onMaximize={() => dispatch({ tag: "maximize-window", id: props.win.id })}
          onRestore={() => dispatch({ tag: "restore-window", id: props.win.id })}
          onClose={() => dispatch({ tag: "close-window", id: props.win.id })}
        />
      </div>
      <div class="wm-content">
        {props.children}
      </div>
      {!props.win.maximized && (
        <div
          class={`wm-resize-handle${resizing() ? " active" : ""}`}
          onPointerDown={onResizeStart}
        />
      )}
    </div>
  );
}
