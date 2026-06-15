"""PBL binary library extraction.

Implements the PowerBuilder .pbl container format parser.
Supports both ANSI (cp1253) and Unicode (UTF-16LE) encodings with auto-detection.
"""
from __future__ import annotations

import struct
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, NamedTuple

_BLOCK = 512
_NODE_BLOCK = 3072

_SOURCE_EXTENSIONS = frozenset({
    '.srd', '.srs', '.srw', '.sru', '.srf',
    '.srm', '.srx', '.srj', '.srp', '.srq', '.sra',
})

PBL_HEADER = "HA$PBExportHeader$"
PBL_COMMENTS = "$PBExportComments$"


@dataclass(frozen=True)
class PblEntry:
    """A single source object extracted from a .pbl library."""
    name: str     # e.g. "w_main.srw"
    content: str  # source text (without PBExportHeader wrapper)


class _Entry(NamedTuple):
    offset: int
    comment_len: int
    name: str


class _Nod(NamedTuple):
    next_offset: int
    entries: list[_Entry]


# ── encoding ───────────────────────────────────────────────────────────────────

def _decode_ansi(b: bytes) -> str:
    try:
        return b.decode('cp1253')
    except UnicodeDecodeError:
        return b.decode('latin-1', errors='replace')


def _decode_unicode(b: bytes) -> str:
    # Do NOT strip() — that removes trailing newlines at block boundaries,
    # causing the next block's content to be smashed onto the same line.
    return b.decode('utf-16-le').replace('\x00', '')


def _detect_unicode(path: Path) -> bool:
    """Return True if the .pbl uses UTF-16LE encoding, False for ANSI."""
    with open(path, 'rb') as f:
        f.seek(4)
        sig = f.read(2)
    # ANSI: bytes[4:6] = 'Po' (0x50 0x6F); Unicode: 'P\x00' (0x50 0x00)
    return len(sig) >= 2 and sig[1] == 0x00


# ── binary reading ─────────────────────────────────────────────────────────────

def _read(path: Path, offset: int, size: int) -> bytes:
    with open(path, 'rb') as f:
        f.seek(offset)
        return f.read(size)


# ── structure parsing ──────────────────────────────────────────────────────────

def _parse_entry(chunk: bytes, unicode: bool) -> tuple[_Entry, int]:
    """Parse one ENT* entry. Returns (entry, bytes_consumed)."""
    # Layout (ANSI):    4(magic) 4(ver) 4(offset) 4(size) 4(date) 2(commentlen) 2(objectlen) name
    # Layout (Unicode): 4(magic) 8(ver) 4(offset) 4(size) 4(date) 2(commentlen) 2(objectlen) name
    p = 4 + (8 if unicode else 4)          # skip magic + version
    dat_offset = struct.unpack_from('<I', chunk, p)[0]; p += 4
    p += 4                                 # skip objectsize
    p += 4                                 # skip date
    comment_len = struct.unpack_from('<H', chunk, p)[0]; p += 2
    object_len  = struct.unpack_from('<H', chunk, p)[0]; p += 2
    name_bytes  = chunk[p:p + object_len]
    decode = _decode_unicode if unicode else _decode_ansi
    name = decode(name_bytes).rstrip('\x00')
    return _Entry(dat_offset, comment_len, name), p + object_len


def _parse_nod(path: Path, address: int, unicode: bool) -> _Nod:
    raw = _read(path, address, _NODE_BLOCK)
    if raw[:4] != b'NOD*':
        raise ValueError(f'Expected NOD* at offset {address:#x}, got {raw[:4]!r}')

    # NOD* header layout: 4(magic) 4(left) 4(parent) 4(right) 2(space) 2(post) 2(count) 2(last)
    next_offset = struct.unpack_from('<I', raw, 12)[0]
    count       = struct.unpack_from('<H', raw, 20)[0]

    entries: list[_Entry] = []
    pos = 32  # 24-byte fixed header + 8-byte gap before first entry
    for _ in range(count):
        entry, consumed = _parse_entry(raw[pos:], unicode)
        entries.append(entry)
        pos += consumed

    return _Nod(next_offset, entries)


