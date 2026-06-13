// typeahead.ts — Reusable typeahead search component.

import { el } from "../dom.js";

interface TypeaheadOptions {
  id: string;
  options: string[];
  value?: string;
  placeholder?: string;
  formatItem?: (name: string) => { name: string; kind?: string; sub?: string };
  onSelect?: (name: string) => void;
}

export interface TypeaheadRef {
  element: HTMLElement;
  getValue(): string;
  setValue(v: string): void;
}

export function createTypeahead(opts: TypeaheadOptions): TypeaheadRef {
  let query = opts.value || "";
  let activeIdx = -1;

  const wrapper = el("div", { className: "typeahead" });
  const input = el("input", {
    type: "text",
    placeholder: opts.placeholder || "Type to search...",
    value: query,
  }) as HTMLInputElement;
  const dropdown = el("div", { className: "typeahead-dropdown", style: "display:none" });
  wrapper.appendChild(input);
  wrapper.appendChild(dropdown);

  function getFiltered(): string[] {
    const q = query.toLowerCase().trim();
    if (!q) return opts.options.slice(0, 20);
    return opts.options.filter(o => o.toLowerCase().includes(q)).slice(0, 20);
  }

  function renderDropdown(): void {
    dropdown.innerHTML = "";
    const items = getFiltered();
    activeIdx = -1;
    if (items.length === 0 && query.trim()) {
      dropdown.appendChild(el("div", { className: "typeahead-empty" }, "No matches"));
    } else {
      items.forEach((item, i) => {
        const fmt = opts.formatItem ? opts.formatItem(item) : { name: item };
        const row = el("div", { className: "typeahead-item", dataset: { idx: String(i) } });
        if (fmt.kind) row.appendChild(el("span", { className: "ta-kind" }, fmt.kind));
        row.appendChild(el("span", { className: "ta-name" }, fmt.name || item));
        if (fmt.sub) row.appendChild(el("span", { className: "ta-sub" }, fmt.sub));
        row.addEventListener("mousedown", (e: Event) => {
          e.preventDefault();
          selectItem(item);
        });
        dropdown.appendChild(row);
      });
    }
  }

  function selectItem(item: string): void {
    query = item;
    input.value = item;
    dropdown.style.display = "none";
    if (opts.onSelect) opts.onSelect(item);
  }

  function showDropdown(): void {
    renderDropdown();
    dropdown.style.display = "";
  }

  function hideDropdown(): void {
    dropdown.style.display = "none";
  }

  input.addEventListener("input", () => {
    query = input.value;
    showDropdown();
  });

  input.addEventListener("focus", () => {
    showDropdown();
  });

  input.addEventListener("blur", () => {
    setTimeout(hideDropdown, 150);
  });

  input.addEventListener("keydown", (e: KeyboardEvent) => {
    const items = dropdown.querySelectorAll(".typeahead-item");
    if (e.key === "ArrowDown") {
      e.preventDefault();
      activeIdx = Math.min(activeIdx + 1, items.length - 1);
      items.forEach((el, i) => el.classList.toggle("active", i === activeIdx));
      if (items[activeIdx]) items[activeIdx]!.scrollIntoView({ block: "nearest" });
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      activeIdx = Math.max(activeIdx - 1, 0);
      items.forEach((el, i) => el.classList.toggle("active", i === activeIdx));
      if (items[activeIdx]) items[activeIdx]!.scrollIntoView({ block: "nearest" });
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (activeIdx >= 0 && items[activeIdx]) {
        const filtered = getFiltered();
        const item = filtered[activeIdx];
        if (item) selectItem(item);
      } else if (query.trim()) {
        selectItem(query.trim());
      }
    } else if (e.key === "Escape") {
      hideDropdown();
      input.blur();
    }
  });

  return {
    element: wrapper,
    getValue: () => input.value,
    setValue: (v: string) => { query = v; input.value = v; },
  };
}
