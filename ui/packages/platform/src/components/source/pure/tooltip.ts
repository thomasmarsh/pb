import type { ProcedureInfo, ResolvedCallInfo, ResolvedVarRefInfo } from "@pb/platform";

export const PROC_COLORS: Record<string, string> = {
  function: "proc-function",
  subroutine: "proc-subroutine",
  event: "proc-event",
  on: "proc-on",
};

export const PROC_BADGE_COLORS: Record<string, string> = {
  function: "#a78bfa",
  subroutine: "#fb923c",
  event: "#facc15",
  on: "#4ade80",
};

export const PROC_TYPE_LABELS: Record<string, string> = {
  function: "Function",
  subroutine: "Subroutine",
  event: "Event",
  on: "On",
};

export interface TooltipContent { html: string; color: string }

export type QuickInfoDecl =
  | { shape: "callable"; kindLabel: string; kindColor: string; name: string; params: string; returnType: string | null }
  | { shape: "value"; kindLabel: string; kindColor: string; name: string; type: string | null };

export function renderQuickInfoHeader(decl: QuickInfoDecl): string {
  const kind = `<span class="qi-kind" style="color:${decl.kindColor}">‹${decl.kindLabel}›</span>`;
  const name = `<span class="qi-name">${decl.name}</span>`;
  if (decl.shape === "callable") {
    const returns = decl.returnType
      ? ` <span class="qi-kw">returns</span> <span class="qi-type">${decl.returnType}</span>`
      : "";
    return `<div class="tt-name">${kind} ${name} <span class="qi-params">(${decl.params})</span>${returns}</div>`;
  }
  const type = decl.type ? ` <span class="qi-params">(${decl.type})</span>` : "";
  return `<div class="tt-name">${kind} ${name}${type}</div>`;
}

export function buildObjectTooltip(
  linkName: string,
  obj: { name: string; kind: string } | undefined,
): TooltipContent {
  const kind = obj?.kind ?? "object";
  const color = kind === "datawindow" ? "#56A85D" : "#5B8DD9";
  return {
    color,
    html: `<div class="tt-name" style="color:${color}">${linkName}</div><div class="tt-meta">${kind}</div>`,
  };
}

const CALL_KIND_COLORS: Record<ResolvedCallInfo["kind"], string> = {
  virtual: "#a78bfa",
  static: "#4ec9b0",
  inherited: "#56b6c2",
  unresolved: "#6b7280",
};

export function buildProcTooltip(
  linkName: string,
  call: ResolvedCallInfo | undefined,
  counts: { caller_count: number; callee_count: number } | undefined,
): TooltipContent {
  const color = call ? CALL_KIND_COLORS[call.kind] : "#a78bfa";
  let html: string;
  if (call?.target_proc_type) {
    html = renderQuickInfoHeader({
      shape: "callable",
      kindLabel: PROC_TYPE_LABELS[call.target_proc_type] ?? call.target_proc_type,
      kindColor: PROC_BADGE_COLORS[call.target_proc_type] ?? color,
      name: call.target_proc ?? call.to_name,
      params: call.target_params ?? "",
      returnType: call.target_return_type,
    });
  } else {
    html = `<div class="tt-name" style="color:${color}">${linkName}</div>`;
  }
  if (call) {
    const target = call.target_object
      ? `${call.target_object}.${call.target_proc ?? call.to_name}`
      : call.to_name;
    html += `<div class="tt-meta">${call.kind} → ${target}</div>`;
    html += `<div class="tt-cc"><span class="badge badge-cc">${call.confidence}</span></div>`;
    if (counts) {
      html += `<div class="tt-meta">Callers: ${counts.caller_count} · Callees: ${counts.callee_count}</div>`;
    }
  }
  return { color, html };
}

const VAR_KIND_COLORS: Record<ResolvedVarRefInfo["kind"], string> = {
  local: "#9cdcfe",
  param: "#4fc1ff",
  instance: "#98c379",
  global: "#fb923c",
  control: "#4ade80",
  class: "#5B8DD9",
  class_static: "#5B8DD9",
  builtin_property: "#dcdcaa",
  dw_column: "#4dd0e1",
  dw_control: "#4dd0e1",
  dw_property: "#80cbc4",
  unresolved: "#6b7280",
};

const VAR_KIND_LABELS: Record<ResolvedVarRefInfo["kind"], string> = {
  local: "Local", param: "Param", instance: "Instance", global: "Global",
  control: "Control", class: "Class", class_static: "Class Static",
  builtin_property: "Builtin Property", dw_column: "DW Column",
  dw_control: "DW Control", dw_property: "DW Property", unresolved: "Unresolved",
};

export function buildVarTooltip(
  linkName: string,
  ref: ResolvedVarRefInfo | undefined,
): TooltipContent | null {
  if (!ref) return null;
  const color = VAR_KIND_COLORS[ref.kind];
  let html = renderQuickInfoHeader({
    shape: "value",
    kindLabel: VAR_KIND_LABELS[ref.kind],
    kindColor: color,
    name: linkName,
    type: ref.declared_type,
  });
  if (ref.target_object) {
    html += `<div class="tt-meta" style="color:#5B8DD9">${ref.target_object}</div>`;
  }
  html += `<div class="tt-meta">${ref.access}${ref.confidence !== "high" ? ` · ${ref.confidence}` : ""}</div>`;
  return { color, html };
}

export function buildProcBarTooltip(
  p: ProcedureInfo,
  counts: { caller_count: number; callee_count: number } | undefined,
  badgeColor: string,
  viewedObjectName: string,
): string {
  const displayName = p.owner && p.owner !== viewedObjectName
    ? `${p.owner} · ${p.name}` : p.name;
  const cc = p.cyclomatic != null ? `CC: ${p.cyclomatic}` : "";
  return renderQuickInfoHeader({
    shape: "callable",
    kindLabel: PROC_TYPE_LABELS[p.proc_type] ?? p.proc_type,
    kindColor: badgeColor,
    name: displayName,
    params: p.params ?? "",
    returnType: p.return_type,
  }) +
    `<div class="tt-meta">Lines ${p.start_line}–${p.end_line}</div>` +
    (cc ? `<div class="tt-cc"><span class="badge badge-cc">${cc}</span></div>` : "") +
    (counts ? `<div class="tt-meta">Callers: ${counts.caller_count} · Callees: ${counts.callee_count}</div>` : "");
}