def _read_entry_text(path: Path, entry: _Entry, unicode: bool) -> str:
    """Follow the DAT* chain for an entry and return the stripped source text."""
    decode = _decode_unicode if unicode else _decode_ansi
    chunks: list[str] = []
    address = entry.offset
    while address > 0:
        raw = _read(path, address, _BLOCK)
        if raw[:4] != b'DAT*':
            raise ValueError(f'Expected DAT* at offset {address:#x}, got {raw[:4]!r}')
        next_addr = struct.unpack_from('<I', raw, 4)[0]
        data_len  = struct.unpack_from('<H', raw, 8)[0]
        chunks.append(decode(raw[10:10 + data_len]))
        address = next_addr

    text = ''.join(chunks)
    return text[entry.comment_len:]  # strip embedded comment prefix


def _is_source(name: str) -> bool:
    return Path(name).suffix.lower() in _SOURCE_EXTENSIONS


# ── public API ─────────────────────────────────────────────────────────────────

def extract(pbl_path: Path) -> list[PblEntry]:
    """Extract all source entries from a single .pbl file."""
    pbl_path = Path(pbl_path)
    unicode = _detect_unicode(pbl_path)

    raw_hdr = _read(pbl_path, 0, _BLOCK)
    if raw_hdr[:4] != b'HDR*':
        raise ValueError(f'Not a valid PBL file: {pbl_path}')

    # NOD* blocks start at 1536 (Unicode) or 1024 (ANSI)
    nod_start = 1536 if unicode else _BLOCK * 2

    entries: list[PblEntry] = []
    address = nod_start
    while address > 0:
        nod = _parse_nod(pbl_path, address, unicode)
        for e in nod.entries:
            if _is_source(e.name):
                text = _read_entry_text(pbl_path, e, unicode)
                entries.append(PblEntry(name=e.name, content=text))
        address = nod.next_offset

    return entries


def extract_to_dir(pbl_path: Path, dest: Path) -> list[Path]:
    """Extract source files from a .pbl into dest/. Returns written paths."""
    written: list[Path] = []
    for entry in extract(pbl_path):
        out = dest / entry.name
        out.write_text(
            f"{PBL_HEADER}{entry.name}\n{PBL_COMMENTS}\n{entry.content}",
            encoding='utf-8',
        )
        written.append(out)
    return written


@contextmanager
def resolve_source_dir(path: Path, reporter) -> Iterator[Path]:
    """Resolve input to a source directory, extracting .pbl files transparently.

    Yields the resolved source directory. Callers must not use the path after
    the context exits; temp directories are cleaned up automatically.

    Three cases:
    - A single .pbl file  → extract into a temp dir, yield that dir.
    - A directory containing .pbl files → extract each into a named sub-dir
      inside a temp dir (sub-dir name = pbl stem), yield the temp dir root.
    - A directory with no .pbl files → yield as-is (plain source tree).
    """
    path = Path(path).resolve()

    if path.is_file() and path.suffix.lower() == '.pbl':
        with tempfile.TemporaryDirectory(prefix='pb-extract-') as tmp:
            dest = Path(tmp)
            with reporter.extracting_progress(1) as prog:
                extract_to_dir(path, dest)
                prog.advance()
            yield dest

    elif path.is_dir():
        pbls = sorted(
            p for p in path.iterdir()
            if p.is_file() and p.suffix.lower() == '.pbl'
        )
        if pbls:
            with tempfile.TemporaryDirectory(prefix='pb-extract-') as tmp:
                with reporter.extracting_progress(len(pbls)) as prog:
                    for pbl in pbls:
                        sub = Path(tmp) / pbl.name   # e.g. "afxlib.pbl/"
                        sub.mkdir()
                        extract_to_dir(pbl, sub)
                        prog.advance()
                yield Path(tmp)
        else:
            yield path

    else:
        yield path
