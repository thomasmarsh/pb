// DwDetailTree.tsx — DataWindow controls/SQL/arguments detail tree.

import { Show, For, createMemo, type JSX } from "solid-js";
import { useExploreStore } from "./ExploreContext.js";
import type { DwExploreDetail } from "../../types/api.js";
import { SqlBlock } from "../../components/CodeBlock.js";
import { TableChip } from "../../components/TableChip.js";
import { chevron } from "../../utils/format.js";

export function DwDetailTree(props: { data: DwExploreDetail }): JSX.Element {
  const store = useExploreStore();
  const snap = store.getState();

  const retrieveSql = createMemo(() => {
    const cols = props.data.retrieve_columns
      .map(c => `${c.table_name}.${c.column_name}`)
      .join(", ");
    const tables = props.data.retrieve_tables.join(", ");
    const where = props.data.retrieve_where
      .map((w, i) => (i === 0 ? "" : `${w.logic ?? "AND"} `) + `${w.exp1} ${w.op} ${w.exp2}`)
      .join("\n        ");
    const lines = [
      cols   ? `SELECT  ${cols}`   : null,
      tables ? `FROM    ${tables}` : null,
      where  ? `WHERE   ${where}`  : null,
    ].filter(Boolean);
    return lines.length > 0 ? lines.join("\n") : null;
  });

  const controlBands = createMemo(() => {
    const bands = new Map<string, typeof props.data.controls>();
    for (const c of props.data.controls) {
      const b = c.band ?? "(none)";
      if (!bands.has(b)) bands.set(b, []);
      bands.get(b)!.push(c);
    }
    return bands;
  });

  function toggleBand(band: string) {
    store.dispatch({ tag: "explore", action: { type: "toggle", nodeId: `dwband:${props.data.name}:${band}` } });
  }

  const isBandExpanded = (band: string) =>
    snap().explore.expandedNodes.has(`dwband:${props.data.name}:${band}`);

  return (
    <div class="dw-detail">
      <Show when={props.data.controls.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Controls</span>
          <span class="dw-section-count">{props.data.controls.length}</span>
        </div>
        <For each={Array.from(controlBands().keys())}>
          {(band) => (
            <div class="dw-band">
              <div class="dw-band-header clickable" onClick={() => toggleBand(band)}>
                <span class="ast-chevron">{chevron(isBandExpanded(band))}</span>
                <span class="dw-band-name">{band}</span>
                <span class="dw-section-count">{controlBands().get(band)!.length}</span>
              </div>
              <Show when={isBandExpanded(band)}>
                <table class="dw-ctrl-table">
                  <thead>
                    <tr>
                      <th>type</th>
                      <th>name</th>
                      <th>expression</th>
                    </tr>
                  </thead>
                  <tbody>
                    <For each={controlBands().get(band)!}>
                      {(ctrl) => (
                        <tr>
                          <td class="ct-type">{ctrl.control_type}</td>
                          <td class="ct-name">{ctrl.control_name}</td>
                          <td class="ct-expr">{ctrl.expression ?? ""}</td>
                        </tr>
                      )}
                    </For>
                  </tbody>
                </table>
              </Show>
            </div>
          )}
        </For>
      </Show>

      <Show when={props.data.retrieve_tables.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Tables</span>
          <span class="dw-section-count">{props.data.retrieve_tables.length}</span>
        </div>
        <div class="dw-tables-chips">
          <For each={props.data.retrieve_tables}>
            {(t) => <TableChip name={t} store={store} size="sm" />}
          </For>
        </div>
      </Show>

      <Show when={retrieveSql()}>
        <div class="dw-section-header">
          <span class="dw-section-title">SQL</span>
        </div>
        <SqlBlock code={retrieveSql()!} style={{ margin: "0 8px 4px", padding: "10px 14px", "font-size": "12px", "max-height": "200px" }} />
      </Show>

      <Show when={props.data.arguments.length > 0}>
        <div class="dw-section-header">
          <span class="dw-section-title">Arguments</span>
        </div>
        <For each={props.data.arguments}>
          {(arg) => (
            <div class="dw-arg">
              <span class="dw-arg-name">{arg.arg_name}</span>
              <span class="dw-arg-type">{arg.arg_type}</span>
            </div>
          )}
        </For>
      </Show>
    </div>
  );
}
