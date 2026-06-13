// App.tsx — SolidJS entry point with Router.

import { render } from "solid-js/web";
import { Router, Route } from "@solidjs/router";
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

const env = { api: createApiClient() };
const store = createStoreAdapter(initialState(), reducer, env);

store.dispatch({ type: "STATS_LOAD" });

function App() {
  return (
    <StoreProvider store={store} env={env}>
      <Router root={Layout}>
        <Route path="/" component={Dashboard} />
        <Route path="/objects" component={Objects} />
        <Route path="/objects/:name" component={ObjectDetail} />
        <Route path="/procedures/:object/:proc" component={ProcedureDetail} />
        <Route path="/datawindows" component={DataWindows} />
        <Route path="/datawindows/:name" component={DWDetail} />
        <Route path="/diagrams" component={Diagrams} />
        <Route path="/queries" component={Queries} />
        <Route path="/search" component={Search} />
      </Router>
    </StoreProvider>
  );
}

const root = document.getElementById("app");
if (root) render(() => <App />, root);
