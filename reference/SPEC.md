# PowerBuilder Parser — Implementation Reference Specification

Synthesized from `reference/code/vsc-powersyntax/` (battle-tested TypeScript implementation)
and `reference/code/vsc-powersyntax/syntaxes/powerbuilder.tmLanguage.json` (authoritative grammar).

All regex patterns are given in their raw string form (PCRE-compatible, case-insensitive unless noted).

---

## 1. File Extensions and Object Types

| Extension | Object type      | Parser path     |
| --------- | ---------------- | --------------- |
| `.srs`    | Window           | PowerScript     |
| `.sru`    | UserObject       | PowerScript     |
| `.srf`    | Function         | PowerScript     |
| `.srm`    | Menu             | PowerScript     |
| `.srw`    | Application      | PowerScript     |
| `.sra`    | Structure        | PowerScript     |
| `.sro`    | Object (generic) | PowerScript     |
| `.srd`    | DataWindow       | DataWindow (§7) |
| `.srp`    | Pipeline         | PowerScript     |
| `.srj`    | Query            | PowerScript     |
| `.srq`    | Query variant    | PowerScript     |

`.srd` files are a completely different syntax from all others and must use a separate parser path.

---

## 2. Lexical Specification

### 2.1 Identifiers

```
IdentStart  ::= [A-Za-z_]
IdentCont   ::= [A-Za-z0-9_$#%\-]
Identifier  ::= IdentStart IdentCont*
```

Hyphens (`-`) are valid in identifier bodies. `$`, `#`, `%` are valid in body positions only (per official docs). The entire language is **case-insensitive**; normalize to lowercase for all comparisons. Maximum identifier length: **40 characters**.

**Corpus verdict (2025-06-06):** No identifiers starting with `$`, `#`, or `%` found in the corpus. The `$PBExportHeader$` lines in `.srd` files are file-format headers (§2.11), not PowerScript identifiers. `IdentStart` is correctly restricted to `[A-Za-z_]`.

For type references (ancestor names, `within` targets, type annotations), backtick is additionally allowed:

```
TypeRef     ::= [A-Za-z_$#%][A-Za-z0-9_$#%\-`]*
```

**Variable declaration ambiguity:** when parsing `Type Name`, check that `Type` is not itself a keyword. The reference implementation's `matchVariableDeclaration` does `if PB_KEYWORDS.has(type.toLowerCase()) → null`.

### 2.2 Keywords

All keywords are case-insensitive. Two-word keywords must be tried before single-word keywords to avoid partial matches.

**Two-word keywords (must be matched as atomic units):**

```
choose case     end if          end choose      end try
end function    end subroutine  end event       end on
end type        end variables   end prototypes  end forward
forward prototypes    type variables    for to    for to step
```

**Single-word keywords:**

```
_debug      alias       and         any         autoinstantiate
call        case        catch       choose      close
commit      connect     constant    continue    create
cursor      declare     delete      describe    descriptor
destroy     disconnect  do          dynamic     else
elseif      end         enumerated  event       execute
exit        external    false       fetch       finally
first       for         forward     from        function
get         global      goto        halt        if
immediate   indirect    insert      into        intrinsic
is          it          last        library     loop
namespace   native      next        not         null
of          on          open        or          post
prepare     prior       private     privateread privatewrite
procedure   protected   protectedread protectedwrite prototypes
public      readonly    ref         return      rollback
rpcfunc     select      selectblob  set         shared
static      step        subroutine  system      systemread
systemwrite then        throw       throws      to
trigger     true        try         type        until
update      updateblob  using       variables   while
with        within      xor
```

**Pronoun / context keywords** (resolve as variable references, not declarations):

```
this    super   parent  parentwindow
sqlca   sqlsa   sqlda   error   message
```

### 2.3 Access and Storage Modifiers

```
AccessModifier ::= public | private | protected
                 | privateread | privatewrite
                 | protectedread | protectedwrite
                 | systemread | systemwrite
                 | global | shared

StorageModifier ::= readonly | constant | ref | indirect | static

FuncModifier    ::= rpcfunc | external | native
```

A modifier prefix for declarations matches zero-or-more of any of the above:

```
AnyModifier ::= (AccessModifier | StorageModifier | FuncModifier)\s+)*
```

### 2.4 Primitive Types

The complete authoritative list (lowercase; ~230 entries in the generated catalog):

```
-- Scalar primitives
any blob boolean byte char character
date datetime dec decimal double
int integer long longlong longptr
real string time uint ulong
unsignedint unsignedinteger unsignedlong

