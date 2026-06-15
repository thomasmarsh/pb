// DetailShell.tsx — Generic loading/error/data wrapper for detail panels.

import { Show, type JSX } from "solid-js";

interface DetailShellProps<T> {
  entry: unknown;
  loadingMsg: string;
  children: (data: T) => JSX.Element;
}

export function DetailShell<T>(props: DetailShellProps<T>): JSX.Element {
  const data = (): T | null => {
    const e = props.entry;
    if (!e || typeof e !== "object") return null;
    if ("error" in e) return null;
    return e as T;
  };

  const error = (): string | null => {
    const e = props.entry;
    if (e && typeof e === "object" && "error" in e) return (e as { error: string }).error;
    return null;
  };

  return (
    <Show
      when={props.entry !== undefined}
      fallback={
        <div class="explore-right-body">
          <div class="loading-overlay"><div class="spinner" /> {props.loadingMsg}</div>
        </div>
      }
    >
      <Show
        when={data()}
        fallback={
          <div class="explore-right-body">
            <div class="tree-error">{error()}</div>
          </div>
        }
      >
        {(d) => props.children(d())}
      </Show>
    </Show>
  );
}
