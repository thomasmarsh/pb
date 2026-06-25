// features/launch/reducer.ts — Thin launch orchestrator.
//
// Drives the application bootstrap flow: load .sra → seed globals → open main window.
// Delegates actual execution to the runtime reducer and window-manager reducer
// via returned effects (no interpreter duplication).

import { Effect } from "../../core/effect.js";
import type { Reducer } from "../../core/reducer.js";
import type { AstData } from "../../core/interpreter.js";

// ── Hardcoded bootstrap globals (simplified: skip INI / CONNECT / w_getxrisi) ──

const HARDCODED_GLOBALS: Record<string, unknown> = {
  gs_kodxrisi: "0001",
  gs_descxrisi: "Demo",
  gs_app_name: "OpenPay",
  gs_username: "admin",
  gs_version_number: "0.1.1b",
  gs_version_date: "22/12/2005",
  gs_dbver_req: "0.1.1",
  gs_copyright_year: "2005-2006",
  gs_serialnumber: "GPL",
  gs_country: "uk",
  gb_useperm: false,
  gs_kodapp: "openpay",
};

// ── State ─────────────────────────────────────────────────────────────────────

export interface LaunchState {
  status: "idle" | "loading" | "running" | "done" | "error";
  appName: string | null;
  globals: Record<string, unknown>;
  windowStack: string[];  // window names opened during this session
  error: string | null;
}

export const initialLaunchState: LaunchState = {
  status: "idle",
  appName: null,
  globals: {},
  windowStack: [],
  error: null,
};

// ── Actions ───────────────────────────────────────────────────────────────────

export type LaunchAction =
  | { tag: "load-app"; sraName: string }
  | { tag: "app-loaded"; ast: AstData }
  | { tag: "run-app-open"; windowName: string }
  | { tag: "window-ast-loaded"; windowName: string; ast: AstData }
  | { tag: "close-window"; windowName: string }
  | { tag: "launch-error"; message: string };

// ── Env ───────────────────────────────────────────────────────────────────────

export interface LaunchEnv {
  getObjectAst(name: string): Effect<AstData>;
}

// ── Reducer ───────────────────────────────────────────────────────────────────

function reduce(
  draft: LaunchState,
  action: LaunchAction,
  env: LaunchEnv,
): Effect<LaunchAction> | null {
  switch (action.tag) {
    case "load-app":
      draft.status = "loading";
      draft.appName = action.sraName;
      draft.error = null;
      return env
        .getObjectAst(action.sraName)
        .map((ast): LaunchAction => ({ tag: "app-loaded", ast }))
        .catch((e): LaunchAction => ({ tag: "launch-error", message: String(e) }));

    case "app-loaded":
      // Seed globals from hardcoded defaults (simplified bootstrap).
      draft.globals = { ...HARDCODED_GLOBALS };
      draft.status = "running";
      // Extract variable names from .sra to confirm globals are known.
      if (action.ast.variables) {
        for (const v of action.ast.variables) {
          if (!(v.name in draft.globals) && v.scope === "global") {
            // Declare the variable but don't overwrite hardcoded values.
            draft.globals[v.name] = undefined;
          }
        }
      }
      // Proceed to open the main window (skip .sra open event body).
      // 132e target: non-MDI window; w_app (MDI frame) is out of scope until 133+.
      return Effect.send({ tag: "run-app-open", windowName: "w_misth_final_form_create" });

    case "run-app-open":
      return env
        .getObjectAst(action.windowName)
        .map((ast): LaunchAction => ({
          tag: "window-ast-loaded",
          windowName: action.windowName,
          ast,
        }))
        .catch((e): LaunchAction => ({ tag: "launch-error", message: String(e) }));

    case "window-ast-loaded":
      draft.windowStack.push(action.windowName);
      draft.status = "done";
      // Dispatch to window-manager and runtime via AppAction wrappers.
      // These are returned as LaunchAction effects that the app reducer will
      // intercept and forward. But since LaunchAction doesn't know about
      // AppAction, we use Effect.none() here — the app reducer handles
      // window-ast-loaded by also dispatching the side-effects.
      // See app/reducer.ts: handleLaunchCascade().
      return null;

    case "close-window":
      draft.windowStack = draft.windowStack.filter(n => n !== action.windowName);
      if (draft.windowStack.length === 0) draft.status = "done";
      return null;

    case "launch-error":
      draft.status = "error";
      draft.error = action.message;
      return null;
  }
}

export const launchReducer: Reducer<LaunchState, LaunchAction, LaunchEnv> = reduce;
