# Architectural Specification: PowerBuilder-to-JSON AST Compiler Front-End

## Subtitle: Static Analysis & LLM-Driven Code Querying via Structured Metadata

---

## 1. Executive Summary & Core Philosophy

This document defines the architectural strategy, data design, and downstream workflow for compiling a legacy PowerBuilder codebase (~300KLOC across 1,700 source files) into a unified, rich Abstract Syntax Tree (AST) serialized as JSON.

### The Core Problem

Legacy PowerBuilder codebases (`.srd`, `.sru`, `.srw`, `.srm`, `.sjp`) are inherently hostile to modern static analysis tools and Large Language Models (LLMs). They are heavily polluted with visual layout metadata (coordinates, font metrics, color bytes), rely on complex implicit object-oriented inheritance loops, and embed a unique mix of procedural PowerScript, proprietary `PBSELECT` metadata, and native PL/SQL blocks. Feeding raw source files into an LLM causes prompt context exhaustion, high token costs, and catastrophic model hallucinations due to the language training gap.

### The Solution: Structural Separation

We bypass text-based reading by transforming the codebase into a dense, normalized JSON AST using a **Megaparsec** compiler front-end.

By separating **structural query execution** from **semantic reasoning**, we shift the LLM's role:

- **The LLM is NOT a source reader:** It never processes raw `.sr*` or text blobs directly.
- **The LLM IS a query architect:** It converts natural language technical questions into deterministic `jq` queries executed locally against the structured JSON AST.
- **The LLM IS a semantic summarizer:** It takes the hyper-focused, minimal JSON payloads extracted by `jq` and translates them into architectural checklists, documentation, or dependency graphs.

---

## 2. LLM + `jq` Integration Workflow (Agentic Tool-Use)

To execute complex system-wide audits—such as discovering every form validation rule or tracing database lineage—the system runs a multi-stage Agentic RAG loop.

```
┌──────────────────┐      1. Natural Language Question       ┌───────────┐
│                  ├────────────────────────────────────────>│           │
│                  │                                         │    LLM    │
│                  │      2. Generates Precise jq Query      │           │
│                  │<────────────────────────────────────────┤           │
│       User       │                                         └───────────┘
│   (or Agentic    │
│    Pipeline)     │      3. Executes jq query locally
│                  ├──────────────────────────────┐
│                  │                              ▼
│                  │                     ┌─────────────────┐
│                  │                     │  JSON AST File  │
│                  │                     └────────┬────────┘
│                  │                              │ 4. Extracts tiny,
│                  │                              │    highly-focused
│                  │<─────────────────────────────┘    context snippet
└──────────────────┘      5. (Optional) Final LLM Call:
                             Summarizes the precise snippet
                             back into English

```

### Complete Operational Pipeline

1. **The Question:** A developer asks: _"What field validations are enforced when updating an invoice, and what database tables do they hit?"_
2. **Query Generation:** The LLM receives the system's known JSON schema definitions. It synthesizes a precise, multi-stage `jq` filter designed to isolate validation events and embedded DML operations.
3. **Local Execution:** The system runs the `jq` filter natively over the AST repository. This instantly filters out gigabytes of layout noise, reducing the search space to precise syntax nodes.
4. **Context Injection & Synthesis:** The dense, structured JSON result is injected into the LLM's context window. The LLM translates the logic into a clear markdown analysis sheet.

### Concrete Simulation: Analysis of Form Validations

#### Input Scenario

The codebase contains a DataWindow control inside a window (`w_invoice_entry.srw`) tracking a data object (`d_invoice_detail.srd`). Validations are split across the visual field rules (`.srd` text properties), the `ItemChanged` event trigger, and an inline PL/SQL check inside a user object.

#### Step 1: LLM-Generated `jq` Query

The LLM writes this command to sweep the entire compiled AST artifact for validation frameworks:

```bash
cat codebase_ast.json | jq '[
  .. |
  select(
    (.nodeType == "DataWindowProperty" and (.propertyName | contains("validation") or .propertyName == "verify")) or
    (.nodeType == "EventScript" and (.eventName == "itemchanged" or .eventName == "pbm_dwnitemchange")) or
    (.nodeType == "PowerScriptFunction" and (.name | ascii_downcase | test("validate|check|verify|auth")))
  ) |
  {
    sourceFile: .meta.file,
    contextObject: .meta.object,
    ancestorClass: .meta.inheritedFrom,
    logicType: .nodeType,
    identifier: (.name // .propertyName),
    extractedScript: .body,
    referencedTables: [.. | select(.nodeType? == "SqlTableReference") | .tableName]
  }
]'
```

#### Step 2: The Filtered JSON Payload (Fed back to LLM)

Instead of processing thousands of lines of visual scaffolding, the LLM receives this clean, high-density structural context block:

