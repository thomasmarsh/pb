import { onMount, onCleanup } from "solid-js";

export function useListKeyboard(opts: {
  items: () => { select: () => void }[];
  tableSelector: string;
}): void {
  let cursorIdx = -1;

  function highlightRow(idx: number): void {
    const table = document.querySelector(opts.tableSelector);
    if (!table) return;
    table.querySelectorAll("tr.list-cursor").forEach((r) => r.classList.remove("list-cursor"));
    const rows = table.querySelectorAll("tbody tr");
    rows[idx]?.classList.add("list-cursor");
    (rows[idx] as HTMLElement)?.scrollIntoView?.({ block: "nearest" });
  }

  onMount(() => {
    function handleKey(e: KeyboardEvent): void {
      const t = e.target as HTMLElement;
      if (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable) return;
      const items = opts.items();
      if (e.key === "j") {
        e.preventDefault();
        cursorIdx = Math.min(cursorIdx + 1, items.length - 1);
        highlightRow(cursorIdx);
      } else if (e.key === "k") {
        e.preventDefault();
        cursorIdx = Math.max(cursorIdx - 1, 0);
        highlightRow(cursorIdx);
      } else if (e.key === "Enter" && cursorIdx >= 0) {
        e.preventDefault();
        items[cursorIdx]?.select();
      }
    }
    document.addEventListener("keydown", handleKey);
    onCleanup(() => document.removeEventListener("keydown", handleKey));
  });

  return undefined as unknown as void;
}
