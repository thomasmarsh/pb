// CodeBlock.tsx — Simple syntax-highlighted code block with line numbers.

import { For } from "solid-js";
import { highlightPowerScript } from "../highlight.js";

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