-- Transaction/system
transaction dynamicdescriptionarea dynamicstagingarea
error message application window menu datawindow
nonvisualobject function_object
```

See `reference/code/vsc-powersyntax/src/server/parsing/grammar.ts` → `PB_BUILTIN_TYPES` for the ~230-entry complete list including all visual controls, PDF objects, HTTP/REST classes, and reflection types.

### 2.5 String Literals

PB has two string delimiters. The escape character is `~` (not backslash).

**Named escapes** (from official docs):

| Escape  | Meaning                  |
|---------|--------------------------|
| `~n`    | Newline                  |
| `~t`    | Tab                      |
| `~r`    | Carriage return          |
| `~v`    | Vertical tab             |
| `~f`    | Form feed                |
| `~b`    | Backspace                |
| `~"`    | Double quote             |
| `~'`    | Single quote             |
| `~~`    | Literal tilde            |
| `~NNN`  | Decimal ASCII (000–255)  |
| `~hNN`  | Hex ASCII (01–FF)        |
| `~oNNN` | Octal ASCII (000–377)    |

`~.` (tilde then any other character) is also consumed as an escape (literal next character).

**Double-quoted strings** — span until the closing `"` on the **same or subsequent lines** (the tmLanguage grammar does not have an EOL anchor on end). No newline escaping is needed; the string continues across physical lines.

**Single-quoted strings** — terminate at the closing `'` OR at end-of-line (pattern: `'|(?=$)`). A single-quoted string that is not closed before EOL ends at EOL.

**DataWindow attribute strings** — use `~"` to embed a literal `"` inside a double-quoted attribute value (e.g., `retrieve="SELECT * FROM t WHERE name = ~"foo~""`).

**Nested string quoting** — when a string passes through multiple evaluation layers (e.g. the argument to `Modify`), each pass strips the outermost quotes and resolves tildes: two tildes become one, tilde-quote becomes the bare quote. Allows arbitrary nesting depth.

### 2.6 Numeric Literals

```
DateLiteral  ::= \d{4}-\d{2}-\d{2}
TimeLiteral  ::= \d{2}:\d{2}:\d{2}(\.\d+)?
FloatLiteral ::= [-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?
IntLiteral   ::= [-+]?\d+
```

Numeric literals may carry a leading `+` or `-` sign. Boundary checks are required: a digit adjacent to an identifier character is not a separate literal.

### 2.7 Enumerated Literals

An identifier immediately followed by `!` (no spaces):

```
EnumLiteral ::= Identifier !
```

Examples: `Black!`, `Primary!`, `True!`. The `!` is part of the token; it must not be tokenized as a separate operator.

### 2.8 Comments

**Line comment:** `//` to end-of-line.

**Block comment:** `/* ... */`. Can span multiple physical lines. The official language reference states block comments **can be nested**; however, the reference TypeScript implementation (`vsc-powersyntax`) treats them as non-nested by default (`nested: true` is an opt-in).

**Corpus verdict (2025-06-06):** No nested block comments (`/*` inside a `/* */` span) found in the corpus. Non-nested is confirmed correct; no change needed.

### 2.9 Operators

```
-- Comparison
<>   >=   <=   >   <

-- Augmented assignment
++   --   +=   -=   *=   /=

-- Assignment
=

-- Arithmetic
+   -   *   /   ^

-- Logical (keyword operators)
and   or   not   xor

-- Member access
.

-- Ancestor call separator
::

-- Continuation marker (only when trailing on the line)
&
```

### 2.10 Continuation Marker `&`

`&` is a continuation marker **only** when it is the last non-whitespace character on a physical line, after stripping comments. In any other position it is an arithmetic or logical-AND operator.

Pattern (applied to the stripped line, after comment removal):

```
&\s*$
```

`&` inside a comment is never a continuation.

**`&` inside string literals — official behaviour vs. implementation:** The official language reference documents that `&` may appear inside a string literal to continue it to the next physical line, with all whitespace before the `&` and at the start of the continuation line included verbatim in the string value:

```
s = "Eastern United States and&
      Eastern Canada"    // tab indent becomes part of the string
```

The reference TypeScript implementation classifies `&` as `String`-class when inside a string, so it does **not** trigger continuation. This implementation choice is safe in practice: PB documentation itself describes this as error-prone and recommends the close-and-reopen pattern instead (`"part one " & + "part two"`). Our masking algorithm follows the reference implementation (String-class `&` = not continuation).

**Corpus verdict (2025-06-06):** No instances of `&` as last character inside an open string literal found in the corpus. The reference implementation's behaviour is confirmed correct; `PB.Lexing.Mask` does not need to be revised.

### 2.11 File Headers

Some exported files begin with `$PBExport` header lines:

