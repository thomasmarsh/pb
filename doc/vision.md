# pb — A Code Intelligence Tool for PowerBuilder

## The Problem

Large PowerBuilder codebases are structurally opaque. A typical enterprise
system spans hundreds of thousands of lines across thousands of source files.
The IDE shows you one object at a time. There is no way to ask "what tables does
this form read?", "what calls this function?", or "where does this DataWindow
retrieve its data?" without opening files manually and reading code line by line.
The format mixes visual layout metadata, SQL, and PowerScript in a way that
resists ordinary text search, and there is no tooling that understands the
language well enough to answer structural questions automatically.

The result is that the people who need answers most — developers tracing a bug,
modernization teams inventorying what a feature does, auditors checking data
flows — spend most of their time just finding where to look.

pb is designed to solve this. It parses your entire PowerBuilder source tree into
a typed, queryable model, then provides three ways to explore it: Browse,
Understand, and Ask.

---

## Design Principle

pb is built around a single idea: **fluent, effortless traversal**. When you are
trying to understand a large codebase, you are following a chain of questions —
each answer raises the next. What does this function call? Who depends on it?
What tables does that DataWindow read? What validates that input? The tool should
make each step instantaneous and frictionless, so the work of understanding is
thinking, not navigating software.

This shapes everything about the design. Browse and Understand are not two
sections — they are two faces of every entity. Any object, function, or
DataWindow can be viewed as source code or as structural analysis, and navigation
moves freely between the two. Ask generates results that link into either face.
The three pillars describe what you are doing, not where you are in the app.

Every entity is a node, and every node goes somewhere. A diagram node is a link.
A table cell containing an object name is a link. A search result is a link.
Nothing is a dead end.

pb is a readonly IDE — all the navigational power of a development environment,
applied to understanding rather than editing.

---

## Browse

pb organises your codebase as the IDE does — libraries, objects, functions,
events, DataWindows. But every item in that tree is a live navigation target.
From a function you can jump to its callers and callees. From an object you can
follow its full ancestry chain. From a DataWindow you can navigate to the tables
it reads and the expressions it evaluates.

The source view and the structural views are connected at every step — there is
no separate mode to enter for structural context. Rendered source, call links,
and diagrams appear together wherever you are in the tree.

Navigation is keyboard-first. A global search bar, reachable with `/` from
anywhere in the app, finds objects, functions, and DataWindows by name or
keyword. `?` opens a help overlay listing available shortcuts.

---

## Understand

pb exposes the structure that is hidden inside the code — the kind of information
that would take weeks to assemble manually from a large codebase. The structural
views are the foundation; the platform is built to go much deeper.

**Call graphs.** Who calls what. Which objects are at the centre of the call
network. Where the highest complexity is concentrated.

**Impact analysis.** Which objects depend on a given function or DataWindow. How
far a change propagates. What breaks if a signature or retrieve definition is
modified.

**Inheritance.** The full ancestry chain for any object, rendered as a navigable
diagram. Depth of inheritance. Where behaviour is overridden.

**DataWindow dependencies.** Which tables a DataWindow reads, what its WHERE
arguments are, what compute expressions reference. This is the primary tool for
answering "what data does this form touch?"

**Complexity metrics.** Cyclomatic complexity, graph centrality, and influence
scores, pre-computed across the whole codebase and surfaced as heatmaps and
sortable tables.

**Control flow and data flow.** The control flow graph for any procedure —
which paths exist, which branches are reachable, where execution can go.
Data flow across procedure boundaries — where a value originates, what
transforms it, where it ends up. Program slices: given any expression, what
statements could have affected it, and where can it propagate?

**Taint analysis.** Which values in the system originate from user input or
external sources, and where they travel. Which code paths reach sensitive
operations — database writes, external calls — without passing through
validation. Not a heuristic, but a structural analysis derived from the
complete call graph and data flow model.

**Formal verification.** Data access constraints stated in plain English,
answered with a proof or a counterexample. "Does user input ever reach this
table without going through the validation function?" is a question pb can
formally resolve — producing either a guarantee or a concrete execution path
that demonstrates the gap.

There is no standalone diagrams section. Every diagram lives with the entity it
describes — a call graph appears on the object's own page, a dependency diagram
on the DataWindow's page. From any diagram node, source is one click away.
Structural context is always available; it is never a separate destination.

