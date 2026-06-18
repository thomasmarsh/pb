import type { JSX } from "solid-js";

interface PaginationProps {
  page: number;
  totalPages: number;
  total: number;
  onPageChange: (page: number) => void;
  pageSize?: number;
}

export function Pagination(props: PaginationProps): JSX.Element {
  const pageSize = () => props.pageSize ?? 100;
  const offset = () => props.page * pageSize();

  return (
    <div class="pagination" style={{ display: "flex", gap: "8px", "align-items": "center", "justify-content": "center", "margin-top": "8px" }}>
      <button
        class="filter-pill"
        disabled={props.page === 0}
        onClick={() => props.onPageChange(props.page - 1)}
      >Prev</button>
      <span style={{ "font-size": "12px", color: "var(--text-muted)" }}>
        {offset() + 1}–{Math.min(offset() + pageSize(), props.total)} of {props.total}
      </span>
      <button
        class="filter-pill"
        disabled={props.page >= props.totalPages - 1}
        onClick={() => props.onPageChange(props.page + 1)}
      >Next</button>
    </div>
  );
}
