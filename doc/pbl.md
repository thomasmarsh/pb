# PBL File Format Specification

Based on reverse engineering by Arnd Schmidt (2003-2012) and extended by our analysis.

**Original spec:** `doc/pbl-spec.txt` (kept for historical reference)

---

## Overview

PBL (PowerBuilder Library) files contain compiled PowerBuilder objects. They use a B-tree structure for indexing entries and chained blocks for storing data.

**File types:**
- `.pbl` — source library (extractable)
- `.pbd` — compiled library (binary, not extractable to source)
- `.dll` / `.exe` — executable with embedded PB objects

**Block sizes:**
- All blocks: 512 bytes
- Exception: NOD* (Node) blocks: 3072 bytes (6 × 512)

---

## Block Types

### 1. HDR* — Header Block (512 bytes)

Located at offset 0. Contains library metadata.

**ANSI format:**
| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `HDR*` |
| 4-17 | 14 | String | `PowerBuilder\0\0` |
| 18-21 | 4 | Char(4) | Version: `0400`, `0500`, `0600` |
| 22-25 | 4 | Long | Creation/Optimization datetime (Unix) |
| 28-xx | var | String | Library comment |
| 284-287 | 4 | Long | Offset of first SCC data block |
| 288-291 | 4 | Long | Size (net size of SCC data) |

**Unicode format:**
| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `HDR*` |
| 4-31 | 28 | StringW | `PowerBuilder\0\0` |
| 32-39 | 8 | CharW(4) | Version: `0400`, `0500`, `0600` |
| 40-43 | 4 | Long | Creation/Optimization datetime (Unix) |
| 46-xx | var | StringW | Library comment |
| 558-561 | 4 | Long | Offset of first SCC data block |
| 562-565 | 4 | Long | Size (net size of SCC data) |

**Detection:** If byte at offset 5 is `0x00`, file is Unicode (UTF-16LE). Otherwise ANSI (cp1253 for Greek).

---

### 2. FRE* — Bitmap Block (512 bytes)

Tracks which blocks are free/used.

| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `FRE*` |
| 4-7 | 4 | Long | Offset of next FRE* block or 0 |
| 8-511 | 504 | Bit(4032) | Bitmap: 1 bit per block (1=used, 0=free) |

---

### 3. NOD* — Node Block (3072 bytes)

B-tree node containing entry chunks. Each node may have left/right child subtrees and a next-sibling chain.

| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `NOD*` |
| 4-7 | 4 | Long | **Left child** offset (subtree with smaller names) |
| 8-11 | 4 | Long | Parent block offset |
| 12-15 | 4 | Long | **Next sibling** offset (right chain) |
| 16-19 | 4 | Long | **Right child** offset (subtree with larger names) |
| 20-21 | 2 | Int16 | **Count** of entries in this node |
| 22-23 | 2 | Int16 | Position of alphabetically first entry name |
| 24-25 | 2 | Int16 | Position of alphabetically last entry name |
| 26-31 | 6 | — | Padding/gap |
| 32-3071 | var | ENT*[] | Entry chunks |

**B-tree structure:**
```
        [Root NOD*]
       /          \
  [Left NOD*]    [Right NOD*]
   /      \        /      \
[...]   [...]   [...]   [...]
```

**Traversal:**
- `next` (offset 12): links sibling nodes in a chain
- `left` (offset 4): points to child subtree with alphabetically smaller names
- `right` (offset 16): points to child subtree with alphabetically larger names

---

### 4. ENT* — Entry Chunk (variable length)

Describes a single object in the library.

**ANSI format:**
| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `ENT*` |
| 4-7 | 4 | Char(4) | Version: `0600` |
| 8-11 | 4 | Long | Offset of first DAT* block |
| 12-15 | 4 | Long | Object size (net data size) |
| 16-19 | 4 | Long | Unix datetime |
| 20-21 | 2 | Int16 | Length of comment |
| 22-23 | 2 | Int16 | Length of object name |
| 24-xx | var | String | Object name |

**Unicode format:**
| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `ENT*` |
| 4-11 | 8 | CharW(4) | Version: `0600` |
| 12-15 | 4 | Long | Offset of first DAT* block |
| 16-19 | 4 | Long | Object size (net data size) |
| 20-23 | 4 | Long | Unix datetime |
| 24-25 | 2 | Int16 | Length of comment |
| 26-27 | 2 | Int16 | Length of object name |
| 28-xx | var | StringW | Object name |

---

### 5. DAT* — Data Block (512 bytes)

Stores object data in chained blocks.

| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `DAT*` |
| 4-7 | 4 | Long | Offset of next DAT* block or 0 |
| 8-9 | 2 | Int16 | Length of data in this block |
| 10-511 | 502 | Blob | Data bytes |

**Data chain:** Follow `next` pointers until 0. Concatenate data from all blocks.

---

### 6. TRL* — Trailer Block (DLL/EXE only, 512 bytes)

Found at end of DLL/EXE files. Points to the HDR* block.

| Offset | Size | Type | Description |
|--------|------|------|-------------|
| 0-3 | 4 | Char(4) | Magic: `TRL*` |
| 4-7 | 4 | Long | Offset of HDR* block |

---

## Object Types

PBL files contain these object types (by extension):

| Extension | Type | Source? |
|-----------|------|---------|
| `.srd` | DataWindow | ✓ |
| `.srs` | DataStore | ✓ |
| `.srw` | Window | ✓ |
| `.sru` | UserObject | ✓ |
| `.srf` | Function | ✓ |
| `.srm` | Menu | ✓ |
| `.srx` | (Unknown) | ✓ |
| `.srj` | Project | ✓ |
| `.srp` | Pipeline | ✓ |
| `.srq` | Query | ✓ |
| `.sra` | Application | ✓ |
| `.fun` | Function (binary) | ✗ |
| `.win` | Window (binary) | ✗ |
| `.udo` | UserObject (binary) | ✗ |
| `.men` | Menu (binary) | ✗ |
| `.str` | Structure (binary) | ✗ |
| `.dwo` | DataWindow (binary) | ✗ |

**Source files** (`.sr*`) contain extractable PBScript source.
**Binary files** (`.fun`, `.win`, etc.) contain compiled objects, not extractable to source.

---

## B-tree Traversal Algorithm

To extract ALL entries from a PBL file:

```
function collect_entries(address):
    if address == 0:
        return []
    
    nod = read_nod_block(address)
    entries = nod.entries
    
    // Recurse into left child (smaller names)
    left_entries = collect_entries(nod.left)
    
    return left_entries + entries

function extract(pbl_file):
    root_address = find_first_nod(pbl_file)  // After HDR* and FRE*
    all_entries = collect_entries(root_address)
    
    // Deduplicate (tree traversal may visit nodes multiple times)
    unique_entries = deduplicate(all_entries)
    
    return unique_entries
```

**Key insight:** The `next` pointer chain only gives you the rightmost path. To get ALL entries, you must also follow `left` children.

---

## Encoding

- **ANSI:** cp1253 (Greek) or latin-1 fallback
- **Unicode:** UTF-16LE

Detection: Check byte at offset 5. If `0x00`, Unicode. Otherwise ANSI.

---

## Timestamps

Stored as Unix timestamps (seconds since 1970-01-01 00:00:00 UTC).

---

## Example: afxlib.pbl Structure

```
NOD at 0x400:   count=72,  next=0x4fe00, left=0x0     (root)
NOD at 0x4fe00: count=74,  next=0x0,    left=0xea400  (middle)
NOD at 0xea400: count=20,  next=0x0,    left=0x0      (leaf)
```

Total: 72 + 74 + 20 = 166 entries
