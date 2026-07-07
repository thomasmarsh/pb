// features/diagrams/types.ts

export interface DiagramsState {
  active: "inheritance" | "calls" | "dw-tables" | "heatmap" | "sql-lineage" | "table-lineage" | "proc-tables" | "fk-graph";
  svg: string | null;
  loading: boolean;
  params: Record<string, string | number>;
  error?: string;
  tableNames: string[];
  objectNames: string[];
  itemsLoaded: boolean;
}
