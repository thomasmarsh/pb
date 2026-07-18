import type { ProcedureInfo } from "@pb/platform";

export function procSelectedRange(
  procedures: ProcedureInfo[],
  selectedProcName: string | undefined,
): { start: number; end: number } | null {
  if (!selectedProcName) return null;
  const proc = procedures.find(p => p.name === selectedProcName);
  if (!proc || proc.start_line == null || proc.end_line == null) return null;
  return { start: proc.start_line, end: proc.end_line };
}

export function procedureAtLine(
  procedures: ProcedureInfo[],
  line: number,
): ProcedureInfo | undefined {
  return procedures.find(
    p => p.start_line != null && p.end_line != null && line >= p.start_line && line <= p.end_line
  );
}
