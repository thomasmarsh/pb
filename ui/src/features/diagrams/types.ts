// features/diagrams/types.ts

export interface DiagramsState {
  active: "inheritance" | "calls" | "dw-tables" | "heatmap" | "sql-lineage" | "table-lineage";
  svg: string | null;
  loading: boolean;
  params: Record<string, string | number>;
  error?: string;
}
