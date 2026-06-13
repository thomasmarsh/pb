// context.tsx — Provides store + env to all SolidJS components.

import { createContext, useContext, type ParentProps } from "solid-js";
import type { Store } from "./store.js";
import type { Env } from "./core.js";

interface StoreContextValue {
  store: Store;
  env: Env;
}

const StoreCtx = createContext<StoreContextValue>();

export function useStore(): Store {
  const ctx = useContext(StoreCtx);
  if (!ctx) throw new Error("useStore must be used within StoreProvider");
  return ctx.store;
}

export function useEnv(): Env {
  const ctx = useContext(StoreCtx);
  if (!ctx) throw new Error("useEnv must be used within StoreProvider");
  return ctx.env;
}

export function StoreProvider(props: ParentProps<{ store: Store; env: Env }>) {
  return (
    <StoreCtx.Provider value={{ store: props.store, env: props.env }}>
      {props.children}
    </StoreCtx.Provider>
  );
}
