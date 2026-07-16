// highlight.ts — PowerScript syntax highlighter.

const PS_KEYWORDS = new Set([
  "and","or","not","xor","if","then","else","elseif","end","choose","case",
  "for","to","step","next","do","while","loop","until","exit","continue",
  "try","catch","finally","throw","throws","return","halt","goto",
  "call","post","trigger","dynamic","with","close","open","create","destroy","using",
  "set","values","where","from","into","of","is","null","as","on","in",
  "select","selectblob","insert","update","updateblob","delete",
  "commit","rollback","connect","disconnect","declare","cursor","procedure",
  "execute","fetch","prepare","describe","immediate","prior","first","last",
  "between","like","exists","having","group","order","union","all","distinct",
  "asc","desc","shared","system","readonly","constant","ref","static",
  "indirect","global","rpcfunc","alias","library","external","native",
  "namespace","enumerated","intrinsic","autoinstantiate","prototype","forward",
  "type","within","true","false",
  "public","private","protected",
  "privateread","privatewrite","protectedread","protectedwrite",
  "systemread","systemwrite",
]);

const PS_TYPES = new Set([
  "any","blob","boolean","byte","char","character",
  "date","datetime","dec","decimal","double",
  "int","integer","long","longlong","longptr","real","string","time",
  "uint","ulong","unsignedint","unsignedinteger","unsignedlong",
  "transaction","error","message","application",
  "window","menu","datawindow","datastore","datawindowchild",
  "nonvisualobject","function_object","powerobject",
  "oleobject","olecontrol",
  "treeview","listview","tab","graph","groupbox",
  "commandbutton","checkbox","radiobutton",
  "singlelineedit","multilineedit","editmask","richtextedit",
  "statictext","picture","line","rectangle","roundrectangle","oval",
  "hprogressbar","vprogressbar","hscrollbar","vscrollbar",
  "httpclient","restclient","inet",
  "jsonparser","jsongenerator","jsonpackage",
  "pipeline","timing","structure","environment",
  "coderobject","compressorobject","crypterobject",
  "errorlogging","exception",
  "profilercall","profileclass","profileline","profileroutine",
]);

const PS_BUILTINS = new Set([
  "abs","acos","asin","atan","ceiling","cos","exp","fact",
  "log","logten","max","min","mod","pi","rand","randomize","round","sign",
  "sin","sqrt","tan","truncate",
  "string","integer","long","double","dec","date","time","now","today",
  "year","month","day","hour","minute","second",
  "upper","lower","trim","len","pos","right","left","mid","replace",
  "isnull","isvalid","messagebox","triggerevent",
  "classname","upperbound","lowerbound",
  "fileopen","fileclose","fileread","filewrite","fileseek",
  "filelength","fileexists",
  "setnull","setattribute","getitem",
  "retrieve","update","insertrow","deleterow",
  "setrow","getrow","rowcount",
  "accepttext","reset","filter","print","pagesetup","preview",
  "sharedata","settransobject","dataobject",
]);

const PS_PRONOUNS = new Set([
  "this","parent","super","parentwindow",
  "sqlca","sqlda","sqlsa","error","message",
]);

