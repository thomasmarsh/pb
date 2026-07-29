// features/explore/browserTabs.ts — Category tabs shown on the Browser page.

export const BROWSER_TABS: { category: string; label: string }[] = [
  { category: "all",         label: "All" },
  { category: "application",  label: "Application" },
  { category: "datawindow",   label: "DataWindow" },
  { category: "window",       label: "Window" },
  { category: "menu",         label: "Menu" },
  { category: "userobject",   label: "User Object" },
  { category: "function",     label: "Function" },
  { category: "system",       label: "System" },
  { category: "structure",    label: "Structure" },
  { category: "tables",       label: "Tables" },
  { category: "procedures",   label: "Procedures" },
];

export function browserTabLabel(category?: string): string {
  if (!category) return "Browser";
  return BROWSER_TABS.find((t) => t.category === category)?.label ?? "Browser";
}
