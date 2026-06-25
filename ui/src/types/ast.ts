// Manually maintained TypeScript types for the PB AST wire format.
// Field names and tag strings must match PB.Pipeline.Serialise (customOptions
// strips camelCase prefixes, e.g. callArgs → args, ifThen → then).

// ── Expr layer ───────────────────────────────────────────────────────────────

export interface LvSegment {
  name: string;
  subscript: string[] | null;
}

export interface Lvalue {
  segments: LvSegment[];
}

export type BinOp =
  | "BopAdd" | "BopSub" | "BopMul" | "BopDiv" | "BopPow"
  | "BopEq"  | "BopNe"  | "BopLt"  | "BopGt"  | "BopLe" | "BopGe"
  | "BopAnd" | "BopOr"  | "BopXor";

export type DispatchMode = "DmPost" | "DmTrigger" | "DmSync";

export interface DispatchExpr {
  object: Lvalue | null;
  mode: DispatchMode;
  dynamic: boolean;
  event: boolean;
  name: string;
  args: string[][];
}

export type Expr =
  | { tag: "ExBool";        contents: boolean }
  | { tag: "ExInt";         contents: string }
  | { tag: "ExReal";        contents: string }
  | { tag: "ExStr";         contents: string }
  | { tag: "ExDate";        contents: string }
  | { tag: "ExTime";        contents: string }
  | { tag: "ExNull" }
  | { tag: "ExEnum";        contents: string }
  | { tag: "ExLvalue";      contents: Lvalue }
  | { tag: "ExCall";        callee: Lvalue; args: string[][] }
  | { tag: "ExMethodCall";  receiver: Expr; method: string; args: string[][] }
  | { tag: "ExDispatch";    contents: DispatchExpr }
  | { tag: "ExCreate";      contents: string }
  | { tag: "ExCreateUsing"; contents: Expr }
  | { tag: "ExArray";       contents: Expr[] }
  | { tag: "ExBinOp";       lhs: Expr; op: BinOp; rhs: Expr }
  | { tag: "ExNot";         contents: Expr }
  | { tag: "ExNeg";         contents: Expr }
  | { tag: "ExHostVar";     contents: Lvalue }
  | { tag: "ExRaw";         contents: string[] };

export type PbType =
  | { tag: "PtPrimitive";   contents: string }
  | { tag: "PtUserDefined"; contents: string }
  | { tag: "PtAny" }
  | { tag: "PtDecimalPrec"; contents: number };

// ── Located wrapper ──────────────────────────────────────────────────────────

export interface Located<T> {
  line: number;
  node: T;
}

// ── BodyStmt layer ───────────────────────────────────────────────────────────

export type AugOp = "AugAdd" | "AugSub" | "AugMul" | "AugDiv";

export interface PbCall {
  ancestor: string;
  event: string;
}

export interface ElseIf {
  cond: Expr;
  body: Located<BodyStmt>[];
}

export interface IfStmt {
  cond: Expr;
  then: Located<BodyStmt>[];
  elseIfs: ElseIf[];
  else: Located<BodyStmt>[] | null;
}

export interface ForStmt {
  var: Lvalue;
  from: Expr;
  to: Expr;
  step: Expr | null;
  body: Located<BodyStmt>[];
}

export type DoCondition =
  | { tag: "DoWhile"; contents: Expr }
  | { tag: "DoUntil"; contents: Expr };

export interface DoStmt {
  cond: DoCondition | null;
  body: Located<BodyStmt>[];
  loop: DoCondition | null;
}

export interface CaseClause {
  expr: string[] | null;
  body: Located<BodyStmt>[];
}

export interface ChooseStmt {
  expr: Expr;
  clauses: CaseClause[];
}

export type BodyStmt =
  | { tag: "BsLocalVar";    mods: string[]; type: PbType; name: string; init: Expr | null }
  | { tag: "BsAssign";      contents: [Lvalue, Expr] }
  | { tag: "BsAugAssign";   contents: [string[], AugOp, string[]] }
  | { tag: "BsInc";         contents: string[] }
  | { tag: "BsDec";         contents: string[] }
  | { tag: "BsCall";        contents: Expr }
  | { tag: "BsPbCall";      contents: PbCall }
  | { tag: "BsReturn";      contents: Expr | null }
  | { tag: "BsIf";          contents: IfStmt }
  | { tag: "BsFor";         contents: ForStmt }
  | { tag: "BsDo";          contents: DoStmt }
  | { tag: "BsChoose";      contents: ChooseStmt }
  | { tag: "BsExit" }
  | { tag: "BsContinue" }
  | { tag: "BsDestroy";     contents: Lvalue }
  | { tag: "BsAssignExpr";  contents: [Expr, Expr] }
  | { tag: "BsRaw";         contents: string };

