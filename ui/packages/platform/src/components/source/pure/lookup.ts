import type { ProcedureInfo, ResolvedCallInfo, ResolvedVarRefInfo } from "@pb/platform";

export function buildObjectMap(
  knownObjects: { name: string; kind: string }[],
): Map<string, { name: string; kind: string }> {
  const map = new Map<string, { name: string; kind: string }>();
  for (const o of knownObjects) map.set(o.name.toLowerCase(), o);
  return map;
}

// Keys by the call site's own (line, start_col) -- not the callee name -- so two
// unrelated calls that happen to share a name (e.g. RowCount on two different
// DataWindow descendants) resolve independently instead of one clobbering the
// other in a last-write-wins name map (Plan 195 Phase F).
export function buildCallSpanMap(
  resolvedCalls: ResolvedCallInfo[],
): Map<string, ResolvedCallInfo> {
  const map = new Map<string, ResolvedCallInfo>();
  for (const c of resolvedCalls) {
    if (c.to_name_start_line == null || c.to_name_start_col == null) continue;
    map.set(`${c.to_name_start_line}:${c.to_name_start_col}`, c);
  }
  return map;
}

// Keys by the reference's own (line, start_col), same rationale as buildCallSpanMap.
export function buildVarRefSpanMap(
  resolvedVarRefs: ResolvedVarRefInfo[],
): Map<string, ResolvedVarRefInfo> {
  const map = new Map<string, ResolvedVarRefInfo>();
  for (const r of resolvedVarRefs) {
    if (r.name_start_line == null || r.name_start_col == null) continue;
    map.set(`${r.name_start_line}:${r.name_start_col}`, r);
  }
  return map;
}

export function buildProcCountMap(
  procedures: ProcedureInfo[],
): Map<string, { caller_count: number; callee_count: number }> {
  const map = new Map<string, { caller_count: number; callee_count: number }>();
  for (const p of procedures) {
    map.set(p.name.toLowerCase(), {
      caller_count: p.caller_count ?? 0,
      callee_count: p.callee_count ?? 0,
    });
  }
  return map;
}

export function buildProcFirstLine(
  procedures: ProcedureInfo[],
): Map<number, ProcedureInfo> {
  const map = new Map<number, ProcedureInfo>();
  for (const p of procedures) {
    if (p.start_line != null) map.set(p.start_line, p);
  }
  return map;
}

// Maps every line within a procedure's [start_line, end_line] range to that
// procedure. Rendered per-line (one row at a time) so the resulting overlay
// strip is pinned to real DOM rows and cannot drift, unlike a pixel-offset
// overlay sized from a hardcoded line-height constant.
export function buildProcRangeMap(
  procedures: ProcedureInfo[],
): Map<number, ProcedureInfo> {
  const map = new Map<number, ProcedureInfo>();
  for (const p of procedures) {
    if (p.start_line == null || p.end_line == null) continue;
    for (let line = p.start_line; line <= p.end_line; line++) map.set(line, p);
  }
  return map;
}