```json
[
  {
    "sourceFile": "d_invoice_detail.srd",
    "contextObject": "dw_invoice",
    "ancestorClass": null,
    "logicType": "DataWindowProperty",
    "identifier": "invoice_amt.validation",
    "extractedScript": "real(data) > 0.00",
    "referencedTables": []
  },
  {
    "sourceFile": "w_invoice_entry.srw",
    "contextObject": "dw_1",
    "ancestorClass": "w_master_entry",
    "logicType": "EventScript",
    "identifier": "itemchanged",
    "extractedScript": "IF dwo.name = 'customer_id' THEN\n  IF :customer.status FROM db WHERE id = :data IS 'SUSPENDED' THEN\n    REJECT\n  END IF;\nEND IF;",
    "referencedTables": ["customer"]
  }
]
```

#### Step 3: Final Semantic Output

The LLM processes this micro-payload and immediately outputs human-readable systems documentation:

> ### Invoice Form Validation Summary
>
> - **Client-Side DataWindow Bounds:** The field `invoice_amt` explicitly blocks any entry less than or equal to `0.00` directly at the data layer engine (`d_invoice_detail.srd`).
> - **State-Based Lifecycle Validations:** The `itemchanged` script inside `w_invoice_entry.srw` dynamically traps updates to `customer_id`. It fires a query against the `customer` table, blocking updates if the customer status evaluates to `'SUSPENDED'`.

---

## 3. JSON Serialization & Schema Guidance

To ensure the compiled AST supports clean `jq` querying and scales safely without memory degradation, the serialization schema must enforce strict design patterns.

### Crucial Data Anchors (Include on Every Node)

- **`.meta.file`**: The absolute or repository-relative path to the originating `.sr*` file.
- **`.meta.object`**: The parent control block or structural context (e.g., `"uo_client_validator"`, `"dw_1"`).
- **`.meta.inheritedFrom`**: The explicit ancestor object chain parsed from the class descriptor header. This is critical for resolving PowerBuilder’s deep inheritance trees.
- **`.nodeType`**: A string literal tag using clear PascalCase descriptors (`"EventScript"`, `"PowerScriptFunction"`, `"SqlTableReference"`, `"DataWindowProperty"`).

### Handling the PowerBuilder Mixed-Language Problem

#### 1. DataWindows and `PBSELECT`

- **Do not treat `PBSELECT` as raw text strings.**
- When the Megaparsec parser encounters `retrieve="PBSELECT(VERSION(400)...)"`, parse the structured parameters directly.
- Extract the tables, columns, arguments, and where clauses into structured JSON nodes. This bypasses the need for an expensive SQL string engine for DataWindow queries.

```json
{
  "nodeType": "DataWindowRetrieval",
  "sourceType": "PBSELECT",
  "version": 400,
  "tables": ["employee", "department"],
  "columns": ["employee.emp_id", "employee.emp_fname", "department.dept_name"],
  "arguments": [{ "name": "al_dept_id", "type": "number" }]
}
```

#### 2. Inline PowerScript SQL & PL/SQL Blocks

- Embed an implicit **Island Parser** pattern within Megaparsec.
- When executing inline SQL, match PowerBuilder Host Variables (identifiers prefixed with a colon, like `:ls_invoice_id` or `:dw_1.Object.Data`) as distinct expression elements (`"nodeType": "HostVariable"`). This ensures standard off-the-shelf SQL parser tokens don't break on non-ANSI syntax.
- Preserve code comments (`//` and `/* */`) and serialize them under an explicit `.comments` array attached to the closest functional statement node. Developers frequently store vital validation hints inside legacy code comments.

---

## 4. Scalable Compilation Pipeline Strategy

Processing 300KLOC across 1,700 source files will cause massive memory usage or schema nesting errors if serialized poorly.

### Architectural Rules for Serialization

```
[ 1,700 Source Files ]
         │
         ▼  (Megaparsec Compiler Front-End)
[ Individual .json AST Files ]  <─── High-speed parallel disk writes
         │
         ▼  (Aggregation Pipeline)
[ Flat JSONL Stream / Indexed Map File ]
         │
         ▼
[ JQ Engine / LLM Tool Window Execution ]
```

1. **Do Not Generate One Giant JSON Array:** Serializing the entire codebase into a single monolithic JSON file array will easily hit system memory ceilings, slow down parser emission, and complicate disk writes.
2. **Utilize a Flat JSONL (JSON Lines) Format or Linked Map File:**
   - **Approach A:** Emit an isolated `.json` file for every compiled `.sr*` file inside an output mirror directory. Create a global metadata manifest pointing to them.
   - **Approach B (Best for `jq`):** Compile the output into a single unified stream of JSON Lines (`.jsonl`), where each independent line represents the isolated top-level object tree of a single component file. This allows `jq` to run in streaming mode (`jq --stream`) with a tiny, flat memory footprint across thousands of application classes.
3. **Preserve Native Unescaping Before SQL Hand-off:** Ensure that nested string delimiters characteristic of DataWindow objects (e.g., `~"`, `~~"`) are fully normalized back into single-escaped standard quotes _prior_ to populating the `.body` or `.extractedScript` fields. This protects external validators and downstream LLM tools from breaking on custom PowerBuilder string layout escaping schemes.
