// procedures.ts — Procedure detail view renderer.

import { el } from "../dom.js";
import type { AppState } from "../types/state.js";
import type { Dispatch } from "../core.js";

function procBadge(t: string): string {
  return { function: "func", subroutine: "sub", event: "event", on: "on" }[t] ?? "func";
}

export function renderProcedureDetail(state: AppState, root: HTMLElement, dispatch: Dispatch): void {
  const proc = state.procedureDetail;
  if (!proc) { root.appendChild(el("div", { className: "loading-overlay" }, el("div", { className: "spinner" }), " Loading...")); return; }
  if ("error" in proc) { root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--red)" }, "Error: " + proc.error))); return; }

  root.appendChild(el("button", { className: "back-btn",
    onClick: () => dispatch({ type: "OBJECT_SELECTED", name: proc.object }) }, "\u2190 Back to " + proc.object));

  const bc = procBadge(proc.proc_type);
  root.appendChild(el("h2", { style: "margin-bottom:4px;font-size:18px" },
    proc.object + ".", el("span", { style: "color:var(--accent)" }, proc.name),
    " ", el("span", { className: "badge badge-" + bc }, proc.proc_type)));

  const meta = el("div", { style: "font-size:12px;color:var(--text-muted);margin-bottom:16px" });
  if (proc.modifiers) meta.appendChild(el("span", null, proc.modifiers + " "));
  if (proc.params) meta.appendChild(el("span", null, "(" + proc.params + ") "));
  if (proc.return_type) meta.appendChild(el("span", null, "returns " + proc.return_type + " "));
  if (proc.cyclomatic != null) meta.appendChild(el("span", { className: "badge badge-cc", style: "margin-left:8px" }, "CC: " + proc.cyclomatic));
  root.appendChild(meta);

  const tabs: { id: string; label: string }[] = [];
  if (proc.source_original) tabs.push({ id: "original", label: "Original Source" });
  if (proc.source_rendered) tabs.push({ id: "rendered", label: "Rendered" });
  if (!tabs.length) { root.appendChild(el("div", { className: "card" }, el("p", { style: "color:var(--text-muted)" }, "No source available"))); return; }

  const activeTab = proc.activeTab ?? tabs[0]!.id;
  const tabBar = el("div", { className: "tab-bar" });
  for (const t of tabs) {
    tabBar.appendChild(el("button", {
      className: "tab-btn" + (t.id === activeTab ? " active" : ""),
      onClick: () => dispatch({ type: "PROCEDURE_TAB", tab: t.id }),
    }, t.label));
  }
  root.appendChild(tabBar);

  const code = activeTab === "original" ? proc.source_original : proc.source_rendered;
  if (code) {
    const baseLine = proc.start_line ?? 1;
    const viewer = el("div", { className: "code-viewer" });
    code.split("\n").forEach((line, i) => {
      viewer.appendChild(el("div", { className: "code-line" },
        el("span", { className: "code-line-num" }, String(baseLine + i)),
        el("span", { className: "code-line-content" }, line)));
    });
    root.appendChild(viewer);
    if (activeTab === "original" && proc.file)
      root.appendChild(el("div", { style: "font-size:11px;color:var(--text-muted);margin-top:8px" },
        proc.file + ":" + (proc.start_line ?? "") + "-" + (proc.end_line ?? "")));
  }
}
