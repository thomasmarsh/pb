import type { IconComp } from "./icons.js";
import { LayoutDashboard, Box, Code2, Grid3X3, Database, Layers } from "./icons.js";

const ENTITY_ICON_MAP: Record<string, IconComp> = {
  library:     LayoutDashboard,
  object:      Box,
  procedure:   Code2,
  datawindow:  Grid3X3,
  table:       Database,
  powerscript: Box,
  project:     Layers,
};

export function entityIcon(kind: string): IconComp {
  return ENTITY_ICON_MAP[kind] ?? Box;
}