```
$PBExportHeader$<filename>
$PBExportComments$<text>
```

Or `HA$` prefix lines. These lines are metadata and must be consumed before the main parse begins. Pattern:

```
HeaderLine ::= \$ [^$\r\n]* \$ .*$
```

---

## 3. Preprocessor (Logical Lines)

The preprocessor is responsible for joining `&`-continued physical lines into logical lines and tracking source spans. This is the `normalizeText :: Text -> [LogicalLine]` layer in `PB.Pipeline.Preprocess`.

### 3.1 Character Mask

Before detecting `&` or `;`, classify every character position as one of:

```
Code | String | LineComment | BlockComment
```

Algorithm (per character, left-to-right, tracking state):

1. If inside a block comment: everything is `BlockComment` until `*/`.
2. If `//` is encountered and not inside a string: remainder of line is `LineComment`.
3. If `"` or `'` is encountered and not inside a comment: enter `String` mode for that delimiter.
   - Single-quoted strings: exit at matching `'` **or** at EOL.
   - Double-quoted strings: exit at matching `"` (may span lines).
4. `~` inside a string: the next character (or escape sequence) is also `String`.
5. Everything else is `Code`.

### 3.2 Continuation Detection

After masking, a physical line continues if and only if its rightmost `Code`-class character is `&`.

Implementation (mirrors `statementSplitter.ts`):

```
trimmed := stripTrailingWhitespace(strippedLine)  -- comment-stripped line
continues := trimmed.endsWith("&") AND that `&` is Code-class
if continues:
    accumulate trimmed[0..-2]  -- drop the `&`
    do not emit a logical line yet
else:
    emit LogicalLine{ text = joined, startLine, endLine }
```

### 3.3 Idempotence Invariant

```
normalize (normalize x) == normalize x
```

### 3.4 Monotonicity Invariant

```
llStartLine <= llEndLine   for all LogicalLine
```

### 3.5 No-Trailing-Ampersand Invariant

```
not ("&" `isSuffixOf` llText l)   for all LogicalLine l
```

### 3.6 Statement Splitting by `;`

After joining continuations, a single logical line may contain multiple statements separated by `;`. The `;` is only a statement separator when it is `Code`-class (not inside a string or comment).

This is the **next layer** after `normalizeText` and belongs in the lexer/grammar phase, not the preprocessor.

### 3.7 Conditional Compilation Directives

Conditional compilation lines begin with `#` or `$` followed by a directive keyword:

```
ConditionalDir ::= [#$]\s* (if | elseif | else | endif | end\s*if | define) \b
```

These must be handled before the main parse. Current scope: detect and strip them; evaluate-and-branch is a later phase.

---

## 4. SR\* File Structure (PowerScript Objects)

### 4.1 Top-Level Layout

A PowerScript SR\* file follows this section order (all sections optional):

```
[HeaderLines]
[forward
  [type Name from Ancestor [end type]]*
end forward]
// Note: the corpus shows two variants inside a forward block:
//   (a) bare header line:  type Name from Ancestor
//   (b) full block:        type Name from Ancestor / end type
// Variant (b) appears in .sru files exported by PowerBuilder; the parser
// must accept both.  The forward block never contains variable declarations
// between the type header and end type.

[forward prototypes | prototypes | type prototypes
  [function/event/subroutine prototypes]*
end prototypes]

[(global | type) variables
  [variable declarations]*
end variables]

[global type Name from Ancestor
  ...
end type]

[type Name from Ancestor [within Container]
  [variable declarations]*
end type]*

[on Object.Event
  ...
end on]*

[event Name [(params)] [returns Type]
  ...
end event]*

[[modifiers] function RetType Name(params) [throws Type]
  ...
end function]*

[[modifiers] subroutine Name(params) [throws Type]
  ...
end subroutine]*
```

### 4.2 Section Patterns (regex, case-insensitive, match at start-of-line)

```
ForwardStart      ::= ^\s*forward\b  (but NOT followed by \s+prototypes)
ForwardEnd        ::= ^\s*end\s+forward\b

FwdProtosStart    ::= ^\s*forward\s+prototypes\b
ProtosStart       ::= ^\s*(type\s+)?prototypes\b
ProtosEnd         ::= ^\s*end\s+prototypes\b

VarsStart         ::= ^\s*((\w+\s+)?type\s+variables|global\s+variables|variables)\b
VarsEnd           ::= ^\s*end\s+variables\b
```

### 4.3 Type Declaration Pattern