---

## Ask

Not every question has a pre-built screen. pb exposes a query interface backed
by a local database containing everything the parser knows: objects, procedures,
calls, DataWindow controls, SQL retrieval definitions, complexity scores, and
graph metrics.

Two ways in: write a query directly — with syntax highlighting, schema browsing,
table inspection, and the full expressive power of SQL, in an interface modelled
on the DuckDB command-line client — or ask a question in plain English and let
pb translate it into a query. Either way, results run locally in milliseconds.

Results are object-aware. A cell containing a DataWindow name, function, or
table name is a link — into its source view, its analysis view, or both. Queries
can surface diagrams where the structure is derivable from the result.

As the analysis infrastructure deepens, so does Ask. Not every question is a
database query. "What is the backward slice of this variable?" is a data flow
question. "Prove that user input cannot reach this table without validation" is
a formal claim. pb translates natural language into whichever formal system can
answer it — a SQL query, a data flow traversal, a taint analysis, or a
constraint passed to a solver. The answer comes back in the same linked,
navigable form: a result you can follow into source.

Queries you find useful can be saved, named, and re-run. The most valuable ones
become permanent features — the query interface is where new analysis ideas
start; built-in views are where proven ones land.

---

## Who uses pb

**PowerBuilder developers** need to understand systems they didn't build: where a
bug might have entered, what a change will break, how a complex event handler
actually works. The familiar source tree is the starting point; call graphs and
blast-radius analysis close the gap that the IDE leaves open.

**Modernization teams** need a structural inventory of what the system does: what
each window reads, how deeply inheritance is used, where the complexity is
concentrated. Pre-built analysis views give the broad picture; custom queries
answer the specific questions that come up during a port or rewrite.

**Auditors** need more than a list of which procedures touch sensitive tables —
they need to formally verify that data access constraints actually hold. Which
paths reach this database operation? Does any path bypass the validation
function? pb answers these as structural questions over the codebase, not as
grep results, producing either a guarantee or a concrete counterexample to
investigate.

Every user will use all three modes. Browse is for when you know where to start;
Understand is for when you need the bigger picture; Ask is for when your question
doesn't have a screen yet.

---

## What makes this possible

pb is built on a complete, typed parser for PowerBuilder source files — not
pattern matching or heuristics, but a grammar that fully understands PowerScript,
DataWindow definitions, SQL retrieval blocks, and the object system. The result
is a structured representation of the entire codebase that can be indexed into a
relational database and queried with the full expressiveness of SQL.

Because the underlying representation is immutable and complete, the entire
arsenal of graph theory applies directly. Centrality, reachability, inheritance
depth, and influence scores are all derivable from a single structural model of
the codebase.

When source files fail to parse, a diagnostic view surfaces the errors with file
and line locations — keeping the index transparent and maintainable.

---

## What comes next

**Type inference.** A typing pass over the full AST decorates every expression
with its type. This unlocks type-aware search and queries, type safety
diagnostics across the codebase, and serves as the foundation for all deeper
analysis.

**Data flow and program slicing.** With types in place, control flow graphs and
intra- then inter-procedural data flow become computable. Program slices —
the set of statements that affect a given variable — give modernization teams
a precise behavioral specification for any output, and give developers an exact
blast-radius view for any change.

**Taint analysis.** Tracking values from their sources (user input, database
reads) through transformations to their sinks (database writes, external calls).
The result is a navigable map of data access paths across the entire codebase,
with every path step linked into source.

**Formal verification.** Constraint-based reasoning over code properties —
whether a branch is reachable, whether a precondition holds at every call site,
whether a data access constraint is provably satisfied. Where the analysis finds
a violation, it produces a concrete counterexample.

**Live schema integration.** Connecting to a live database or schema snapshot
(Oracle-first) will let pb validate DataWindow SQL references, surface column
types, and reason about schema drift.

**Stored procedures.** Parsing Oracle stored procedures as a first-class source
type would complete the structural picture for codebases where significant logic
lives in the database.

---

## Design documentation

The concrete translation of this vision into information architecture, user
experience, and interface direction is maintained as a series in
[`doc/design/`](design/): information architecture, user experience, and UI
direction — each building on the last.
