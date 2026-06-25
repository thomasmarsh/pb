// @pb/interpreter — PB language runtime: CPS engine, evaluator, renderer.
// Zero SolidJS dependency. Pure TypeScript.

// AST wire types
export type {
  BodyStmt, BinOp, CaseClause, ChooseStmt, DataWindowFile,
  DispatchExpr, DispatchMode, DoCondition, DoStmt, DwArgument, DwBand,
  DwBandKind, DwColumn, DwControl, DwGroup, DwObjectAttrs, DwRetrieve,
  DwRetrieveOrRaw, DwTable, DwUnknownBlock, ElseIf, EventBlock, EventSig,
  Expr, ForStmt, ForwardBlock, FunctionBlock, GlobalInstance, IfStmt,
  Located, Lvalue, LvSegment, OnBlock, PbCall, PbType,
  ProtoDecl, PrototypesBlock, SrFile, SubSig, SubroutineBlock, TypeBlock,
  TypeDecl, VarDecl, VarScope, VariablesBlock,
} from "./types/ast.js";

// Interpreter types
export type { AstData, DWRow, GlobalVarDecl, ProcEntry } from "./interpreter.js";

// CPS engine
export type { CpsEnv, CpsGraph, CpsNode } from "./cps/types.js";
export type { CpsResumeAction } from "./cps/runner.js";
export { step } from "./cps/runner.js";
export { loadCpsGraph } from "./cps/load.js";
export { evalExpr, evalTokenArg } from "./cps/expr.js";
export type { VarEnv } from "./cps/var-env.js";
export { makeVarEnv, readVar, writeVar, declareLocal, pushFrame, popFrame, flattenVarEnv } from "./cps/var-env.js";

// Runtime built-ins
export type { PBFunction } from "./runtime.js";
export { PB_BUILTINS } from "./runtime.js";

// Layout and rendering
export type { WindowLayout, LayoutControl } from "./layout.js";
export { extractLayout } from "./layout.js";
export type { DwBandLayout, DwControlLayout, DwLayout } from "./dwLayout.js";
export { extractDwLayout } from "./dwLayout.js";
export type { RenderedWindow, RenderedControl, RenderedDW } from "./render-window.js";
export { renderWindow } from "./render-window.js";
