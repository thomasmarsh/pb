// CodeBlock.tsx — Syntax-highlighted code blocks (PowerScript + SQL).

import { For } from "solid-js";
import type { JSX } from "solid-js";
import { highlightPowerScript, highlightSql } from "../../utils/highlight.js";

export function SqlBlock(props: { code: string; style?: JSX.CSSProperties }) {
  return <pre class="code-viewer sql-code" style={props.style} innerHTML={highlightSql(props.code)} />;
}

interface CodeBlockProps {
  code: string;
  baseLine?: number;
  highlightLine?: number;
  onLineClick?: (line: number) => void;
}

export function CodeBlock(props: CodeBlockProps) {
  const highlightedLines = () => highlightPowerScript(props.code).split("\n");
  const base = () => props.baseLine ?? 1;
  const isErrorLine = (i: number) => base() + i === props.highlightLine;

  return (
    <div class="source-viewer">
      <div class="source-gutter">
        <For each={highlightedLines()}>
          {(_line, i) => (
            <div
              class="source-gutter-line"
              classList={{
                "source-gutter-line--error":     isErrorLine(i()),
                "source-gutter-line--clickable":  props.onLineClick != null,
              }}
              onClick={() => props.onLineClick?.(base() + i())}
            >
              {String(base() + i())}
            </div>
          )}
        </For>
      </div>
      <div class="source-code-area">
        <pre>
          <For each={highlightedLines()}>
            {(line, i) => (
              <>
                <span
                  class="source-code-line"
                  classList={{ "source-code-line--error": isErrorLine(i()) }}
                  innerHTML={line}
                />
                {i() < highlightedLines().length - 1 ? "\n" : ""}
              </>
            )}
          </For>
        </pre>
      </div>
    </div>
  );
}