```
-- Global/root type (no within)
RootType    ::= ^\s*(global\s+)?type\s+(Ident)\s+from\s+(TypeRef)\s*$

-- Nested type (with optional within)
NestedType  ::= ^\s*(global|public|private|protected\s+)?type\s+(Ident)\s+from\s+(TypeRef)
                (\s+within\s+(TypeRef))?
```

Captures: `name`, `ancestor`, `container` (optional).

### 4.4 End-Type Pattern

```
EndType ::= ^\s*end\s+type\b
```

### 4.5 Function/Subroutine Declaration

```
FunctionDecl ::= ^\s*(AnyModifier)function\s+(TypeRef)\s+(Ident)\s*(?=\()
SubroutineDecl ::= ^\s*(AnyModifier)subroutine\s+(Ident)\s*(?=\()
```

Captures: `modifiers`, `returnType` (function only), `name`.

End markers:

```
EndFunction   ::= ^\s*end\s+function\b
EndSubroutine ::= ^\s*end\s+subroutine\b
```

### 4.6 Event Declaration

```
EventDecl ::= ^\s*(AnyModifier)event\s+(Ident(::Ident)?)\s*(?:;|\(|$)
```

End marker:

```
EndEvent ::= ^\s*end\s+event\b
```

### 4.7 On-Block Declaration

```
OnDecl ::= ^\s*on\s+(Ident(\.\s*Ident)+)\s*;?\s*$
```

The qualified name is `object.event` (e.g., `w_main.create`). The owner is everything before the last `.`.

End marker:

```
EndOn ::= ^\s*end\s+on\b
```

### 4.8 Variable Declaration

```
VarDecl ::= ^\s*(AnyModifier)(TypeRef(\{N\})?)\s+(Ident)
```

Captures: `modifiers`, `type` (with optional array bounds `{N}`), `name`.

**Guard:** if the matched `type` token is itself a keyword, the match is invalid (discard).

### 4.9 External Function Declaration

```
ExternalFn  ::= ^\s*(public|private|protected)?\s*function\s+(TypeRef)\s+(Ident)
                \s*\([^)]*\)\s+library\s+"([^"]+)"(\s+alias\s+for\s+"([^"]+)")?

ExternalSub ::= ^\s*(public|private|protected)?\s*subroutine\s+(Ident)
                \s*\([^)]*\)\s+library\s+"([^"]+)"(\s+alias\s+for\s+"([^"]+)")?

RpcFn       ::= (same as ExternalFn but with rpcfunc instead of library "...")
RpcSub      ::= (same as ExternalSub but with rpcfunc)
```

Library types: `.dll`, `.pbx`, `unknown`.

---

## 5. Control Flow Blocks

Control blocks are found inside function/event/subroutine bodies. They are recognized **after** continuation-joining and comment-stripping (work on logical lines).

### 5.1 Block Openers

```
IfOpen      ::= ^if\b.*\bthen\s*$    -- multi-line if must end with `then`
ForOpen     ::= ^for\b
DoOpen      ::= ^do\b
ChooseOpen  ::= ^choose\s+case\b
TryOpen     ::= ^try\b
```

### 5.2 Block Closers

```
EndIf       ::= ^end\s+if\b
Next        ::= ^next\b
Loop        ::= ^loop\b              -- closes do (loop while/loop until)
EndChoose   ::= ^end\s+choose\b
EndTry      ::= ^end\s+try\b
```

### 5.3 Mid-Block Keywords (do not close/open)

```
Else        ::= ^else\b
ElseIf      ::= ^elseif\b
Case        ::= ^case\b              -- inside choose case
Catch       ::= ^catch\b
Finally     ::= ^finally\b
```

### 5.4 Stack-Based Recognition

Use a stack of `(kind, startLine)`. On opener: push. On closer: pop until matching kind found, emit `ControlBlockRange{kind, startLine, endLine}`. Unclosed blocks at EOF: close against the last line (parse error, but do not crash).

### 5.5 Inline If (Single-Line)

`if cond then stmt [else stmt]` — no `end if`, no block opened.

Detection: `^if\b` but NOT ending with `\bthen\s*$` (i.e., the `then` is followed by code on the same line).

---

## 6. Embedded SQL

### 6.1 SQL Statement Openers

A line that begins with one of the following SQL keywords (case-insensitive, not followed immediately by `(`) opens a SQL region:

```
SELECT  SELECTBLOB  INSERT  UPDATE  UPDATEBLOB  DELETE
COMMIT  ROLLBACK    CONNECT DISCONNECT  DECLARE   CURSOR
EXECUTE FETCH       PREPARE DESCRIBE    DESCRIPTOR OPEN
CLOSE
```

Pattern: `^\s*(KEYWORD)\b(?!\s*\()`