const COLORS = {
  keyword: "#c586c0",
  type: "#4ec9b0",
  builtin: "#dcdcaa",
  string: "#ce9178",
  comment: "#6a9955",
  number: "#b5cea8",
  pronoun: "#569cd6",
  enum: "#4fc1ff",
  operator: "#d4d4d4",
};

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function highlightLine(
  line: string,
  startInBlockComment: boolean = false,
): { html: string; inBlockComment: boolean } {
  let result = "";
  let i = 0;
  const len = line.length;

  if (startInBlockComment) {
    const end = line.indexOf("*/");
    if (end === -1) {
      return { html: `<span style="color:${COLORS.comment}">${escapeHtml(line)}</span>`, inBlockComment: true };
    }
    result += `<span style="color:${COLORS.comment}">${escapeHtml(line.slice(0, end + 2))}</span>`;
    i = end + 2;
  }

  while (i < len) {
    const ch = line[i]!;
    const next = i + 1 < len ? line[i + 1] : undefined;
    // Line comment
    if (ch === "/" && next === "/") {
      return { html: result + `<span style="color:${COLORS.comment}">${escapeHtml(line.slice(i))}</span>`, inBlockComment: false };
    }
    // Block comment start — may or may not close on this same line.
    if (ch === "/" && next === "*") {
      const end = line.indexOf("*/", i + 2);
      if (end !== -1) {
        result += `<span style="color:${COLORS.comment}">${escapeHtml(line.slice(i, end + 2))}</span>`;
        i = end + 2;
        continue;
      } else {
        return { html: result + `<span style="color:${COLORS.comment}">${escapeHtml(line.slice(i))}</span>`, inBlockComment: true };
      }
    }
    // Double-quoted string
    if (ch === '"') {
      let j = i + 1;
      while (j < len) {
        const cj = line[j]!;
        const nj = j + 1 < len ? line[j + 1] : undefined;
        if (cj === "~" && nj !== undefined) { j += 2; continue; }
        if (cj === '"') { j++; break; }
        j++;
      }
      result += `<span style="color:${COLORS.string}">${escapeHtml(line.slice(i, j))}</span>`;
      i = j;
      continue;
    }
    // Single-quoted string
    if (ch === "'") {
      let j = i + 1;
      while (j < len) {
        const cj = line[j]!;
        const nj = j + 1 < len ? line[j + 1] : undefined;
        if (cj === "~" && nj !== undefined) { j += 2; continue; }
        if (cj === "'") { j++; break; }
        j++;
      }
      result += `<span style="color:${COLORS.string}">${escapeHtml(line.slice(i, j))}</span>`;
      i = j;
      continue;
    }
    // Tilde-quoted string (PB-specific)
    if (ch === "~" && next === '"') {
      let j = i + 2;
      while (j < len) {
        const cj = line[j]!;
        const nj = j + 1 < len ? line[j + 1] : undefined;
        if (cj === "~" && nj === "~") { j += 2; continue; }
        if (cj === "~" && nj === '"') { j += 2; break; }
        j++;
      }
      result += `<span style="color:${COLORS.string}">${escapeHtml(line.slice(i, j))}</span>`;
      i = j;
      continue;
    }
    // Numbers
    if (/[0-9]/.test(ch) && (i === 0 || /[\s(+\-*/^=<>,]/.test(line[i - 1]!))) {
      let j = i;
      while (j < len && /[0-9._eE+-]/.test(line[j]!)) j++;
      result += `<span style="color:${COLORS.number}">${escapeHtml(line.slice(i, j))}</span>`;
      i = j;
      continue;
    }
    // Enum (ident ending with !) or identifiers
    if (/[A-Za-z_]/.test(ch)) {
      let j = i;
      while (j < len && /[\w$#%\-]/.test(line[j]!)) j++;
      const word = line.slice(i, j);
      const lower = word.toLowerCase();
      // Check for enum (ends with !)
      if (j < len && line[j] === "!") {
        result += `<span style="color:${COLORS.enum}">${escapeHtml(word)}!</span>`;
        i = j + 1;
        continue;
      }
      let color: string | null = null;
      if (PS_KEYWORDS.has(lower)) color = COLORS.keyword;
      else if (PS_TYPES.has(lower)) color = COLORS.type;
      else if (PS_BUILTINS.has(lower)) color = COLORS.builtin;
      else if (PS_PRONOUNS.has(lower)) color = COLORS.pronoun;
      if (color) {
        result += `<span style="color:${color}">${escapeHtml(word)}</span>`;
      } else {
        result += escapeHtml(word);
      }
      i = j;
      continue;
    }
    // Operators
    if (/[<>=+\-*/^]/.test(ch)) {
      let j = i + 1;
      if (i + 1 < len && /=<>>/.test(line[i + 1]!)) j++;
      result += `<span style="color:${COLORS.operator}">${escapeHtml(line.slice(i, j))}</span>`;
      i = j;
      continue;
    }
    // Default
    result += escapeHtml(ch);
    i++;
  }
  return { html: result, inBlockComment: false };
}

export function highlightPowerScript(code: string): string {
  let inBlockComment = false;
  return code
    .split("\n")
    .map(line => {
      const { html, inBlockComment: next } = highlightLine(line, inBlockComment);
      inBlockComment = next;
      return html;
    })
    .join("\n");
}

const CHUNK_SIZE = 200;

export function highlightPowerScriptChunked(
  code: string,
  onChunk: (partial: string, done: boolean) => void,
): void {
  const lines = code.split("\n");
  let i = 0;
  let inBlockComment = false;
  function nextChunk() {
    const end = Math.min(i + CHUNK_SIZE, lines.length);
    const chunk = lines
      .slice(i, end)
      .map(line => {
        const { html, inBlockComment: next } = highlightLine(line, inBlockComment);
        inBlockComment = next;
        return html;
      })
      .join("\n");
    i = end;
    if (i >= lines.length) {
      onChunk(chunk, true);
    } else {
      onChunk(chunk, false);
      setTimeout(nextChunk, 0);
    }
  }
  nextChunk();
}

export function highlightAsync(code: string): Promise<string> {
  return new Promise((resolve) => {
    let result = "";
    highlightPowerScriptChunked(code, (chunk, done) => {
      result += chunk;
      if (done) resolve(result);
    });
  });
}

// ── SQL highlighting via highlight.js ────────────────────────────────────────

import hljs from "highlight.js/lib/core";
import sql from "highlight.js/lib/languages/sql";
hljs.registerLanguage("sql", sql);

export function highlightSql(code: string): string {
  return hljs.highlight(code, { language: "sql" }).value;
}

// Keyword set for identifier linking (used by source viewer)
export const PB_KEYWORDS = new Set([
  ...PS_KEYWORDS,
  ...PS_PRONOUNS,
  "function","subroutine","event","on",
]);
