// source-viewer.ts — Source code viewer with cross-linked identifiers.

import { el } from "../dom.js";
import { highlightPowerScript, PB_KEYWORDS } from "../highlight.js";
import type { ProcedureInfo } from "../types/api.js";
import type { Dispatch } from "../core.js";

const PROC_COLORS: Record<string, string> = {
  function: "proc-function",
  subroutine: "proc-subroutine",
  event: "proc-event",
  on: "proc-on",
};

const PROC_BADGE_COLORS: Record<string, string> = {
  function: "#a78bfa",
  subroutine: "#fb923c",
  event: "#facc15",
  on: "#4ade80",
};

interface SourceViewerSrc {
  lines: string[];
  procedures: ProcedureInfo[];
  knownObjects: { name: string; kind: string }[];
  knownProcs: { name: string; object: string; proc_type: string }[];
}

type KnownProc = { name: string; object: string; proc_type: string; modifiers?: string | null; params?: string | null; return_type?: string | null; start_line?: number | null; end_line?: number | null; cyclomatic?: number | null };

function linkIdentifiers(
  html: string,
  objectMap: Map<string, { name: string; kind: string }>,
  procMap: Map<string, KnownProc>,
  selfName: string,
): string {
  return html.replace(/\b([A-Za-z_][\w$#%-]*)\b/g, (match, word) => {
    const lower = word.toLowerCase();
    if (match.startsWith("<") || match.startsWith("/")) return match;
    if (lower === selfName.toLowerCase()) return match;
    if (PB_KEYWORDS.has(lower)) return match;
    if (procMap.has(lower)) return `<span data-link-type="procedure" data-link-name="${word}">${match}</span>`;
    if (objectMap.has(lower)) return `<span data-link-type="object" data-link-name="${word}">${match}</span>`;
    return match;
  });
}

export function createSourceViewer(
  src: SourceViewerSrc,
  objectName: string,
  dispatch: Dispatch,
): HTMLElement {
  const viewer = el("div", { className: "source-viewer" });
  const gutter = el("div", { className: "source-gutter" });
  const codeArea = el("div", { className: "source-code-area" });

  const procFirstLine = new Map<number, ProcedureInfo>();
  for (const p of src.procedures) {
    if (p.start_line != null) procFirstLine.set(p.start_line, p);
  }

  // Build lookup maps
  const objectMap = new Map<string, { name: string; kind: string }>();
  for (const o of src.knownObjects) objectMap.set(o.name.toLowerCase(), o);
  type KnownProc = { name: string; object: string; proc_type: string; modifiers?: string | null; params?: string | null; return_type?: string | null; start_line?: number | null; end_line?: number | null; cyclomatic?: number | null };
  const procMap = new Map<string, KnownProc>();
  for (const p of src.knownProcs) procMap.set(p.name.toLowerCase(), p);
  for (const p of src.procedures) {
    procMap.set(p.name.toLowerCase(), {
      name: p.name,
      object: objectName,
      proc_type: p.proc_type,
      modifiers: p.modifiers,
      params: p.params,
      return_type: p.return_type,
      start_line: p.start_line,
      end_line: p.end_line,
      cyclomatic: p.cyclomatic,
    });
  }

  const code = src.lines.join("\n");
  const highlighted = highlightPowerScript(code);
  const highlightedLines = highlighted.split("\n");

  // Tooltip
  const tooltip = el("div", { className: "source-proc-tooltip" });
  document.body.appendChild(tooltip);

  function showTooltip(target: HTMLElement, html: string): void {
    tooltip.innerHTML = html;
    tooltip.classList.add("visible");
    const rect = target.getBoundingClientRect();
    let left = rect.right + 8;
    let top = rect.top;
    if (left + 400 > window.innerWidth) left = rect.left - 410;
    if (top + 120 > window.innerHeight) top = window.innerHeight - 130;
    tooltip.style.left = left + "px";
    tooltip.style.top = top + "px";
  }

  function hideTooltip(): void {
    tooltip.classList.remove("visible");
  }

  // Render lines
  src.lines.forEach((_line, i) => {
    const lineNum = i + 1;

    const gl = el("div", { className: "source-gutter-line" }, String(lineNum));
    const procInfo = procFirstLine.get(lineNum);
    if (procInfo) {
      gl.style.color = PROC_BADGE_COLORS[procInfo.proc_type ?? ""] ?? "var(--text-muted)";
      gl.style.fontWeight = "600";
    }
    gutter.appendChild(gl);

    let html = highlightedLines[i] ?? "";
    html = linkIdentifiers(html, objectMap, procMap, objectName);

    const lineEl = el("span", { html: html + "\n" });
    if (procInfo) lineEl.className = "source-line-highlight";

    lineEl.querySelectorAll("[data-link-type]").forEach(span => {
      const linkType = (span as HTMLElement).dataset.linkType;
      const linkName = (span as HTMLElement).dataset.linkName;
      if (!linkType || !linkName) return;

      span.setAttribute("style", "cursor:pointer;text-decoration:underline;text-decoration-style:dotted;text-underline-offset:2px");

      if (linkType === "object") {
        const obj = objectMap.get(linkName.toLowerCase());
        span.setAttribute("style", span.getAttribute("style")! +
          `;color:${obj && obj.kind === "datawindow" ? "#56A85D" : "#5B8DD9"}`);
        span.addEventListener("mouseenter", () => {
          const kind = obj ? obj.kind : "object";
          showTooltip(span as HTMLElement, `<div class="tt-name" style="color:#5B8DD9">${linkName}</div><div class="tt-meta">${kind}</div>`);
        });
        span.addEventListener("mouseleave", hideTooltip);
        span.addEventListener("click", () => { hideTooltip(); dispatch({ type: "OBJECT_SELECTED", name: linkName }); });
      } else if (linkType === "procedure") {
        const proc = procMap.get(linkName.toLowerCase());
        const color = proc ? (PROC_BADGE_COLORS[proc.proc_type ?? ""] ?? "#a78bfa") : "#a78bfa";
        span.setAttribute("style", span.getAttribute("style") + `;color:${color}`);
        span.addEventListener("mouseenter", () => {
          if (!proc) { showTooltip(span as HTMLElement, `<div class="tt-name" style="color:${color}">${linkName}</div>`); return; }
          const ret = proc.return_type ? ` &rarr; ${proc.return_type}` : "";
          const cc = proc.cyclomatic != null ? `<div class="tt-cc"><span class="badge badge-cc">CC: ${proc.cyclomatic}</span></div>` : "";
          showTooltip(span as HTMLElement, `<div class="tt-name" style="color:${color}">${proc.name}</div>` +
            `<div class="tt-meta">${proc.proc_type}${ret}</div>` +
            (proc.params ? `<div class="tt-meta">(${proc.params})</div>` : "") +
            `<div class="tt-meta">${proc.object}</div>${cc}`);
        });
        span.addEventListener("mouseleave", hideTooltip);
        span.addEventListener("click", () => {
          hideTooltip();
          if (proc && proc.start_line != null) {
            dispatch({ type: "PROCEDURE_SELECTED", objectName: proc.object, procName: proc.name });
          } else {
            dispatch({ type: "OBJECT_SELECTED", name: proc?.object ?? linkName });
          }
        });
      }
    });

    codeArea.appendChild(lineEl);
  });

  // Procedure overlay bars
  for (const p of src.procedures) {
    if (p.start_line == null || p.end_line == null) continue;
    const barTop = (p.start_line - 1) * 20.8;
    const barHeight = (p.end_line - p.start_line + 1) * 20.8;
    const bar = el("div", {
      className: "source-proc-bar " + (PROC_COLORS[p.proc_type ?? ""] ?? ""),
      style: `top:${barTop}px;height:${barHeight}px`,
    });

    bar.addEventListener("mouseenter", () => {
      const cc = p.cyclomatic != null ? `CC: ${p.cyclomatic}` : "";
      const ret = p.return_type ? ` &rarr; ${p.return_type}` : "";
      showTooltip(bar,
        `<div class="tt-name" style="color:${PROC_BADGE_COLORS[p.proc_type ?? ""] ?? '#fff'}">${p.name}</div>` +
        `<div class="tt-meta">${p.proc_type} ${p.modifiers ?? ""}${ret}</div>` +
        (p.params ? `<div class="tt-meta">(${p.params})</div>` : "") +
        `<div class="tt-meta">Lines ${p.start_line}&ndash;${p.end_line}</div>` +
        (cc ? `<div class="tt-cc"><span class="badge badge-cc">${cc}</span></div>` : ""));
    });
    bar.addEventListener("mouseleave", hideTooltip);
    bar.addEventListener("click", () => {
      hideTooltip();
      dispatch({ type: "PROCEDURE_SELECTED", objectName, procName: p.name });
    });

    codeArea.appendChild(bar);
  }

  codeArea.style.position = "relative";
  viewer.appendChild(gutter);
  viewer.appendChild(codeArea);

  const observer = new MutationObserver(() => {
    if (!document.body.contains(viewer)) { tooltip.remove(); observer.disconnect(); }
  });
  observer.observe(document.body, { childList: true, subtree: true });

  return viewer;
}
