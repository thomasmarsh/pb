// SourceCard.tsx — Source file viewer with error/empty states.

import { Show } from "solid-js";
import type { Store } from "../../../core/store.js";
import type { AppState } from "../../../features/app/state.js";
import type { AppAction } from "../../../features/app/actions.js";
import type { ObjectSourceResponse, ProcedureInfo, KnownProcInfo, LocalSymbolInfo } from "../../../types/api.js";
import { SourceViewer } from "../SourceViewer.js";

export function SourceCard(props: {
  store: Store<AppState, AppAction>;
  file: string;
  objectName: string;
  sourceDetail: ObjectSourceResponse | { error: string } | null;
}) {
  const hasLines = () => {
    const s = props.sourceDetail;
    return s && "lines" in s && s.lines && s.lines.length > 0;
  };

  return (
    <div class="card">
      <div class="source-file-header">
        <div class="card-header"><h3>Source</h3></div>
        <div class="source-file-path">{props.file}</div>
      </div>
      <Show
        when={hasLines()}
        fallback={
          <Show when={props.sourceDetail}>
            {"error" in (props.sourceDetail as object)
              ? <p style={{ color: "var(--red)", "font-size": "12px" }}>{(props.sourceDetail as { error: string }).error}</p>
              : <p style={{ color: "var(--text-muted)", "font-size": "12px" }}>Source not available — re-index to restore it.</p>
            }
          </Show>
        }
      >
        <SourceViewer
          store={props.store}
          lines={(props.sourceDetail as { lines: string[] }).lines}
          procedures={(props.sourceDetail as { procedures: ProcedureInfo[] }).procedures}
          knownObjects={(props.sourceDetail as { knownObjects: { name: string; kind: string }[] }).knownObjects}
          knownProcs={(props.sourceDetail as { knownProcs: KnownProcInfo[] }).knownProcs}
          localSymbols={(props.sourceDetail as { localSymbols?: LocalSymbolInfo[] }).localSymbols}
          objectName={props.objectName}
        />
      </Show>
    </div>
  );
}
