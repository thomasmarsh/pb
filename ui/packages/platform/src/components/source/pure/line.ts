import type { ProcedureInfo } from "@pb/platform";

export const PIXELS_PER_LINE = 20.8;

export function lineFromY(clientY: number, containerTop: number, scrollTop: number): number {
  return Math.max(1, 1 + Math.floor((clientY - containerTop + scrollTop) / PIXELS_PER_LINE));
}

export function overlayTop(startLine: number): number {
  return (startLine - 1) * PIXELS_PER_LINE;
}

export function overlayHeight(startLine: number, endLine: number): number {
  return (endLine - startLine + 1) * PIXELS_PER_LINE;
}

export function dimmedRanges(
  totalLines: number,
  highlightedLines: Set<number>,
): { start: number; end: number }[] {
  const ranges: { start: number; end: number }[] = [];
  let rangeStart: number | null = null;
  for (let line = 1; line <= totalLines; line++) {
    if (highlightedLines.has(line)) {
      if (rangeStart !== null) {
        ranges.push({ start: rangeStart, end: line - 1 });
        rangeStart = null;
      }
    } else if (rangeStart === null) {
      rangeStart = line;
    }
  }
  if (rangeStart !== null) ranges.push({ start: rangeStart, end: totalLines });
  return ranges;
}

export function procSelectedRange(
  procedures: ProcedureInfo[],
  selectedProcName: string | undefined,
): { start: number; end: number } | null {
  if (!selectedProcName) return null;
  const proc = procedures.find(p => p.name === selectedProcName);
  if (!proc || proc.start_line == null || proc.end_line == null) return null;
  return { start: proc.start_line, end: proc.end_line };
}
