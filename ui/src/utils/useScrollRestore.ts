import { createEffect } from "solid-js";

export function useScrollRestore(
  getFace: () => string,
  scrollPos: Record<string, { source: number; analysis: number }> | undefined,
  entityName: string,
  scrollAreaRef: () => HTMLDivElement | undefined,
): void {
  createEffect(() => {
    const pos = scrollPos?.[entityName];
    if (!pos || !scrollAreaRef()) return;
    scrollAreaRef()!.scrollTop = getFace() === "source" ? pos.source : pos.analysis;
  });
}
