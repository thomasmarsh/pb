export interface SQLResult {
  rows: Record<string, unknown>[];
  columns: string[];
  rowcount: number;
  error?: string;
}