// ── SourceFile layer ─────────────────────────────────────────────────────────

export type VarScope = "GlobalVars" | "TypeVars";

export interface TypeDecl {
  name: string;
  ancestor: string;
  within: string | null;
}

export interface GlobalInstance {
  type: string;
  name: string;
}

export interface VarDecl {
  modifiers: string[];
  type: string;
  name: string;
}

export interface FnSig {
  mods: string[];
  returnType: string;
  name: string;
  params: string;
  throws: string | null;
}

export interface SubSig {
  mods: string[];
  name: string;
  params: string;
  throws: string | null;
}

export interface EventSig {
  name: string;
  rawSig: string;
}

export type ProtoDecl =
  | { tag: "ProtoFn";  contents: FnSig }
  | { tag: "ProtoSub"; contents: SubSig }
  | { tag: "ProtoEv";  contents: EventSig };

export interface ForwardBlock {
  types: TypeDecl[];
  instances: GlobalInstance[];
}

export interface PrototypesBlock {
  decls: ProtoDecl[];
}

export interface VariablesBlock {
  scope: VarScope;
  decls: VarDecl[];
}

export interface TypeBlock {
  decl: TypeDecl;
  body: Located<BodyStmt>[];
}

export interface FunctionBlock {
  sig: FnSig;
  body: Located<BodyStmt>[];
}

export interface SubroutineBlock {
  sig: SubSig;
  body: Located<BodyStmt>[];
}

export interface EventBlock {
  sig: EventSig;
  owner: string | null;
  body: Located<BodyStmt>[];
}

export interface OnBlock {
  qualName: string;
  owner: string;
  event: string;
  body: Located<BodyStmt>[];
}

export interface SrFile {
  headers: string[];
  forward: ForwardBlock | null;
  prototypes: PrototypesBlock | null;
  variables: VariablesBlock | null;
  globalInstances: GlobalInstance[];
  typeBlocks: TypeBlock[];
  onBlocks: OnBlock[];
  events: EventBlock[];
  functions: FunctionBlock[];
  subroutines: SubroutineBlock[];
}

// ── DataWindow layer ─────────────────────────────────────────────────────────

export type DwBandKind =
  | { tag: "BkHeader" }
  | { tag: "BkDetail" }
  | { tag: "BkFooter" }
  | { tag: "BkSummary" }
  | { tag: "BkBackground" }
  | { tag: "BkForeground" }
  | { tag: "BkGroupHeader";  contents: number }
  | { tag: "BkGroupTrailer"; contents: number }
  | { tag: "BkTreeLevel";    contents: number };

export interface DwWhereClause {
  exp1: string;
  op: string;
  exp2: string;
  logic: string | null;
}

export interface DwArgument {
  name: string;
  type: string;
}

export interface DwRetrieve {
  version: number;
  tables: string[];
  columns: string[];
  arguments: DwArgument[];
  where: DwWhereClause[];
}

export type DwRetrieveOrRaw =
  | { tag: "DwRetrieveOk";  contents: DwRetrieve }
  | { tag: "DwRetrieveRaw"; contents: string };

export interface DwColumn {
  name: string;
  type: string;
  dbName: string | null;
  update: boolean;
  key: boolean;
  updateWhere: boolean;
  dddwName: string | null;
  attrs: Record<string, string | undefined>;
}

export interface DwObjectAttrs {
  attrs: Record<string, string | undefined>;
}

export interface DwTable {
  columns: DwColumn[];
  retrieve: DwRetrieveOrRaw | null;
  update: string | null;
  updateWhere: number | null;
  arguments: DwArgument[];
}

export interface DwBand {
  kind: DwBandKind;
  height: number | null;
  color: string | null;
  autoSize: boolean;
  attrs: Record<string, string | undefined>;
}

export interface DwGroup {
  level: number;
  headerHeight: number | null;
  trailerHeight: number | null;
  by: string[];
  newPage: boolean;
  attrs: Record<string, string | undefined>;
}

export interface DwControl {
  type: string;
  name: string | null;
  band: DwBandKind | null;
  id: number | null;
  x: number | null;
  y: number | null;
  width: number | null;
  height: number | null;
  visible: boolean | null;
  expression: string | null;
  parsedExpression: Expr | null;
  format: string | null;
  parsedFormat: Expr | null;
  tabSeq: number | null;
  attrs: Record<string, string | undefined>;
}

export interface DwUnknownBlock {
  keyword: string;
  attrs: Record<string, string | undefined>;
}

export interface DataWindowFile {
  release: number;
  object: DwObjectAttrs;
  table: DwTable | null;
  bands: DwBand[];
  groups: DwGroup[];
  controls: DwControl[];
  unknowns: DwUnknownBlock[];
  meta: Record<string, Record<string, string | undefined> | undefined>;
}
