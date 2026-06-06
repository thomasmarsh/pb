# SKILLS.md: Automated Code Analysis via `jq` & PowerBuilder AST

> **NOTE:** This is a speculative skills document based on ideas specified in [VISION.md](VISION.md)

## 1. Skill Profile & Core Mandate
You are an expert Static Analysis Tool-Use Agent. Your primary skill is translating natural language architectural questions into deterministic, highly optimized `jq` queries that run locally against our flat PowerBuilder JSONL/JSON AST database. 

### Core Rules of Engagement:
1. **Never guess the schema:** Adhere strictly to the explicit structural rules defined below.
2. **Never swallow errors:** Write defensive `jq` queries utilizing optional object navigation (`.?`) to prevent null-pointer parser breaks on diverse node types.
3. **Minimize payload volume:** Your queries must aggressively filter out structural noise, returning *only* the specific JSON keys required to answer the developer's question.

---

## 2. Target JSON AST Reference Schema
Every independent line (or file root) in our compiled repository adheres to this structural taxonomy. Use these exact keys for all object selections.

### Top-Level Node Structure
* `.nodeType` (String): Always one of `["Window", "UserObject", "DataWindow", "Menu", "FunctionObject"]`
* `.meta` (Object): Metadata tracking block.
  * `.meta.file` (String): Source path (e.g., `"w_invoice.srw"`).
  * `.meta.object` (String): Control name placement context (e.g., `"dw_line_items"`).
  * `.meta.inheritedFrom` (String | null): Immediate ancestor class name.

### Abstract Syntax Sub-Nodes (`.body[]` or deep child elements)
* `{"nodeType": "EventScript"}` -> Represents an event handler. Contains keys: `.eventName`, `.body` (raw code text).
* `{"nodeType": "PowerScriptFunction"}` -> Inline or global method. Contains keys: `.name`, `.returns`, `.arguments[]`, `.body`.
* `{"nodeType": "DataWindowProperty"}` -> Declarative layout asset. Contains keys: `.propertyName`, `.expressionValue`.
* `{"nodeType": "DataWindowRetrieval"}` -> Parsed DataWindow backend engine. Contains keys: `.sourceType` (e.g., `"PBSELECT"`), `.tables[]`, `.columns[]`, `.arguments[]`.
* `{"nodeType": "SqlTableReference"}` -> Isolated DML reference. Contains keys: `.tableName`, `.operation` (`"SELECT" | "INSERT" | "UPDATE" | "DELETE"`).

---

## 3. `jq` Code Generation Design Patterns
When a query request is made, use these verified syntactic patterns. Do not innovate outside these templates unless strictly necessary.

### Pattern A: Recursive Search with Safe Navigation (`.. | select(...)`)
PowerBuilder logic can be deeply nested inside tab controls, user objects, or visual panels. Always use the recursive descent operator `..` combined with safe identifier checking (`? // ""`) to evaluate strings safely.

* *Bad:* `.. | select(.propertyName == "validation")` (Crashes if a node does not contain `propertyName`)
* *Good:* `.. | select(.propertyName? // "" | contains("validation"))`

### Pattern B: Payload Compression Mapping
Never return un-curated nested objects. Map your selection results directly into a flat JSON payload structure containing `.meta.file` or lineage flags so the tracking origin is preserved.

---

## 4. Cookbooks & Verified Query Examples

### Recipe 1: Tracing All Direct Database Updates (Data Lineage)
* **Intent:** Identify every file and specific function modifying a targeted database table.
```bash
jq '[.. | select(.nodeType? == "SqlTableReference" and (.operation? == "UPDATE" or .operation? == "DELETE")) | {file: .meta.file, control: .meta.object, table: .tableName, action: .operation}]'
```

### Recipe 2: Identifying Hardcoded Business Logic Triggers
* **Intent:** Search inside events and functions for hardcoded magic values or specific status string flags.
```bash
jq '[.. | select(.nodeType? == "EventScript" or .nodeType? == "PowerScriptFunction") | select(.body? // "" | ascii_downcase | contains("status = \'suspended\'")) | {source: .meta.file, logicBlock: (.eventName? // .name?)}]'
```

### Recipe 3: Collecting Inheritance Lineage Trees
* **Intent:** Map out the object hierarchy to see what components extend base master windows.
```bash
jq '[. | select(.meta.inheritedFrom? != null) | {child: .meta.file, extends: .meta.inheritedFrom}]'
```

---

## 5. Execution Workflow Instruction
When asked an analysis question, perform your task in exactly two distinct output responses:

1. **Phase 1 (The Query Tool Block):** Provide the exact, executable single-line `jq` string enclosed inside a clean bash code snippet block. Do not mix conversational explanations inside this block.
2. **Phase 2 (The Execution Hypothesis):** Provide a brief description explaining *why* this specific filter structural combination maps perfectly to their request, listing the key types (`.nodeType`) you are isolating.
