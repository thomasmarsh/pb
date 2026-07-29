// @pb/platform — Analysis and exploration feature reducers, types, and utils.

// ── Feature reducers + types + actions ──────────────────────────────────────

// Analysis (Plan 161 Phase 4 — live_proc table)
export {
  analysisReducer,
  initialAnalysisState,
} from "./features/analysis/reducer.js";
export type { AnalysisEnv } from "./features/analysis/reducer.js";
export type { AnalysisState } from "./features/analysis/types.js";
export type { AnalysisAction } from "./features/analysis/actions.js";

// Dashboard
export {
  dashboardReducer,
  initialDashboardState,
} from "./features/dashboard/reducer.js";
export type { DashboardEnv } from "./features/dashboard/reducer.js";
export type { DashboardState } from "./features/dashboard/types.js";
export type { DashboardAction } from "./features/dashboard/actions.js";

// DataWindows
export {
  datawindowsReducer,
  initialDatawindowsState,
} from "./features/datawindows/reducer.js";
export type { DatawindowsEnv } from "./features/datawindows/reducer.js";
export type { DatawindowsState } from "./features/datawindows/types.js";
export type { DatawindowsAction } from "./features/datawindows/actions.js";

// Diagrams
export {
  diagramsReducer,
  initialDiagramsState,
} from "./features/diagrams/reducer.js";
export type { DiagramsEnv } from "./features/diagrams/reducer.js";
export type { DiagramsState } from "./features/diagrams/types.js";
export type { DiagramsAction } from "./features/diagrams/actions.js";

// Diagnostics
export {
  diagnosticsReducer,
  initialDiagnosticsState,
} from "./features/diagnostics/reducer.js";
export type { DiagnosticsEnv } from "./features/diagnostics/reducer.js";
export type { DiagnosticsState, DiagnosticsKindFilter } from "./features/diagnostics/types.js";
export type { DiagnosticsAction } from "./features/diagnostics/actions.js";
export { PAGE_SIZE } from "./features/diagnostics/types.js";

// Explore
export {
  exploreReducer,
  makeInitialExploreState,
} from "./features/explore/reducer.js";
export type { ExploreEnv } from "./features/explore/reducer.js";
export type { ExploreState } from "./features/explore/types.js";
export type { ExploreAction } from "./features/explore/actions.js";
export { BROWSER_TABS, browserTabLabel } from "./features/explore/browserTabs.js";

// Navigation
export { navReducer } from "./features/navigation/reducer.js";
export type { NavEnv } from "./features/navigation/reducer.js";
export type {
  NavState,
  NavigationAction,
  BreadcrumbSegment,
} from "./features/navigation/types.js";
export type { Route, ViewName } from "./features/navigation/types.js";
export { print, parse } from "./features/navigation/routes.js";
export { crumbsForRoute, ICONS } from "./features/navigation/breadcrumb.js";

// Objects
export {
  objectsReducer,
  initialObjectsState,
} from "./features/objects/reducer.js";
export type { ObjectsEnv } from "./features/objects/reducer.js";
export type { ObjectsState } from "./features/objects/types.js";
export type { ObjectsAction } from "./features/objects/actions.js";

// Queries
export {
  queriesReducer,
  initialQueriesState,
} from "./features/queries/reducer.js";
export type { QueriesEnv } from "./features/queries/reducer.js";
export { ASK_RUN_KEY } from "./features/queries/types.js";
export type { QueriesState, QueryRunState } from "./features/queries/types.js";
export type { QueriesAction } from "./features/queries/actions.js";

// Search
export {
  searchReducer,
  initialSearchState,
} from "./features/search/reducer.js";
export type { SearchEnv } from "./features/search/reducer.js";
export type { SearchState } from "./features/search/types.js";
export type { SearchAction } from "./features/search/actions.js";

// Tables
export { tablesReducer } from "./features/tables/reducer.js";
export { initialTablesState } from "./features/tables/types.js";
export type { TablesEnv } from "./features/tables/reducer.js";
export type { TablesState } from "./features/tables/types.js";
export type { TablesAction } from "./features/tables/actions.js";

// ── Utils ────────────────────────────────────────────────────────────────────

export { anonymizeText } from "./utils/anonymize.js";
export { parsePbUrl, getPbHref, diagramUrl } from "./utils/diagram.js";
export type { DiagramKind } from "./utils/diagram.js";
export { HAS_FOCUS, AUTO_GENERATE, DIAGRAM_KINDS } from "./utils/diagram.js";
export { debounce } from "./utils/debounce.js";
export { procBadge, shortFile } from "./utils/format.js";
export {
  highlightSql,
  highlightPowerScript,
  highlightAsync,
  PB_KEYWORDS,
} from "./utils/highlight.js";
export type { IdentifierLinkContext } from "./utils/highlight.js";
export { entityIcon } from "./utils/entities.js";
export type { IconComp } from "./utils/icons.js";
export {
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
  Search,
  AlertTriangle,
  Clock,
  Sun,
  Moon,
  HelpCircle,
  ChevronLeft,
  ChevronDown,
  ChevronRight,
  ChevronUp,
  ArrowLeft,
  ArrowRight,
  ArrowUpDown,
} from "./utils/icons.js";

