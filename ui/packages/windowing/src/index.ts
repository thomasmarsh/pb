// @pb/windowing — MDI desktop + PB execution loop reducers and types.

// Window manager
export type { WindowManagerState, WindowManagerAction, ManagedWindow } from "./manager/types.js";
export { initialWindowManagerState } from "./manager/initial.js";
export { windowManagerReducer } from "./manager/reducer.js";

// Runtime (CPS execution loop)
export { runtimeReducer, initialRuntimeState, PB_GLOBALS } from "./runner/reducer.js";
export type { RuntimeState, RuntimeAction, RuntimeEnv } from "./runner/reducer.js";

// Launch (bootstrap flow)
export { launchReducer, initialLaunchState } from "./launch/reducer.js";
export type { LaunchState, LaunchAction, LaunchEnv } from "./launch/reducer.js";
