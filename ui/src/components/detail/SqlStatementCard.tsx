// SqlStatementCard.tsx — Card rendering a single SQL statement with operation badge and table chips.

import { Show, For } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "../../core/store.js";
import type { AppState } from "../../features/app/state.js";
import type { AppAction } from "../../features/app/actions.js";
import type { SqlStatementRow } from "../../types/api.js";
import { SqlBlock } from "./CodeBlock.js";
import { TableChip } from "./TableChip.js";

interface SqlStatementCardProps {
  stmt:  SqlStatementRow;
  store: Store<AppState, AppAction>;
}

function opBadgeClass(op: string): string {
  switch (op.toUpperCase()) {
    case "SELECT": return "badge badge-ps";
    case "INSERT": return "badge badge-dw";
    case "UPDATE": return "badge badge-sub";
    case "DELETE": return "badge badge-cc";
    default:       return "badge badge-proj";
  }
}

export function SqlStatementCard(props: SqlStatementCardProps): JSX.Element {
  return (
    <div class="sql-stmt-block">
      <div class="sql-stmt-header">
        <span class={opBadgeClass(props.stmt.operation)}>{props.stmt.operation}</span>
        <Show when={!props.stmt.parse_ok}>
          <span class="badge badge-warn">&#x26A0; unparsed</span>
        </Show>
      </div>
      <SqlBlock code={props.stmt.formatted_sql} />
      <Show when={props.stmt.tables && props.stmt.tables.length > 0}>
        <div class="sql-tables-row">
          <span class="sql-tables-label">Tables:</span>
          <For each={props.stmt.tables!}>
            {(t) => <TableChip name={t} store={props.store} size="sm" />}
          </For>
        </div>
      </Show>
    </div>
  );
}
