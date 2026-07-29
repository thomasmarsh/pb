// App.tsx — SolidJS entry point. Valtio proxy store, prop-drilled.

import { render, Show } from "solid-js/web";
import type { JSX } from "solid-js";
import { createStore, type Store } from "@pb/core";
import { initialState, reducer } from "./reducer.js";
import type { AppState } from "./state.js";
import type { AppAction } from "./actions.js";
import { createApiClient, createEnv } from "./api-client.js";
import { Layout } from "./layout/Layout.js";
import { GlobalSearch } from "./views/components/GlobalSearch.js";
import { HelpOverlay } from "./layout/HelpOverlay.js";
import { Dashboard } from "./views/features/dashboard/Dashboard.js";
import { Objects } from "./views/features/objects/Objects.js";
import { ObjectDetail } from "./views/features/objects/ObjectDetail.js";
import { ProcedureDetail } from "./views/features/objects/ProcedureDetail.js";
import { ProceduresList } from "./views/features/objects/ProceduresList.js";
import { DataWindows, DWDetail } from "./views/features/datawindows/DataWindows.js";
import { Tables } from "./views/features/tables/Tables.js";
import { Diagrams } from "./views/features/diagrams/Diagrams.js";
import { Queries } from "./views/features/queries/Queries.js";
import { Search } from "./views/features/search/Search.js";
import { Explore } from "./views/features/explore/Explore.js";
import { Browser } from "./views/features/explore/Browser.js";
import { Diagnostics } from "./views/features/diagnostics/Diagnostics.js";
import { LibraryDetail } from "./views/features/library/LibraryDetail.js";
import { DeadCode } from "./views/features/analysis/DeadCode.js";
import { DeadVars } from "./views/features/analysis/DeadVars.js";
import { TypeMismatches } from "./views/features/analysis/TypeMismatches.js";
import { LiveProcedures } from "./views/features/analysis/LiveProcedures.js";
import { TaintExplorer } from "./views/features/analysis/TaintExplorer.js";
import { TaintPathView } from "./views/features/analysis/TaintPathView.js";
import { SliceView } from "./views/features/analysis/SliceView.js";
import { FormalReports, HealthCheck } from "@pb/platform";
import { CFGDiagram } from "./views/features/analysis/CFGDiagram.js";
import { LaunchView } from "./views/features/launch/LaunchView.js";
import { initViewFromUrl, setupPopstateHandler } from "./views/features/navigation/url-sync.js";

const env = createEnv(createApiClient());
const store = createStore(initialState(), reducer, env);

// Bootstrap: read URL and dispatch initial actions
initViewFromUrl((a: AppAction) => store.dispatch(a));
setupPopstateHandler((a: AppAction) => store.dispatch(a));

// Load initial state for features
store.dispatch({ tag: "theme", action: { tag: "load" } });
store.dispatch({ tag: "dashboard", action: { tag: "load" } });
store.dispatch({ tag: "explore", action: { tag: "load" } });

function ViewRouter(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = props.store.getState();
  return (
    <Layout store={props.store}>
      <Show when={snap().nav.route.view === "dashboard"}><Dashboard store={props.store} /></Show>
      <Show when={snap().nav.route.view === "objects"}><Objects store={props.store} /></Show>
      <Show when={snap().nav.route.view === "objectDetail"}><ObjectDetail store={props.store} /></Show>
      <Show when={snap().nav.route.view === "procedureDetail"}><ProcedureDetail store={props.store} /></Show>
      <Show when={snap().nav.route.view === "proceduresList"}><ProceduresList store={props.store} /></Show>
      <Show when={snap().nav.route.view === "datawindows"}><DataWindows store={props.store} /></Show>
      <Show when={snap().nav.route.view === "dwDetail"}><DWDetail store={props.store} /></Show>
      <Show when={snap().nav.route.view === "tables" || snap().nav.route.view === "tableDetail"}><Tables store={props.store} /></Show>
      <Show when={snap().nav.route.view === "diagrams"}><Diagrams store={props.store} /></Show>
      <Show when={snap().nav.route.view === "queries"}><Queries store={props.store} /></Show>
      <Show when={snap().nav.route.view === "search"}><Search store={props.store} /></Show>
      <Show when={snap().nav.route.view === "explore"}><Explore store={props.store} /></Show>
      <Show when={snap().nav.route.view === "browser"}><Browser store={props.store} /></Show>
      <Show when={snap().nav.route.view === "diagnostics"}><Diagnostics store={props.store} /></Show>
      <Show when={snap().nav.route.view === "libraryDetail"}><LibraryDetail store={props.store} /></Show>
      <Show when={snap().nav.route.view === "deadCode"}><DeadCode store={props.store} /></Show>
      <Show when={snap().nav.route.view === "deadVars"}><DeadVars store={props.store} /></Show>
      <Show when={snap().nav.route.view === "typeMismatches"}><TypeMismatches store={props.store} /></Show>
      <Show when={snap().nav.route.view === "liveProcedures"}><LiveProcedures store={props.store} /></Show>
      <Show when={snap().nav.route.view === "taintExplorer"}><TaintExplorer store={props.store} /></Show>
      <Show when={snap().nav.route.view === "taintPathView"}><TaintPathView store={props.store} /></Show>
      <Show when={snap().nav.route.view === "sliceView"}><SliceView store={props.store} /></Show>
      <Show when={snap().nav.route.view === "formalReports"}><FormalReports /></Show>
      <Show when={snap().nav.route.view === "cfgDiagram"}><CFGDiagram store={props.store} /></Show>
      <Show when={snap().nav.route.view === "launch"}><LaunchView store={props.store} /></Show>
    </Layout>
  );
}

function App(): JSX.Element {
  return (
    <>
      <ViewRouter store={store} />
      <GlobalSearch store={store} />
      <HelpOverlay store={store} />
      <HealthCheck />
    </>
  );
}

const root = document.getElementById("app");
if (root) render(() => <App />, root);