The `(?!\s*\()` guard prevents matching `Close(win)` as a SQL CLOSE.

### 6.2 SQL Region Boundaries

- **Start:** the line matching the opener pattern (after masking).
- **End:** the physical line containing `;` (the SQL terminator).
- SQL spans multiple lines until `;` is found.

### 6.3 Host Variables

Inside a SQL region, `:identifier` (colon prefix) is a PowerScript host variable reference.

### 6.4 SQL-Embedded vs. Dynamic SQL

`EXECUTE IMMEDIATE` and `EXECUTE USING` are dynamic SQL. `EXECUTE procedurename` is a stored procedure call. The distinction matters for parameter binding analysis.

---

## 7. DataWindow Syntax (`.srd` Files)

DataWindow files are completely different from PowerScript. Do not run them through the PowerScript lexer.

**Corpus facts (262 `.srd` files, 2025-06-09):** control types seen: `text` (526×), `column` (453×), `compute` (228×), `line` (27×), `report` (17×), `groupbox` (11×), `button` (5×), `bitmap` (5×), `htmltable`, `htmlgen`. Top-level structural keywords: `datawindow`, `table`, `header`, `detail`, `footer`, `summary`, `htmltable`, `htmlgen`.

### 7.1 Overall Structure

After the standard `HA$PBExportHeader$` and `$PBExportComments$` header lines (§2.11),
a `.srd` file begins with a **release line**, then a sequence of **attribute blocks**:

```
release 9;
datawindow(attr=val attr="val" ...)
table(...)
header(...)
summary(...)
footer(...)
detail(...)
htmltable(...)
htmlgen(...)
<controltype>(band=<band> ...)
```

The `release` line declares the DataWindow format version. Observed values: `9`.

Each block is a keyword followed by parenthesis-balanced content. Blocks may span
multiple lines. The parser must use depth counting, not line scanning.

**Structural keyword disambiguation:** `column` appears both as a top-level control
block (has `band=` attribute) and as a sub-block attribute inside `table(...)` using
`column=(...)` notation (the `=` makes it an attribute-with-block-value, not a keyword).

### 7.2 Attribute Value Syntax

Two value forms:

- **Unquoted:** `attr=value` — value runs until whitespace or `)` at depth 0.
- **Quoted:** `attr="value"` — value runs until unescaped `"`. Inside quoted values, `~"` is the escape for a literal `"`.

A third form used only inside `table(...)`:

- **Sub-block:** `attr=(...)` — value is a nested paren-balanced block. Used for
  `column=(...)` and `arguments=(...)`. The content follows the same attribute syntax
  recursively.

### 7.3 `table(...)` Block

Contains column sub-blocks, a retrieve query, and optional argument declarations:

```
table(
  column=(type=<pbtype> updatewhereclause=yes name=<ident> dbname="<table.col>"
          [update=yes] [dddw.name=<ident>] ...)
  column=(...)
  retrieve="<SQL string>"
  arguments=(("argname", argtype) ...)
)
```

`column=()` uses the sub-block `attr=(...)` form — not a top-level control block.
Multiple `column=(...)` entries are allowed. The `retrieve` value is the full SQL
SELECT statement, which may use `PBSELECT(...)` DSL syntax or plain SQL.

#### PBSELECT DSL

The PowerBuilder visual query builder emits a `PBSELECT(...)` expression instead of
plain SQL for queries built via the IDE. Key elements:

```
retrieve="PBSELECT(
  VERSION(400)
  TABLE(NAME=~"tablename~")
  COLUMN(NAME=~"table.col~")
  JOIN(LEFT=~"t1.col~" OP=~"=~" RIGHT=~"t2.col~" [OUTER1=~"t1.col~"])
  WHERE(EXP1=~"(col~" OP=~"=~" EXP2=~":arg )~")
)
ARG(NAME=~"argname~" TYPE=string)"
```

`~"` inside the quoted retrieve string escapes a literal `"`. `ARG(...)` within the
retrieve string is part of the PBSELECT DSL, distinct from the top-level
`arguments=(...)` attribute (both may be present simultaneously — they carry the same
information in different formats for backwards compatibility).

### 7.4 Band Blocks

```
BandName ::= header | detail | footer | summary
```

Each band block is `bandname(height=N color="N" ...)`.

### 7.5 Control Blocks

Any word that is not a band name, `datawindow`, `table`, `htmltable`, `htmlgen`, or
`report` and is followed by `(` at the top level is a control block. Control blocks
carry a `band=<bandname>` attribute identifying which band they belong to.

**Corpus-observed control types:**

