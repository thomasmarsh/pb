// CodeBlock.tsx — Narrowed source view (single function/subroutine snippet).
//
// Delegates to the shared SourceView so the narrowed view renders the exact
// same cross-linked, tooltip-enabled code as the whole-file SourceViewer. Pass
// linking context (objectName / knownObjects / knownProcs / ...) when available
// so identifiers link and show tooltips, just like the whole-file view.

import type { JSX } from "solid-js";
import { highlightSql } from "@pb/platform";
import type { KnownProcInfo, ProcedureInfo, LocalSymbolInfo } from "@pb/platform";
import { SourceView } from "../source/SourceView.js";

export function SqlBlock(props: { code: string; style?: JSX.CSSProperties }) {
  return <pre class="code-viewer sql-code" style={props.style} innerHTML={highlightSql(props.code)} />;
}

interface CodeBlockProps {
  code: string;
  baseLine?: number;
  highlightLine?: number;
  onLineClick?: (line: number) => void;
  // Linking context — supplied so the narrowed view gains the same cross-linked
  // identifiers and tooltips as the whole-file view.
  objectName?: string;
  knownObjects?: { name: string; kind: string }[];
  knownProcs?: KnownProcInfo[];
  procedures?: ProcedureInfo[];
  localSymbols?: LocalSymbolInfo[];
}

export function CodeBlock(props: CodeBlockProps) {
  const base = () => props.baseLine ?? 1;
  const highlightLines = () => (props.highlightLine != null ? new Set([props.highlightLine]) : null);
  const lines = () => props.code.split("\n");

  return (
    <SourceView
      lines={lines()}
      baseLine={base()}
      highlightLines={highlightLines()}
      onLineClick={props.onLineClick}
      objectName={props.objectName}
      knownObjects={props.knownObjects}
      knownProcs={props.knownProcs}
      procedures={props.procedures}
      localSymbols={props.localSymbols}
    />
  );
}
