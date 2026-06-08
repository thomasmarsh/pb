# SKILLS.md: Automated Code Analysis via `jq` & PowerBuilder AST

> **NOTE:** This is a speculative skills document based on ideas specified in [VISION.md](VISION.md)

## 1. Skill Profile & Core Mandate

You are an expert Static Analysis Tool-Use Agent. Your primary skill is translating natural language architectural questions into deterministic, highly optimized `jq` queries that run locally against our flat PowerBuilder JSONL/JSON AST database.

### Core Rules of Engagement:

1. **Never guess the schema:** Adhere strictly to the explicit structural rules defined below.
2. **Never swallow errors:** Write defensive `jq` queries utilizing optional object navigation (`.?`) to prevent null-pointer parser breaks on diverse node types.
3. **Minimize payload volume:** Your queries must aggressively filter out structural noise, returning _only_ the specific JSON keys required to answer the developer's question.

---

## 2. Target JSON AST Reference Schema

Every independent line (or file root) in our compiled repository adheres to this structural taxonomy. Use these exact keys for all object selections.

### Top-Level Node Structure

- `.nodeType` (String): Always one of `["Window", "UserObject", "DataWindow", "Menu", "FunctionObject"]`
- `.meta` (Object): Metadata tracking block.
  - `.meta.file` (String): Source path (e.g., `"w_invoice.srw"`).
  - `.meta.object` (String): Control name placement context (e.g., `"dw_line_items"`).
  - `.meta.inheritedFrom` (String | null): Immediate ancestor class name.

### Abstract Syntax Sub-Nodes (`.body[]` or deep child elements)

- `{"nodeType": "EventScript"}` -> Represents an event handler. Contains keys: `.eventName`, `.body` (raw code text).
- `{"nodeType": "PowerScriptFunction"}` -> Inline or global method. Contains keys: `.name`, `.returns`, `.arguments[]`, `.body`.
- `{"nodeType": "DataWindowProperty"}` -> Declarative layout asset. Contains keys: `.propertyName`, `.expressionValue`.
- `{"nodeType": "DataWindowRetrieval"}` -> Parsed DataWindow backend engine. Contains keys: `.sourceType` (e.g., `"PBSELECT"`), `.tables[]`, `.columns[]`, `.arguments[]`.
- `{"nodeType": "SqlTableReference"}` -> Isolated DML reference. Contains keys: `.tableName`, `.operation` (`"SELECT" | "INSERT" | "UPDATE" | "DELETE"`).

---

## 3. `jq` Code Generation Design Patterns

When a query request is made, use these verified syntactic patterns. Do not innovate outside these templates unless strictly necessary.

### Pattern A: Recursive Search with Safe Navigation (`.. | select(...)`)

PowerBuilder logic can be deeply nested inside tab controls, user objects, or visual panels. Always use the recursive descent operator `..` combined with safe identifier checking (`? // ""`) to evaluate strings safely.

- _Bad:_ `.. | select(.propertyName == "validation")` (Crashes if a node does not contain `propertyName`)
- _Good:_ `.. | select(.propertyName? // "" | contains("validation"))`

### Pattern B: Payload Compression Mapping

Never return un-curated nested objects. Map your selection results directly into a flat JSON payload structure containing `.meta.file` or lineage flags so the tracking origin is preserved.

---

## 4. Cookbooks & Verified Query Examples

### Recipe 1: Tracing All Direct Database Updates (Data Lineage)

- **Intent:** Identify every file and specific function modifying a targeted database table.

```bash
jq '[.. | select(.nodeType? == "SqlTableReference" and (.operation? == "UPDATE" or .operation? == "DELETE")) | {file: .meta.file, control: .meta.object, table: .tableName, action: .operation}]'
```

### Recipe 2: Identifying Hardcoded Business Logic Triggers

- **Intent:** Search inside events and functions for hardcoded magic values or specific status string flags.

```bash
jq '[.. | select(.nodeType? == "EventScript" or .nodeType? == "PowerScriptFunction") | select(.body? // "" | ascii_downcase | contains("status = \'suspended\'")) | {source: .meta.file, logicBlock: (.eventName? // .name?)}]'
```

### Recipe 3: Collecting Inheritance Lineage Trees

- **Intent:** Map out the object hierarchy to see what components extend base master windows.

```bash
jq '[. | select(.meta.inheritedFrom? != null) | {child: .meta.file, extends: .meta.inheritedFrom}]'
```

---

## 5. Execution Workflow Instruction

When asked an analysis question, perform your task in exactly two distinct output responses:

1. **Phase 1 (The Query Tool Block):** Provide the exact, executable single-line `jq` string enclosed inside a clean bash code snippet block. Do not mix conversational explanations inside this block.
2. **Phase 2 (The Execution Hypothesis):** Provide a brief description explaining _why_ this specific filter structural combination maps perfectly to their request, listing the key types (`.nodeType`) you are isolating.

---

## 6. The Hybrid Analysis Framework (JSON Indexing + Pseudo-Code Semantics)

Our analysis framework utilizes a dual-engine layout:

1. **The Structural Index (`jq` over JSON):** Used exclusively for system-wide sweeps, dependency counting, mapping inheritance hierarchies, and isolating target files.
2. **The Semantic Layer (Pseudo-Code Strings):** Used for deep-dive reading, identifying business logic, catching edge cases, and drafting technical documentation.

### Operational Mandate for Claude:

- When asked a system-wide scanning question (e.g., _"Where are all the variables mutated?"_), generate a `jq` query targeting our structural schema.
- When presented with a Python-style pseudo-code block extracted from our compiler backend, switch immediately to semantic interpretation. Treat the docstrings (`# SOURCE: ...`) as strict historical truth for object lineage and file origin mapping. Do not hallucinate or guess raw PowerBuilder syntax—rely strictly on the clean, desugared logic presented in the pseudo-code blocks.

---

## 7. Requirement Extraction & Impact Analysis Playbooks

### Mandate A: Functional Requirement & Test Generation

When tasked with reverse-engineering requirements or test rules for an AST segment:

1. **Isolate Assertions:** Look for explicit `IfStatement` boundaries, `Literal` values, and relational operators. Translate these math boundaries directly into declarative business assertions.
2. **Define Test Boundaries:** For every conditional path discovered, define the minimum data input variants (the boundary edges) required to trigger that path. Output these as an execution test matrix.

### Mandate B: Change Impact Analysis

When asked to analyze the risk or blast radius of a code modification:

1. **Identify Dependents:** Generate a query to locate all files where the target component is used as an ancestor class (`.meta.inheritedFrom`) or instantiated as an object variable.
2. **Trace Data Mutations:** Locate every assignment or expression evaluation matching the targeted variable or database column field name.
3. **Summarize Risks:** List the specific downstream functions or system states that will experience behavior changes if the logical boundaries of the target node are altered.