| Type       | Description                       |
|------------|-----------------------------------|
| `text`     | Static label or computed text     |
| `column`   | Data-bound column (with `band=`)  |
| `compute`  | Computed field                    |
| `line`     | Horizontal or vertical rule       |
| `report`   | Nested sub-report DataWindow      |
| `groupbox` | Visual group box                  |
| `button`   | Push button                       |
| `bitmap`   | Image/bitmap                      |

Key attributes present on most controls: `name`, `band`, `id`, `x`, `y`, `width`,
`height`, `visible`, `expression`.

**Disambiguation:** `column(band=detail ...)` (top-level control) vs.
`column=(type=char ...)` (sub-block inside `table`). The presence of `=` immediately
after the keyword is the distinguishing token.

### 7.6 Expression Values

Inside attribute `expression="..."` the value is a DataWindow expression. Other
attributes may have the form `"staticvalue~tdynexpr"` where `~t` separates a static
display value (before) from a dynamic expression (after).

### 7.7 `report(...)` Block

Nested DataWindow (sub-report). Key attribute: `dataobject="dw_name"`.

### 7.8 Retrieve Arguments

Two formats, often both present in the same file:

```
-- Format 1: top-level arguments attribute inside table(...)
arguments=(("argname", argtype) ...)

-- Format 2: ARG blocks embedded at the end of the retrieve string (PBSELECT DSL)
ARG(NAME=~"argname~" TYPE=argtype)
```

Format 1 is the canonical form. Format 2 appears inside the `retrieve="..."` value
when PBSELECT DSL is used. Treat them as redundant — parse both and reconcile if
they differ.

### 7.9 Parsing Strategy

Use a depth-tracking parenthesis scanner rather than a line-based parser:

```haskell
extractParenthesizedBlock :: [Text] -> Int -> (Text, Int)
-- returns (blockContent, endLineIndex)
-- tracks depth; enters at '(' on startLine, exits when depth returns to 0
```

**Top-level parse loop:**

1. Skip the `release N;` line.
2. Read the block keyword (up to `(`).
3. If keyword is `column` and the next non-whitespace char is `=`, this is a
   `table` sub-block attribute, not a top-level control. (This case only arises
   inside `table(...)` content — the top-level loop will never see a bare
   `column=(...)` because it is always consumed as part of `table(...)` content.)
4. Call `extractParenthesizedBlock` to collect the block body.
5. Dispatch to the appropriate attribute extractor by keyword.

**Quote handling inside quoted attribute values:** when scanning for the closing `"`,
the sequence `~"` is not a close — skip both characters and continue. The `~"` escape
is the only relevant escape inside DataWindow quoted values (unlike PowerScript which
has a full `~x` escape set).

---

## 8. Code Masking Algorithm

Used by all later phases to neutralize strings and comments before analysis. Preserves character positions (replaces masked chars with spaces). Preserves newline characters.

### 8.1 Single-Line Mask (fast path for most uses)

```
state = Code
for each char c:
  if state == InString(delim):
    if c == delim → emit delim; state = Code
    else           → emit ' '
  elif c == '//' → emit spaces to EOL; break
  elif c == '"' or '\'' → emit c; state = InString(c)
  else → emit c
```

Note: single-line mask does **not** handle block comments. Use document-level mask for those.

### 8.2 Document-Level Mask (handles block comments)

```
state = Code; blockDepth = 0; inStr = null
for each char c:
  preserve '\n', '\r' always
  if blockDepth > 0:
    if c=='/' and next=='*' and nested → blockDepth++; emit '  '; skip 2
    if c=='*' and next=='/'           → blockDepth--; emit '  '; skip 2
    else                              → emit ' '
  elif inStr != null:
    if c == inStr → emit c; inStr = null
    else          → emit ' '
    -- single-quoted: also exit at '\n'
  elif c=='/' and next=='/' → emit spaces to EOL
  elif c=='/' and next=='*' → blockDepth++; emit '  '; skip 2
  elif c=='"' or c=='\'' → inStr = c; emit c
  else → emit c
```

### 8.3 PB Escape in Strings

Inside a PB string, `~` is the escape character. The masked form should consume the full escape sequence as `String`-class:

- `~oNNN` (4 chars)
- `~hNN` (3 chars)
- `~.` (2 chars)
- `~` alone at EOL (1 char, treat as String)

---

## 9. Statement Splitter

Operates on logical lines (after `normalizeText`). Produces a list of `LogicalStatement`.

### 9.1 Algorithm

```
for each LogicalLine (after &-joining):
  stripped = maskLine(line.text)
  if stripped has Code-class ';':
    split at each Code ';'; emit one LogicalStatement per segment
  else:
    emit the whole line as one LogicalStatement
```

