import type { KnownProcInfo, LocalSymbolInfo, ProcedureInfo } from "@pb/platform";

export function buildObjectMap(
  knownObjects: { name: string; kind: string }[],
): Map<string, { name: string; kind: string }> {
  const map = new Map<string, { name: string; kind: string }>();
  for (const o of knownObjects) map.set(o.name.toLowerCase(), o);
  return map;
}

export function buildProcMap(
  knownProcs: KnownProcInfo[],
  procedures: ProcedureInfo[],
  objectName: string,
): Map<string, KnownProcInfo> {
  const map = new Map<string, KnownProcInfo>();
  for (const p of knownProcs) map.set(p.name.toLowerCase(), p);
  for (const p of procedures) {
    map.set(p.name.toLowerCase(), {
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
  return map;
}

export function buildVarMap(
  localSymbols: LocalSymbolInfo[],
): Map<string, LocalSymbolInfo> {
  const map = new Map<string, LocalSymbolInfo>();
  for (const s of localSymbols) {
    const key = s.var_name.toLowerCase();
    if (!map.has(key)) map.set(key, s);
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
