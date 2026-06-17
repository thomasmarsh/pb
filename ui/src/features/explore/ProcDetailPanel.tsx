// ProcDetailPanel.tsx — Procedure detail with Source/AST/SQL tabs.

import { Show, For, createMemo, createSignal, createResource } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import { highlightAsync } from "../../lib/highlight.js";
import type { ExploreProcDetail, SqlStatementRow } from "../../types/api.js";
import { AstNode } from "./AstNode.js";
import { DetailShell } from "../../components/DetailShell.js";
import { SqlStatementCard } from "../../components/SqlStatementCard.js";
import { InlineDiagram } from "../../components/InlineDiagram.js";
import { procBadge } from "../../utils/format.js";

export function ProcDetailPanel(props: { nodeId: string }) {
  const store = useExploreStore();
  const snap = store.getState();
  const entry = () => snap().explore.procCache[props.nodeId];
  const procName = () => props.nodeId.split(":")[2] ?? "";
  const objectName = () => props.nodeId.split(":")[1] ?? "";

  const activeTab = () => snap().explore.activeTab;

  return (
    <DetailShell<ExploreProcDetail> entry={entry()} loadingMsg="Loading...">
      {(d) => {
        const lines = createMemo(() => d.source_rendered ? d.source_rendered.split("\n") : []);

        const [highlighted] = createResource(
          () => ({ src: d.source_rendered, tab: activeTab() }),
          ({ src, tab }) => {
            if (!src || tab !== "source") return Promise.resolve("");
            return highlightAsync(src);
          },
          { initialValue: "" },
        );

        const highlightIdx = createMemo(() => {
          const hl = snap().explore.highlightedLine;
          if (hl == null) return null;
          const idx = hl - (d.start_line ?? 1);
          if (idx < 0 || idx >= lines().length) return null;
          return idx;
        });

        const [sourceViewerEl, setSourceViewerEl] = createSignal<HTMLDivElement | null>(null);

        createMemo(() => {
          const idx = highlightIdx();
          const el = sourceViewerEl();
          if (idx == null || !el) return;
          el.scrollTop = Math.max(0, idx * 20.8 - 80);
        });

        return (
          <>
            <div class="explore-right-header">
              <span class={`badge ${procBadge(d.proc_type)}`}>{d.proc_type}</span>
              <span class="proc-name">{procName()}</span>
              <Show when={d.params}>
                <span class="proc-params">({d.params})</span>
              </Show>
              <Show when={d.return_type}>
                <span class="proc-params">{"→"} {d.return_type}</span>
              </Show>
              <Show when={d.cyclomatic != null}>
                <span class="badge badge-cc">CC: {d.cyclomatic}</span>
              </Show>
              <div class="explore-tabs" style={{ "margin-left": "auto" }}>
                <button
                  class={`explore-tab-btn${activeTab() === "source" ? " active" : ""}`}
                  onClick={() => store.dispatch({ tag: "explore", action: { type: "tab", tab: "source" } })}
                >Source</button>
                <button
                  class={`explore-tab-btn${activeTab() === "ast" ? " active" : ""}`}
                  onClick={() => store.dispatch({ tag: "explore", action: { type: "tab", tab: "ast" } })}
                >AST</button>
                <Show when={d.sql_statements.length > 0}>
                  <button
                    class={`explore-tab-btn${activeTab() === "sql" ? " active" : ""}`}
                    onClick={() => store.dispatch({ tag: "explore", action: { type: "tab", tab: "sql" } })}
                  >SQL ({d.sql_statements.length})</button>
                </Show>
                <Show when={d.sql_statements.length > 0}>
                  <button
                    class={`explore-tab-btn${activeTab() === "diagram" ? " active" : ""}`}
                    onClick={() => store.dispatch({ tag: "explore", action: { type: "tab", tab: "diagram" } })}
                  >Diagram</button>
                </Show>
              </div>
            </div>
            <div class="explore-right-body">
              <Show when={activeTab() === "source"}>
                <div class="source-viewer" ref={setSourceViewerEl}>
                  <div class="source-gutter">
                    <For each={lines()}>
                      {(_, i) => (
                        <div
                          class="source-gutter-line"
                          style={i() === highlightIdx() ? {
                            color: "#fb923c", "font-weight": "600",
                            background: "rgba(251, 146, 60, 0.12)",
                          } : undefined}
                        >
                          {(d.start_line ?? 1) + i()}
                        </div>
                      )}
                    </For>
                  </div>
                  <div class="source-code-area">
                    <Show when={highlightIdx() != null}>
                      <div class="ast-line-highlight" style={{
                        top: `${highlightIdx()! * 20.8}px`,
                        height: "20.8px",
                      }} />
                    </Show>
                    <Show
                      when={!highlighted.loading}
                      fallback={<div class="loading-overlay"><div class="spinner" /> Highlighting...</div>}
                    >
                      <pre innerHTML={highlighted()} />
                    </Show>
                  </div>
                </div>
              </Show>
              <Show when={activeTab() === "ast"}>
                <AstNode node={d.ast} nodeId={props.nodeId + ".ast"} depth={0} />
              </Show>
              <Show when={activeTab() === "sql"}>
                <div class="sql-tab-body">
                  <For each={d.sql_statements}>
                    {(stmt: SqlStatementRow) => (
                      <SqlStatementCard stmt={stmt} store={store} />
                    )}
                  </For>
                </div>
              </Show>
              <Show when={activeTab() === "diagram"}>
                <div class="sql-tab-body">
                  <InlineDiagram
                    kind="sql-lineage"
                    params={{ focal: objectName() }}
                    store={store}
                    compact
                  />
                </div>
              </Show>
            </div>
          </>
        );
      }}
    </DetailShell>
  );
}
