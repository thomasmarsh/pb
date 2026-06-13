// App.tsx — SolidJS entry point. Pure TCA: store owns navigation.

import { render, Show } from "solid-js/web";
import { StoreProvider } from "./context.js";
import { createStoreAdapter } from "./store.js";
import { initialState, reducer } from "./core.js";
import { createApiClient } from "./api-client.js";
import { Layout } from "./components/Layout.js";
import { Dashboard } from "./components/Dashboard.js";
import { Objects, ObjectDetail } from "./components/Objects.js";
import { ProcedureDetail } from "./components/ProcedureDetail.js";
import { DataWindows, DWDetail } from "./components/DataWindows.js";
import { Diagrams } from "./components/Diagrams.js";
import { Queries } from "./components/Queries.js";
import { Search } from "./components/Search.js";
import { useStore } from "./context.js";

const env = { api: createApiClient() };
const store = createStoreAdapter(initialState(), reducer, env);

store.dispatch({ type: "STATS_LOAD" });

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
    </Layout>
  );
}

function App() {
  return (
    <StoreProvider store={store} env={env}>
      <ViewRouter />
    </StoreProvider>
  );
}

const root = document.getElementById("app");
if (root) render(() => <App />, root);
