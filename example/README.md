# Example Corpus

Two real PowerBuilder projects used for parser development and regression testing.

## Corpora at a glance

| Corpus  | Root                           | Files | Encoding     | Notes                       |
| ------- | ------------------------------ | ----- | ------------ | --------------------------- |
| OpenPay | `openpay/`                     | 396   | Windows-1253 | Real Greek payroll app — GPL v2.0, [sourceforge.net/projects/openpay](https://sourceforge.net/projects/openpay/) |
| Appeon  | `PowerBuilder-Example/export/` | 381   | 7-bit ASCII  | Official Appeon example app |

**Encoding:** All Appeon files are safe to read as UTF-8 or ASCII. OpenPay files are
Windows-1253; bytes above `0x7F` appear in comments, string literals, and object
descriptions — never in structural tokens. Plan 12 (`plan/12-encoding.md`) handles
this at the I/O boundary.

## File types

Every `.sr*` file begins with two stripped header lines:

```text
HA$PBExportHeader$<filename>
$PBExportComments$
```

What follows depends on the extension:

| Ext    | Object type     | PowerScript? | Contents                                                                                    |
| ------ | --------------- | :----------: | ------------------------------------------------------------------------------------------- |
| `.sra` | Application     |     yes      | `global type … from application`, global transaction objects, `global variables` block      |
| `.srd` | DataWindow      |    **no**    | DSL: `release N;` then `datawindow(…)`, `table(…)`, band/control blocks — see SPEC §7       |
| `.srf` | Global function |     yes      | `forward prototypes` + one or more `global function … end function` blocks                  |
| `.srj` | Project/job     |    **no**    | Build-config metadata (EXE settings, JSON) — do not parse                                   |
| `.srm` | Menu            |     yes      | Menu type declaration + `on` and `event` blocks for menu items                              |
| `.srp` | Pipeline        |    **no**    | `PIPELINE(…)` / `SOURCE(…)` / `DESTINATION(…)` DSL — do not parse                           |
| `.srs` | Structure       |     yes      | `global type … from structure` with field declarations                                      |
| `.sru` | User object     |     yes      | Like `.srw` but for visual/non-visual user objects                                          |
| `.srw` | Window          |     yes      | Richest files: `forward`, `type variables`, prototypes, function/subroutine/event/on blocks |
| `.srx` | External object |     yes      | Remote/distributed NVO proxy; like `.sru` with a different type header                      |

Skip `.srj` and `.srp` entirely — they are not PowerScript.

## File counts by extension

| Ext    | OpenPay | Appeon | Total |
| ------ | ------- | ------ | ----- |
| `.srd` | 120     | 142    | 262   |
| `.srw` | 106     | 131    | 237   |
| `.srf` | 106     | 26     | 132   |
| `.sru` | 32      | 33     | 65    |
| `.srm` | 15      | 35     | 50    |
| `.srs` | 15      | 7      | 22    |
| `.srj` | 1       | 3      | 4     |
| `.srp` | 0       | 3      | 3     |
| `.srx` | 0       | 1      | 1     |
| `.sra` | 1       | 0      | 1     |

Non-DataWindow, non-skip total: **515** files to sweep with `pb-corpus`.

---

## Appeon library map

The Appeon corpus is organised under `PowerBuilder-Example/export/` into one directory
per compiled library (`.pbl`). Binary `.pbl` files in the root are not readable; always
use the `.pbl/` subdirectory under `export/`.

| Directory       | Files | Types                   | Contents                                         |
| --------------- | ----- | ----------------------- | ------------------------------------------------ |
| `pbexamfe.pbl/` | 34    | srf srj srm srs sru srw | Front-end: app config, entry UOs, menus          |
| `pbexamfn.pbl/` | 19    | srf                     | Global shared functions (all `.srf`)             |
| `pbexammn.pbl/` | 31    | srm                     | All menus — rich source of `on`/`event` blocks   |
| `pbexamuo.pbl/` | 33    | srs sru srx             | Custom user objects, structures, one `.srx`      |
| `pbexamw1.pbl/` | 41    | srw                     | Windows: DDE, dynamic SQL, DataWindow operations |
| `pbexamw2.pbl/` | 38    | srw                     | Windows: OLE, tab controls, list views           |
| `pbexamw3.pbl/` | 40    | srw                     | Windows: SDK functions, graphs, misc             |
| `pbexamd1.pbl/` | 57    | srd                     | DataWindow definitions part 1                    |
| `pbexamd2.pbl/` | 48    | srd                     | DataWindow definitions part 2                    |
| `pbexamor.pbl/` | 14    | srd srp                 | OLE/OLE2 DataWindows, pipeline                   |
| `pbexamsa.pbl/` | 13    | srd srp                 | Sample data pipeline, DataWindows                |
| `pbexamsy.pbl/` | 13    | srd srp                 | System reference DataWindows, pipeline           |

---

## OpenPay layout

`openpay/` is a flat directory. Naming conventions:

| Prefix                   | Meaning                     |
| ------------------------ | --------------------------- |
| `dw_` / `prn_` / `sprn_` | DataWindow objects (`.srd`) |
| `fn_` / `gsc_`           | Global functions (`.srf`)   |
| `w_` / `wiz_` / `wprn_`  | Windows (`.srw`)            |
| `sc_`                    | Structures (`.srs`)         |
| `uo_` / `u_`             | User objects (`.sru`)       |
| `m_`                     | Menus (`.srm`)              |
| `openpay`                | Application entry (`.sra`)  |
| `p_openpay`              | Project/job (`.srj`) — skip |

---

## Construct finder

Use this table to locate a specific syntactic construct quickly. Appeon files are
preferred for parser work because they are ASCII and have no encoding ambiguity.

### PowerScript structural constructs

| Construct                             | Good example file(s)                                                                           |
| ------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Minimal global function (1 line body) | `PowerBuilder-Example/export/pbexamfe.pbl/f_get_profile.srf`                                   |
| Global function, integer return       | `PowerBuilder-Example/export/pbexamfe.pbl/f_getversion.srf`                                    |
| `forward prototypes` block            | `PowerBuilder-Example/export/pbexamfe.pbl/f_get_profile.srf`                                   |
| `type variables` block                | `PowerBuilder-Example/export/pbexammn.pbl/m_menu_functions_main.srm`                           |
| `global variables` block              | `openpay/openpay.sra`                                                                          |
| Application object (`.sra`)           | `openpay/openpay.sra` — global transactions, global variables, app-level UOs                   |
| Structure (`.srs`)                    | `PowerBuilder-Example/export/pbexamuo.pbl/s_string_withcount.srs` (5 lines, minimal)           |
| External/distributed object (`.srx`)  | `PowerBuilder-Example/export/pbexamuo.pbl/uo_sales_order.srx`                                  |
| `on` blocks only                      | `PowerBuilder-Example/export/pbexammn.pbl/m_menu_functions_main.srm`                           |
| `on` + `event` blocks                 | `PowerBuilder-Example/export/pbexammn.pbl/m_rte.srm`                                           |
| `on … end on` (named: `on w.create`)  | `PowerBuilder-Example/export/pbexamw1.pbl/w_dynsql_frame.srw`                                  |
| External function declarations        | `PowerBuilder-Example/export/pbexamw1.pbl/w_dir_tree.srw` · `pbexamw3.pbl/w_sdk_functions.srw` |
| Window with MDI frame                 | `PowerBuilder-Example/export/pbexamw1.pbl/w_dynsql_frame.srw`                                  |

### Control-flow body constructs

| Construct                                                  | Good example file(s)                                                                            |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `if … end if`                                              | `PowerBuilder-Example/export/pbexamfn.pbl/f_boolean_to_char.srf`                                |
| `choose case … end choose`                                 | `PowerBuilder-Example/export/pbexamw1.pbl/w_dw_rows.srw` · `openpay/w_form.srw`                 |
| `for … next`                                               | `PowerBuilder-Example/export/pbexamw1.pbl/w_dde_client.srw` · `openpay/w_filter.srw`            |
| `do … loop`                                                | `openpay/fn_parse_stath.srf` (line 25) · `PowerBuilder-Example/export/pbexamuo.pbl/u_tower.sru` |
| Embedded dynamic SQL (`DECLARE`/`PREPARE`/`FETCH`/`CLOSE`) | `PowerBuilder-Example/export/pbexamfn.pbl/f_populate_ddlb_from_db.srf`                          |
| Dynamic SQL format 1–4                                     | `PowerBuilder-Example/export/pbexamw1.pbl/w_dynsql_format{1,2,3,4}.srw`                         |
| Embedded static SQL (`SELECT … INTO`)                      | `openpay/w_misth_zpkrat_form.srw` · `openpay/fn_param_address.srf`                              |

### DataWindow constructs

| Pattern                             | Good example file(s)                                                         |
| ----------------------------------- | ---------------------------------------------------------------------------- |
| Minimal DataWindow (few controls)   | `openpay/dw_dates.srd`                                                       |
| PBSELECT query DSL in `retrieve=`   | `openpay/dw_misth_ypal_list.srd`                                             |
| Plain SQL `retrieve=`               | `PowerBuilder-Example/export/pbexamd1.pbl/d_dept.srd`                        |
| Nested sub-report (`report(…)`)     | `PowerBuilder-Example/export/pbexamor.pbl/d_example_report_detail.srd`       |
| `compute(…)` controls               | `openpay/prn_ypal_total_dates.srd`                                           |
| Drop-down DataWindow (`dddw.name=`) | `PowerBuilder-Example/export/pbexamd1.pbl/d_dddw_cust.srd`                   |
| `graph(…)` / graphing DataWindow    | `PowerBuilder-Example/export/pbexamd1.pbl/d_dept_data_for_graph.srd`         |
| Pipeline object (`.srp` DSL)        | `PowerBuilder-Example/export/pbexamsa.pbl/p_create_full_sales_orders_sp.srp` |

---

## Golden test candidates

Files suitable for inline golden regression tests (Plan 11). All are Appeon ASCII,
no encoding issues.

| File                                     | Lines | Why                                    |
| ---------------------------------------- | ----- | -------------------------------------- |
| `pbexamfe.pbl/f_get_profile.srf`         | 10    | Minimal: 1 prototype, 1-statement body |
| `pbexamfe.pbl/f_getversion.srf`          | 10    | Minimal: different return type         |
| `pbexamfe.pbl/f_delete_profile.srf`      | 11    | Minimal: integer return                |
| `pbexamfe.pbl/f_set_profile.srf`         | 11    | Minimal: void return                   |
| `pbexamfn.pbl/f_right_adjust_dec.srf`    | 22    | Multi-statement body, numeric ops      |
| `pbexamfn.pbl/f_boolean_to_char.srf`     | 28    | `if/end if` body                       |
| `pbexamuo.pbl/s_string_withcount.srs`    | 5     | Minimal structure                      |
| `pbexammn.pbl/m_menu_functions_main.srm` | ~40   | `on` blocks, `type variables`          |

All paths above are relative to `PowerBuilder-Example/export/`.

---

## Search strategy

When a component name is mentioned without a path:

```bash
rg -rl "component_name" example/openpay/ example/PowerBuilder-Example/export/
```

For structural pattern searches (e.g., find all files with `choose case`):

```bash
rg -rl "^choose case" example/
```

For file-type-filtered searches:

```bash
find example/ -name "*.srf" | xargs rg -l "pattern"
```
