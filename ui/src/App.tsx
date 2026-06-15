// App.tsx — SolidJS entry point. Valtio proxy store, prop-drilled.

import { render, Show } from "solid-js/web";
import type { JSX } from "solid-js";
import { createStore, useSnapshot } from "./core/store.js";
import type { Store } from "./core/store.js";
import { initialState, reducer } from "./app/reducer.js";
import type { AppState } from "./app/state.js";
import type { AppAction } from "./app/actions.js";
import { createApiClient, createEnv } from "./app/api-client.js";
import { Layout } from "./components/Layout.js";
import { Dashboard } from "./components/Dashboard.js";
import { Objects, ObjectDetail } from "./components/Objects.js";
import { ProcedureDetail } from "./components/ProcedureDetail.js";
import { DataWindows, DWDetail } from "./components/DataWindows.js";
import { Diagrams } from "./components/Diagrams.js";
import { Queries } from "./components/Queries.js";
import { Search } from "./components/Search.js";
import { Explore } from "./components/Explore.js";
import { initViewFromUrl, setupPopstateHandler, syncUrlFromState, NAV_SYNC_ACTIONS } from "./features/navigation/url-sync.js";
import type { NavigationAction } from "./features/navigation/types.js";
import { HealthCheck } from "./components/HealthCheck.js";

const env = createEnv(createApiClient());
const store = createStore(initialState(), reducer, env, (action, state) => {
  if (action.tag === "nav" && NAV_SYNC_ACTIONS.has(action.action.type)) {
    syncUrlFromState(state.nav.view, {
      objectDetail: state.nav.objectDetail,
      procedureDetail: state.nav.procedureDetail,
      dwDetail: state.nav.dwDetail,
    }, action.action);
  }
});

// Bootstrap: read URL and dispatch initial actions
const navDispatch = (a: NavigationAction) => store.dispatch({ tag: "nav", action: a });
initViewFromUrl(navDispatch);
setupPopstateHandler(navDispatch);

// Load stats for dashboard
store.dispatch({ tag: "nav", action: { type: "stats-load" } });

function ViewRouter(props: { store: Store<AppState, AppAction> }): JSX.Element {
  const snap = useSnapshot(props.store.state);
  return (
    <Layout store={props.store}>
      <Show when={snap().nav.view === "dashboard"}><Dashboard store={props.store} /></Show>
      <Show when={snap().nav.view === "objects"}><Objects store={props.store} /></Show>
      <Show when={snap().nav.view === "objectDetail"}><ObjectDetail store={props.store} /></Show>
      <Show when={snap().nav.view === "procedureDetail"}><ProcedureDetail store={props.store} /></Show>
      <Show when={snap().nav.view === "datawindows"}><DataWindows store={props.store} /></Show>
      <Show when={snap().nav.view === "dwDetail"}><DWDetail store={props.store} /></Show>
      <Show when={snap().nav.view === "diagrams"}><Diagrams store={props.store} /></Show>
      <Show when={snap().nav.view === "queries"}><Queries store={props.store} /></Show>
      <Show when={snap().nav.view === "search"}><Search store={props.store} /></Show>
      <Show when={snap().nav.view === "explore"}><Explore store={props.store} /></Show>
    </Layout>
  );
}

function App(): JSX.Element {
  return (
    <>
      <ViewRouter store={store} />
      <HealthCheck />
    </>
  );
}

const root = document.getElementById("app");
if (root) render(() => <App />, root);
