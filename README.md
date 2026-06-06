# PB AST

Each `.sr*` file corresponds to a PB object type:

- `.srs` → Window
- `.sru` → UserObject
- `.srf` → Function
- `.srm` → Menu
- `.srd` → DataWindow
- `.srw` → Application
- `.sra` → Structure
- `.sro` → Object (generic)

Dependencies:

- Grammar → interprets → Tokens
- Lexer → produces → Tokens
- Preprocessor → produces → Text

Rules:

- `Text` everywhere
- No partial functions
- No accidental `String`
- No `head`, `tail`, `fromJust`, etc.

Unit test:

- Windows → Unix newline normalization
- & with trailing spaces
- & inside strings
- & inside comments
- Continuation across 3+ lines
- Continuation followed by blank line
- Continuation with escaped quotes
- Continuation with tabs
- Continuation with Unicode

PBT:

- idempotence: `normalize (normalize x) == normalize x`
- monotonicity: `llStartLine <= llEndLine`
- No empty logical lines unless input had them
- No logical line ends with `&`
- String literal parity preserved (continuation never breaks inside a string)
- Concat preservation: `T.concat (map llText (normalize x)) == expectedJoinedText`

