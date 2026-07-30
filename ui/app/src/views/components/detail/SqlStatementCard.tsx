// SqlStatementCard.tsx — Card rendering a single SQL statement with operation badge and table chips.

import { Show, For } from "solid-js";
import type { JSX } from "solid-js";
import type { Store } from "@pb/core";
import type { AppState } from "../../../state.js";
import type { AppAction } from "../../../actions.js";
import type { SqlStatementRow } from "@pb/platform";
import { SqlBlock, lintLabel, lintSeverity, lintDescription } from "@pb/platform";
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
        <For each={props.stmt.lint_warnings}>
          {(code) => (
            <span
              class={`badge badge-${lintSeverity(code) === "error" ? "error" : "warn"}`}
              title={lintDescription(code)}
            >
              {lintLabel(code)}
            </span>
          )}
        </For>
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
