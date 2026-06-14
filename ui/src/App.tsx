// App.tsx — SolidJS entry point. Pure TCA with deep linking.

import { render, Show } from "solid-js/web";
import { StoreProvider } from "./context.js";
import { createStoreAdapter } from "./store.js";
import { initialState, reducer } from "./core.js";
import { createApiClient, createEnv } from "./api-client.js";
import { Layout } from "./components/Layout.js";
import { Dashboard } from "./components/Dashboard.js";
import { Objects, ObjectDetail } from "./components/Objects.js";
import { ProcedureDetail } from "./components/ProcedureDetail.js";
import { DataWindows, DWDetail } from "./components/DataWindows.js";
import { Diagrams } from "./components/Diagrams.js";
import { Queries } from "./components/Queries.js";
import { Search } from "./components/Search.js";
import { Explore } from "./components/Explore.js";
import { useStore } from "./context.js";
import { initViewFromUrl, setupPopstateHandler } from "./navigation.js";
import { HealthCheck } from "./components/HealthCheck.js";

const env = createEnv(createApiClient());
const store = createStoreAdapter(initialState(), reducer, env);

// Bootstrap: read URL and dispatch initial actions
initViewFromUrl(store.dispatch);
setupPopstateHandler(store.dispatch);

// Load stats for dashboard (always needed for sidebar)
if (!store.state.stats) store.dispatch({ type: "STATS_LOAD" });

function ViewRouter() {
  const store = useStore();
  const view = () => store.state.view;

  return (
    <Layout>
      <Show when={view() === "dashboard"}><Dashboard /></Show>
      <Show when={view() === "objects"}><Objects /></Show>
      <Show when={view() === "objectDetail"}><ObjectDetail /></Show>
      <Show when={view() === "procedureDetail"}><ProcedureDetail /></Show>
      <Show when={view() === "datawindows"}><DataWindows /></Show>
      <Show when={view() === "dwDetail"}><DWDetail /></Show>
      <Show when={view() === "diagrams"}><Diagrams /></Show>
      <Show when={view() === "queries"}><Queries /></Show>
      <Show when={view() === "search"}><Search /></Show>
      <Show when={view() === "explore"}><Explore /></Show>
    </Layout>
  );
}

function App() {
  return (
    <StoreProvider store={store} env={env}>
      <ViewRouter />
      <HealthCheck />
    </StoreProvider>
  );
}

const root = document.getElementById("app");
if (root) render(() => <App />, root);
