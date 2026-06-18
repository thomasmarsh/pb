export function entityIcon(kind: string): string {
  return ENTITY_ICONS[kind] ?? "○";
}

const ENTITY_ICONS: Record<string, string> = {
  library:    "◆",
  object:     "○",
  procedure:  "ƒ",
  datawindow: "▦",
  table:      "⊟",
  powerscript: "○",
  project:    "◆",
};
