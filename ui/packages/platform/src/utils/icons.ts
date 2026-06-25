// utils/icons.ts — Central re-export of Lucide icons used across the app.
// Import from here, not directly from lucide-solid, so substitutions stay in one place.

import type { Component } from "solid-js";

export type IconComp = Component<{ size?: number; class?: string; color?: string; strokeWidth?: number }>;

export {
  // Entity / nav
  LayoutDashboard,
  Box,
  Package,
  Code2,
  Grid3X3,
  Database,
  Table,
  List,
  MessageSquare,
  BarChart2,
  FolderTree,
  LayoutList,
  Layers,
  Play,
  X,
  Minus,
  Square,
  Maximize2,
  Minimize2,
  Menu,

  // Actions / UI chrome
  Search,
  AlertTriangle,
  Clock,
  Sun,
  Moon,
  HelpCircle,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  ChevronDown,
  ArrowLeft,
  ArrowRight,
  ArrowUpDown,
  Copy,
  Check,
  Download,
  ZoomIn,
  ZoomOut,
} from "lucide-solid";