### 9.2 LogicalStatement Type

```haskell
data LogicalStatement = LogicalStatement
  { lsText      :: Text    -- joined, comment-stripped text
  , lsStartLine :: Int
  , lsEndLine   :: Int
  , lsRawLines  :: [Text]  -- original physical lines
  }
```

---

## 10. Lexer Token Taxonomy

Derived from `powerbuilder.tmLanguage.json` scope names — use these as the canonical token kinds for our AST.

| Token kind          | Pattern / note                                    |
| ------------------- | ------------------------------------------------- |
| `TkHeaderLine`      | `$...$...` at file start                          |
| `TkLineComment`     | `//` to EOL                                       |
| `TkBlockComment`    | `/* ... */`                                       |
| `TkStringDouble`    | `"..."` with `~` escapes                          |
| `TkStringSingle`    | `'...'` terminates at EOL                         |
| `TkBoolTrue`        | `true` (keyword)                                  |
| `TkBoolFalse`       | `false` (keyword)                                 |
| `TkNull`            | `null` (keyword)                                  |
| `TkDateLiteral`     | `YYYY-MM-DD`                                      |
| `TkTimeLiteral`     | `HH:MM:SS[.frac]`                                 |
| `TkFloatLiteral`    | decimal with `.` or exponent                      |
| `TkIntLiteral`      | integer                                           |
| `TkEnumLiteral`     | `Ident!`                                          |
| `TkDatatype`        | primitive/builtin type name                       |
| `TkAccessModifier`  | `public` / `private` / `protected` / etc.         |
| `TkStorageModifier` | `readonly` / `constant` / `ref` / etc.            |
| `TkControlKw`       | `if`, `then`, `else`, `for`, `do`, `choose`, etc. |
| `TkDeclKw`          | `function`, `subroutine`, `event`, `type`, etc.   |
| `TkSqlKw`           | `select`, `insert`, `update`, etc.                |
| `TkOtherKw`         | `and`, `or`, `not`, `xor`, `with`                 |
| `TkCompareOp`       | `<>`, `>=`, `<=`, `>`, `<`                        |
| `TkAugmentOp`       | `++`, `--`, `+=`, `-=`, `*=`, `/=`                |
| `TkAssignOp`        | `=`                                               |
| `TkArithOp`         | `+`, `-`, `*`, `/`, `^`                           |
| `TkContinuation`    | `&` (trailing only; consumed by preprocessor)     |
| `TkDot`             | `.`                                               |
| `TkDoubleColon`     | `::`                                              |
| `TkLParen`          | `(`                                               |
| `TkRParen`          | `)`                                               |
| `TkLBracket`        | `[`                                               |
| `TkRBracket`        | `]`                                               |
| `TkComma`           | `,`                                               |
| `TkSemi`            | `;`                                               |
| `TkColon`           | `:` (host variable prefix in SQL)                 |
| `TkLabel`           | `Ident:` at start-of-line (not `::`)              |
| `TkIdent`           | any other identifier                              |

---

## 11. Grammar Structure (Megaparsec)

### 11.1 Parsing Order for Keywords

Megaparsec `try` combinator ordering (longest match first):

1. Two-word keywords: `end if`, `end function`, `choose case`, etc.
2. Single-word keywords.
3. Enumerated literals (`Ident!`).
4. Identifiers.

### 11.2 Section Parser Sketch

```haskell
-- State machine over logical lines
parseSrFile :: [LogicalLine] -> SrObject
parseSrFile lines =
  SrObject
    { srHeaders   = parseHeaders   lines
    , srForward   = parseForward   lines
    , srPrototypes= parsePrototypes lines
    , srVariables = parseVariables lines
    , srTypeBlocks= parseTypeBlocks lines
    , srOnBlocks  = parseOnBlocks  lines
    , srEvents    = parseEvents    lines
    , srFunctions = parseFunctions lines
    }
```

### 11.3 Key Triangulation Tests (per CLAUDE.md)

For every parser, provide at minimum:

1. **Positive** — valid input → expected AST node
2. **Negative** — invalid input → parse failure (no crash)
3. **Property** — Hedgehog invariant (idempotence, monotonicity, etc.)

Pathological cases to cover in unit tests:

- `foo()bar()` — adjacent function calls without whitespace
- `& // comment` — `&` followed by inline comment (continuation still fires)
- `&` inside a string literal — NOT a continuation
- `ident!` vs `ident ! expr` — enum literal vs `!` operator (PB has no `!` operator; this is always enum)
- Date `2024-01-15` vs integer subtraction `2024-1-15`
- `:varname` in SQL vs `:` label operator
- `end` alone on a line (valid in some contexts: `end` keyword for `release`)
- Multi-word keyword split by continuation: `end &\n if` — should be recognized as `end if`