// ── API types ────────────────────────────────────────────────────────────────

export type * from "./types/api.js";

// ── Components ───────────────────────────────────────────────────────────────

// Top-level
export { DataWindowGrid } from "./components/DataWindowGrid.js";
export { DwPreview } from "./components/DwPreview.js";
export { ResizableCanvas } from "./components/ResizableCanvas.js";

// Analysis
export { AnalysisView } from "./components/analysis/AnalysisView.js";
export { FormalReports } from "./components/analysis/FormalReports.js";
export { LinearTrace } from "./components/analysis/LinearTrace.js";
export type {
  TraceType,
  LinearTraceProps,
} from "./components/analysis/LinearTrace.js";

// Controls (PB window runtime controls)
export { CommandButton } from "./components/controls/CommandButton.js";
export { GroupBox } from "./components/controls/GroupBox.js";
export { LineEdit } from "./components/controls/LineEdit.js";
export { StaticText } from "./components/controls/StaticText.js";

// Detail
export { AnalysisExplainer } from "./components/detail/AnalysisExplainer.js";
export type { AnalysisExplainerContent } from "./components/detail/AnalysisExplainer.js";
export { AnalysisSummaryBar } from "./components/detail/AnalysisSummaryBar.js";
export type { SummaryItem } from "./components/detail/AnalysisSummaryBar.js";
export { CodeBlock, SqlBlock } from "./components/detail/CodeBlock.js";
export { ColumnRow } from "./components/detail/ColumnRow.js";
export { ContextualPanel } from "./components/detail/ContextualPanel.js";
export { DetailHeader } from "./components/detail/DetailHeader.js";
export { DetailShell } from "./components/detail/DetailShell.js";
export { EntityCard } from "./components/detail/EntityCard.js";
export type { EntityType } from "./components/detail/EntityCard.js";
export { EntityListCard } from "./components/detail/EntityListCard.js";

// Diagram
export { DiagramTooltip } from "./components/diagram/DiagramTooltip.js";
export {
  computeZoom,
  smoothVelocity,
  stripSvgTitles,
  computeTooltipPosition,
  releaseVelocity,
  runMomentum,
  ZOOM_MIN,
  ZOOM_MAX,
} from "./components/diagram/diagramMath.js";
export { createPanZoom } from "./components/diagram/usePanZoom.js";
export type {
  PanZoom,
  PanZoomState,
  PanZoomActions,
  PanZoomHandlers,
} from "./components/diagram/usePanZoom.js";

// Diagrams feature components
export { SvgToolbar } from "./components/diagrams/SvgToolbar.js";

// Objects
export { MetricsGrid } from "./components/objects/MetricsGrid.js";

// Source
export { SourceView } from "./components/source/SourceView.js";
export type { SourceViewProps, SourceLinkTarget } from "./components/source/SourceView.js";
export { SourceTooltip } from "./components/source/SourceTooltip.js";
export {
  procSelectedRange,
  procedureAtLine,
} from "./components/source/pure/line.js";
export {
  buildObjectMap,
  buildCallSpanMap,
  buildVarRefSpanMap,
  buildProcCountMap,
  buildProcFirstLine,
  buildProcRangeMap,
} from "./components/source/pure/lookup.js";
export {
  PROC_COLORS,
  PROC_BADGE_COLORS,
  buildObjectTooltip,
  buildProcTooltip,
  buildVarTooltip,
  buildProcBarTooltip,
} from "./components/source/pure/tooltip.js";
export type { TooltipContent } from "./components/source/pure/tooltip.js";

// UI
export { BackButton } from "./components/ui/BackButton.js";
export { ComboboxInput } from "./components/ui/ComboboxInput.js";
export { CopyButton } from "./components/ui/CopyButton.js";
export { HealthCheck } from "./components/ui/HealthCheck.js";
export { Loading } from "./components/ui/Loading.js";
export { ModalShell } from "./components/ui/ModalShell.js";
export { Pagination } from "./components/ui/Pagination.js";

// Windows
export { MenuBar } from "./components/windows/MenuBar.js";
export { WindowControls } from "./components/windows/WindowControls.js";

// ── Hooks ─────────────────────────────────────────────────────────────────────

export { useListKeyboard } from "./utils/hooks/useListKeyboard.js";
