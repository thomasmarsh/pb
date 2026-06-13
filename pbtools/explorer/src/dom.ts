// dom.ts — Minimal DOM helpers for building UI elements.

type AttrValue = string | boolean | ((e: Event) => void) | Record<string, string>;
type Attrs = Record<string, AttrValue> | null;

export function el(
  tag: string,
  attrs?: Attrs,
  ...children: (Node | string | null | undefined)[]
): HTMLElement {
  const e = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (k === "className") e.className = v as string;
      else if (k === "html") e.innerHTML = v as string;
      else if (k === "dataset" && typeof v === "object") {
        for (const [dk, dv] of Object.entries(v)) e.dataset[dk] = dv;
      } else if (k.startsWith("on") && typeof v === "function") {
        e.addEventListener(k.slice(2).toLowerCase(), v as (e: Event) => void);
      } else {
        e.setAttribute(k, String(v));
      }
    }
  }
  for (const c of children) {
    if (typeof c === "string") e.appendChild(document.createTextNode(c));
    else if (c) e.appendChild(c);
  }
  return e;
}

export function $(sel: string, ctx?: ParentNode): HTMLElement | null {
  return (ctx || document).querySelector(sel);
}

export function $$(sel: string, ctx?: ParentNode): HTMLElement[] {
  return [...(ctx || document).querySelectorAll(sel)] as HTMLElement[];
}
