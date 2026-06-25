// @pb/platform — Analysis and exploration feature reducers, types, and utils.

// ── Feature reducers + types + actions ──────────────────────────────────────

// Dashboard
export { dashboardReducer, initialDashboardState } from "./features/dashboard/reducer.js";
export type { DashboardEnv } from "./features/dashboard/reducer.js";
export type { DashboardState } from "./features/dashboard/types.js";
export type { DashboardAction } from "./features/dashboard/actions.js";

// DataWindows
export { datawindowsReducer, initialDatawindowsState } from "./features/datawindows/reducer.js";
export type { DatawindowsEnv } from "./features/datawindows/reducer.js";
export type { DatawindowsState } from "./features/datawindows/types.js";
export type { DatawindowsAction } from "./features/datawindows/actions.js";

// Diagrams
export { diagramsReducer, initialDiagramsState } from "./features/diagrams/reducer.js";
export type { DiagramsEnv } from "./features/diagrams/reducer.js";
export type { DiagramsState } from "./features/diagrams/types.js";
export type { DiagramsAction } from "./features/diagrams/actions.js";

// Errors
export { errorsReducer, initialErrorsState } from "./features/errors/reducer.js";
export type { ErrorsEnv } from "./features/errors/reducer.js";
export type { ErrorsState, ErrorKindFilter } from "./features/errors/types.js";
export type { ErrorsAction } from "./features/errors/actions.js";
export { PAGE_SIZE } from "./features/errors/types.js";

// Explore
export { exploreReducer, makeInitialExploreState } from "./features/explore/reducer.js";
export type { ExploreEnv } from "./features/explore/reducer.js";
export type { ExploreState } from "./features/explore/types.js";
export type { ExploreAction } from "./features/explore/actions.js";

// Navigation
export { navReducer } from "./features/navigation/reducer.js";
export type { NavEnv } from "./features/navigation/reducer.js";
export type { NavState, NavigationAction, BreadcrumbSegment } from "./features/navigation/types.js";
export type { Route, ViewName } from "./features/navigation/types.js";
export { print, parse } from "./features/navigation/routes.js";
export { crumbsForRoute, ICONS } from "./features/navigation/breadcrumb.js";

// Objects
export { objectsReducer, initialObjectsState } from "./features/objects/reducer.js";
export type { ObjectsEnv } from "./features/objects/reducer.js";
export type { ObjectsState } from "./features/objects/types.js";
export type { ObjectsAction } from "./features/objects/actions.js";

// Queries
export { queriesReducer, initialQueriesState } from "./features/queries/reducer.js";
export type { QueriesEnv } from "./features/queries/reducer.js";
export type { QueriesState } from "./features/queries/types.js";
export type { QueriesAction } from "./features/queries/actions.js";

// Search
export { searchReducer, initialSearchState } from "./features/search/reducer.js";
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
export { HAS_FOCUS, AUTO_GENERATE } from "./utils/diagram.js";
export { debounce } from "./utils/debounce.js";
export { procBadge, shortFile } from "./utils/format.js";
export { highlightSql, highlightPowerScript, highlightAsync, PB_KEYWORDS } from "./utils/highlight.js";
export { entityIcon } from "./utils/entities.js";
export type { IconComp } from "./utils/icons.js";
export {
  LayoutDashboard, Box, Package, Code2, Grid3X3, Database, Table, List,
  MessageSquare, BarChart2, FolderTree, LayoutList, Layers, Play, X, Minus,
  Square, Maximize2, Minimize2, Menu, Search, AlertTriangle, Clock, Sun, Moon,
  HelpCircle, ChevronLeft, ChevronDown, ChevronRight, ChevronUp, ArrowLeft, ArrowRight, ArrowUpDown,
} from "./utils/icons.js";

// ── API types ────────────────────────────────────────────────────────────────

export type * from "./types/api.js";