---

## 12. DataWindow AST Record Types

All fields strong-typed per CLAUDE.md. No `Map Text Text` for known attributes.

```haskell
data DataWindowObject = DataWindowObject
  { dwName             :: Text
  , dwUnits            :: Maybe Int
  , dwTimerInterval    :: Maybe Int
  , dwColor            :: Maybe Int
  , dwTable            :: Maybe DwTable
  , dwBands            :: [DwBand]
  , dwControls         :: [DwControl]
  }

data DwTable = DwTable
  { dtColumns          :: [DwColumn]
  , dtRetrieve         :: Maybe Text          -- raw SQL string
  , dtArguments        :: [DwArgument]
  }

data DwColumn = DwColumn
  { dcName             :: Text
  , dcType             :: Text
  , dcDbName           :: Maybe Text
  , dcUpdate           :: Maybe Bool
  , dcDddwName         :: Maybe Text
  }

data DwArgument = DwArgument
  { daName             :: Text
  , daType             :: Text
  }

data DwBand = DwBand
  { dbBandKind         :: DwBandKind
  , dbHeight           :: Maybe Int
  }

data DwBandKind = Header | Detail | Footer | Summary

data DwControl = DwControl
  { dcControlType      :: Text
  , dcName             :: Maybe Text
  , dcBand             :: Maybe DwBandKind
  , dcId               :: Maybe Int
  , dcExpression       :: Maybe Text
  , dcExtraAttrs       :: Map Text Text       -- unknown attributes
  }
```

---

## 13. Known Pitfalls

| Pitfall                               | Mitigation                                              |
| ------------------------------------- | ------------------------------------------------------- |
| Hyphen in identifiers                 | Ident regex must include `\-` in body char class        |
| `end` keyword is also standalone      | Match `end\s+<kw>` before bare `end`                    |
| `//` inside a string                  | Mask before comment detection                           |
| `&` mid-line is an operator           | Check trailing-only after masking                       |
| SQL `OPEN`/`CLOSE` vs method calls    | Negative lookahead `(?!\s*\()` on SQL openers           |
| Variable decl vs assignment           | `Type Name` only valid where declarations are expected  |
| `type variables` — two words          | Match as atomic section opener, not `type` then `vars`  |
| Inline `if`                           | `^if\b.*\bthen\s*$` distinguishes block from inline     |
| `choose case` — two words             | Must be matched before bare `choose`                    |
| `for to step` — three words           | Must be matched as a unit                               |
| Single-quoted strings end at EOL      | Mask algorithm must break string state at `\n`          |
| DataWindow `~"` vs PB `~"` in strings | DataWindow strings: only `~"` escape; PB: full `~x` set |
| Nested DataWindow blocks              | Use balanced paren depth counter, not line-based scan   |
| `null` is a keyword and a value       | Token kind `TkNull` for semantic analysis               |
| `error`, `message` are pronouns       | Reserve as variable references, not user-defined names  |
| Conditional compilation `#if`         | Strip/gate before main parse                            |

---

## 14. Implementation Phase Map

### Phase A — Preprocessor (current)

- `PB.Pipeline.Preprocess`: `normalizeText :: Text -> [LogicalLine]`
- Invariants: idempotence, monotonicity, no trailing `&`, string parity

### Phase B — Code Masking

- `PB.Lexing.Mask`: `maskLine :: Text -> MaskedLine`, `maskDocument :: Text -> Text`
- Required before Phase C

### Phase C — Lexer / Tokenizer

- `PB.Lexing.Tokenize`: `tokenize :: [LogicalLine] -> [Token]`
- Token kinds from §10; two-word keyword handling; escape sequences

### Phase D — Statement Splitter

- `PB.Pipeline.Preprocess` or `PB.Lexing`: split on Code-class `;`

### Phase E — Section Detection

- `PB.Pipeline.Sentinel` or `PB.Grammar.Sections`: recognize `forward`, `prototypes`, `variables` boundaries

### Phase F — PowerScript Grammar (declarations)

- `PB.Grammar.Declarations`: type, function, subroutine, event, on-block parsers

### Phase G — PowerScript Grammar (expressions/statements)

- `PB.Grammar.Statements`: control flow, SQL regions, assignments, calls

### Phase H — DataWindow Parser

- `PB.Grammar.DataWindow`: paren-block scanner, attribute extractor, DW AST

### Phase I — Pipeline Integration

- `PB.Pipeline.Runner`: wire A→B→C→D→E→F→G/H into the JSON AST output
