// CodeBlock.tsx — Syntax-highlighted code blocks (PowerScript + SQL).

import { For } from "solid-js";
import type { JSX } from "solid-js";
import { highlightPowerScript, highlightSql } from "../lib/highlight.js";

export function SqlBlock(props: { code: string; style?: JSX.CSSProperties }) {
  return <pre class="code-viewer sql-code" style={props.style} innerHTML={highlightSql(props.code)} />;
}

interface CodeBlockProps {
  code: string;
  baseLine?: number;
}

export function CodeBlock(props: CodeBlockProps) {
  const highlighted = () => highlightPowerScript(props.code);
  const lines = () => props.code.split("\n");
  const base = () => props.baseLine ?? 1;

  return (
    <div class="source-viewer">
      <div class="source-gutter">
        <For each={lines()}>
          {(_line, i) => (
            <div class="source-gutter-line">{String(base() + i())}</div>
          )}
        </For>
      </div>
      <div class="source-code-area">
        <pre innerHTML={highlighted()} />
      </div>
    </div>
  );
}
