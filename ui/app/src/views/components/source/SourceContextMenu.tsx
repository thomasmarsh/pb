import { Show, onMount, onCleanup } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";

export interface ContextMenuTarget {
  linkType: "procedure" | "object" | "var";
  linkName: string;
  x: number;
  y: number;
  sourceLine: number;
  callerCount?: number;
  calleeCount?: number;
  procObject?: string;
}

export interface ContextActions {
  onFindCallers?: (procName: string, procObject: string) => void;
  onFindCallees?: (procName: string, procObject: string) => void;
  onViewCfg?: (procName: string, procObject: string) => void;
  onViewTaint?: (procName: string, procObject: string) => void;
}

interface SourceContextMenuProps {
  target: ContextMenuTarget | null;
  store: Store<AppState, AppAction>;
  objectName: string;
  contextActions?: ContextActions;
  onClose: () => void;
}

export function SourceContextMenu(props: SourceContextMenuProps): JSX.Element {
  onMount(() => {
    function handleKey(e: KeyboardEvent) {
      if (e.key === "Escape") props.onClose();
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  function act(fn: () => void) {
    fn();
    props.onClose();
  }

  return (
    <Show when={props.target}>
      {(t) => {
        const isProc = () => t().linkType === "procedure";
        const name = () => t().linkName;
        const ca = () => props.contextActions;
        const resolvedObject = () => t().procObject ?? props.objectName;

        const left = () => Math.min(t().x, (typeof window !== "undefined" ? window.innerWidth : 800) - 220);
        const top = () => Math.min(t().y, (typeof window !== "undefined" ? window.innerHeight : 600) - 200);

        return (
          <div class="context-menu" style={{ position: "fixed", left: `${left()}px`, top: `${top()}px` }}>
            <button
              onClick={() => act(() => {
                if (t().linkType === "procedure") {
                  props.store.dispatch({ tag: "objects", action: { tag: "proc-select", objectName: resolvedObject(), procName: name() } });
                } else if (t().linkType === "object") {
                  props.store.dispatch({ tag: "objects", action: { tag: "select", name: name() } });
                }
              })}
            >
              Go to definition
            </button>

            <Show when={isProc()}>
              <button
                disabled={!ca()?.onFindCallers}
                onClick={() => { if (ca()?.onFindCallers) act(() => ca()!.onFindCallers!(name(), resolvedObject())); }}
              >
                {"Find callers" + (t().callerCount != null ? ` (${t().callerCount})` : "")}
              </button>

              <button
                disabled={!ca()?.onFindCallees}
                onClick={() => { if (ca()?.onFindCallees) act(() => ca()!.onFindCallees!(name(), resolvedObject())); }}
              >
                {"Find callees" + (t().calleeCount != null ? ` (${t().calleeCount})` : "")}
              </button>

              <button
                disabled={!ca()?.onViewCfg}
                onClick={() => { if (ca()?.onViewCfg) act(() => ca()!.onViewCfg!(name(), resolvedObject())); }}
              >
                View CFG
              </button>

              <button
                onClick={() => act(() => {
                  props.store.dispatch({
                    tag: "objects",
                    action: { tag: "go-slice", object: resolvedObject(), proc: name(), line: t().sourceLine, direction: "backward" },
                  });
                })}
              >
                Generate backward slice
              </button>

              <button
                onClick={() => act(() => {
                  props.store.dispatch({
                    tag: "objects",
                    action: { tag: "highlight-slice", object: resolvedObject(), proc: name(), line: t().sourceLine, direction: "backward" },
                  });
                })}
              >
                Highlight backward slice in source
              </button>

              <button
                disabled={!ca()?.onViewTaint}
                onClick={() => { if (ca()?.onViewTaint) act(() => ca()!.onViewTaint!(name(), resolvedObject())); }}
              >
                View taint paths
              </button>
            </Show>
          </div>
        );
      }}
    </Show>
  );
}
