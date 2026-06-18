// App.tsx — SolidJS entry point. Valtio proxy store, prop-drilled.

import { render, Show } from "solid-js/web";
import type { JSX } from "solid-js";
import { createStore } from "./core/store.js";
import type { Store } from "./core/store.js";
import { initialState, reducer } from "./app/reducer.js";
import type { AppState } from "./app/state.js";
import type { AppAction } from "./app/actions.js";
import { createApiClient, createEnv } from "./app/api-client.js";
import { Layout } from "./components/Layout.js";
import { GlobalSearch } from "./components/GlobalSearch.js";
import { HelpOverlay } from "./components/HelpOverlay.js";
import { Dashboard } from "./features/dashboard/Dashboard.js";
import { Objects } from "./features/objects/Objects.js";
import { ObjectDetail } from "./features/objects/ObjectDetail.js";
import { ProcedureDetail } from "./features/objects/ProcedureDetail.js";
import { ProceduresList } from "./features/objects/ProceduresList.js";
import { DataWindows, DWDetail } from "./features/datawindows/DataWindows.js";
import { Tables } from "./features/tables/Tables.js";
import { Diagrams } from "./features/diagrams/Diagrams.js";
import { Queries } from "./features/queries/Queries.js";
import { Search } from "./features/search/Search.js";
import { Explore } from "./features/explore/Explore.js";
import { Errors } from "./features/errors/Errors.js";
import { LibraryDetail } from "./features/library/LibraryDetail.js";
import { DeadCode } from "./features/analysis/DeadCode.js";
import { TaintExplorer } from "./features/analysis/TaintExplorer.js";
import { FormalReports } from "./features/analysis/FormalReports.js";
import { initViewFromUrl, setupPopstateHandler } from "./features/navigation/url-sync.js";
import { HealthCheck } from "./components/HealthCheck.js";

const env = createEnv(createApiClient());
const store = createStore(initialState(), reducer, env);

// Bootstrap: read URL and dispatch initial actions
initViewFromUrl((a: AppAction) => store.dispatch(a));
setupPopstateHandler((a: AppAction) => store.dispatch(a));

// Load initial state for features
store.dispatch({ tag: "theme", action: { type: "load" } });
store.dispatch({ tag: "dashboard", action: { type: "load" } });
store.dispatch({ tag: "explore", action: { type: "load" } });

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
      <Show when={snap().nav.route.view === "errors"}><Errors store={props.store} /></Show>
      <Show when={snap().nav.route.view === "libraryDetail"}><LibraryDetail store={props.store} /></Show>
      <Show when={snap().nav.route.view === "deadCode"}><DeadCode store={props.store} /></Show>
      <Show when={snap().nav.route.view === "taintExplorer"}><TaintExplorer store={props.store} /></Show>
      <Show when={snap().nav.route.view === "formalReports"}><FormalReports store={props.store} /></Show>
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
