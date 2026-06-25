"""Tests for pb.pipeline.pbl — .pbl binary extraction.

Unit tests use synthetic in-memory fixtures; the integration test against the
openpay corpus is skipped when example/openpay-0.1.1b/ contains no .pbl files.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest
from pb.pipeline.build import find_repo
from pb.pipeline.pbl import (
    PBL_COMMENTS,
    PBL_HEADER,
    PblEntry,
    _decode_ansi,
    _decode_unicode,
    _detect_unicode,
    _is_source,
    extract,
    extract_to_dir,
    resolve_source_dir,
)
from pb.pipeline.reporter import RecordingReporter

# ── synthetic fixture builder ─────────────────────────────────────────────────

_BLOCK = 512
_NODE_BLOCK = 3072


def _make_ansi_pbl(entries: list[tuple[str, str]]) -> bytes:
    """Build a minimal but structurally valid ANSI .pbl binary."""
    dat_start = _BLOCK + _BLOCK + _NODE_BLOCK  # HDR* + FRE* + NOD* = 4096

    entry_bufs: list[bytes] = []
    dat_blocks: list[bytes] = []
    dat_offset = dat_start

    for name, content in entries:
        name_b = name.encode("cp1253") + b"\x00"
        content_b = content.encode("cp1253")
        chunk = content_b[:502]

        dat_block = (
            b"DAT*"
            + struct.pack("<I", 0)  # no next block
            + struct.pack("<H", len(chunk))
            + chunk
        ).ljust(_BLOCK, b"\x00")

        ent = (
            b"ENT*"
            + b"\x00" * 4  # version (ANSI: 4 bytes)
            + struct.pack("<I", dat_offset)  # offset to first DAT block
            + struct.pack("<I", len(content_b))
            + b"\x00" * 4  # date
            + struct.pack("<H", 0)  # commentlen
            + struct.pack("<H", len(name_b))
            + name_b
        )
        entry_bufs.append(ent)
        dat_blocks.append(dat_block)
        dat_offset += _BLOCK

    # HDR* block — ANSI signature: 'PowerBuilder  ' (14 bytes)
    hdr = (
        b"HDR*"
        + b"PowerBuilder  "  # 14-byte ANSI signature (bytes[4]='P', bytes[5]='o')
        + b"\x01\x00"  # VersMajor
        + b"\x00\x00"  # VersMinor
        + b"\x00" * 4  # DateTime
        + b"\x00" * 256  # Comments
        + b"\x00" * 4  # SccOffset
        + b"\x00" * 4  # SccSize
    ).ljust(_BLOCK, b"\x00")

    fre = b"FRE*" + b"\x00" * (_BLOCK - 4)

    nod = (
        b"NOD*"
        + struct.pack("<I", 0)  # offsetleft
        + struct.pack("<I", 0)  # parentoffset
        + struct.pack("<I", 0)  # offsetright (no more nodes)
        + struct.pack("<H", 0)  # spaceleft
        + struct.pack("<H", 0)  # postfirst
        + struct.pack("<H", len(entries))  # count
        + struct.pack("<H", 0)  # poslast
        + b"\x00" * 8  # 8-byte gap before first entry
        + b"".join(entry_bufs)
    ).ljust(_NODE_BLOCK, b"\x00")

    return hdr + fre + nod + b"".join(dat_blocks)


# ── pure function unit tests ──────────────────────────────────────────────────


def test_is_source_accepts_known_extensions():
    for ext in ("srw", "sru", "srd", "srs", "srf", "srm", "srx", "srj", "srp", "srq", "sra"):
        assert _is_source(f"myobj.{ext}"), ext


def test_is_source_rejects_non_source():
    assert not _is_source("readme.txt")
    assert not _is_source("openpay.pbl")
    assert not _is_source("app.pbw")


def test_is_source_case_insensitive():
    assert _is_source("w_main.SRW")
    assert _is_source("u_svc.SRU")


def test_decode_ansi_ascii():
    assert _decode_ansi(b"hello world") == "hello world"


def test_decode_ansi_fallback_on_bad_cp1253(tmp_path):
    # byte 0x80 is valid cp1253 but 0x81 is not; should fall back to latin-1
    result = _decode_ansi(bytes([0x81]))
    assert isinstance(result, str)


def test_decode_unicode_roundtrip():
    text = "global type w_main from window"
    encoded = text.encode("utf-16-le")
    assert _decode_unicode(encoded) == text


def test_decode_unicode_strips_null_artifacts():
    # UTF-16LE naturally produces 0x00 bytes between ASCII chars; they must be removed
    raw = "ab".encode("utf-16-le")  # b'\x61\x00\x62\x00'
    result = _decode_unicode(raw)
    assert "\x00" not in result
    assert result == "ab"


# ── encoding detection ────────────────────────────────────────────────────────


def test_detect_unicode_false_for_ansi(tmp_path):
    # ANSI: bytes[4]='P'(0x50), bytes[5]='o'(0x6F)
    pbl = tmp_path / "test.pbl"
    pbl.write_bytes(b"HDR*PowerBuilder  " + b"\x00" * 494)
    assert not _detect_unicode(pbl)


def test_detect_unicode_true_for_utf16le(tmp_path):
    # Unicode: bytes[4]='P'(0x50), bytes[5]=0x00 (null byte of UTF-16LE 'P')
    pbl = tmp_path / "test.pbl"
    pbl.write_bytes(b"HDR*\x50\x00" + b"\x00" * 506)
    assert _detect_unicode(pbl)


# ── extract from synthetic fixture ────────────────────────────────────────────


def test_extract_empty_library(tmp_path):
    pbl = tmp_path / "empty.pbl"
    pbl.write_bytes(_make_ansi_pbl([]))
    entries = extract(pbl)
    assert entries == []


def test_extract_single_srw(tmp_path):
    content = "global type w_main from window\nend type\n"
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(_make_ansi_pbl([("w_main.srw", content)]))

    entries = extract(pbl)
    assert len(entries) == 1
    assert entries[0] == PblEntry(name="w_main.srw", content=content)


def test_extract_skips_non_source_entries(tmp_path):
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(
        _make_ansi_pbl(
            [
                ("w_main.srw", "source a"),
                ("readme.txt", "not source"),
                ("u_svc.sru", "source b"),
            ]
        )
    )
    entries = extract(pbl)
    names = [e.name for e in entries]
    assert "w_main.srw" in names
    assert "u_svc.sru" in names
    assert "readme.txt" not in names


def test_extract_multiple_entries(tmp_path):
    pairs = [
        ("w_main.srw", "window source"),
        ("u_svc.sru", "user object source"),
        ("d_list.srd", "datawindow source"),
    ]
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(_make_ansi_pbl(pairs))

    entries = extract(pbl)
    assert {e.name for e in entries} == {name for name, _ in pairs}
    content_map = {e.name: e.content for e in entries}
    for name, expected in pairs:
        assert content_map[name] == expected


def test_extract_rejects_invalid_file(tmp_path):
    bad = tmp_path / "bad.pbl"
    bad.write_bytes(b"NOTAPBL" + b"\x00" * 505)
    with pytest.raises(ValueError, match="Not a valid PBL"):
        extract(bad)


# ── tree traversal (left child) ───────────────────────────────────────────────


def _make_nod_block(
    entries_bufs: list[bytes],
    *,
    left: int = 0,
    nxt: int = 0,
    count: int | None = None,
) -> bytes:
    """Build a NOD* block with given left/next pointers and entry count."""
    if count is None:
        count = len(entries_bufs)
    nod = (
        b"NOD*"
        + struct.pack("<I", left)   # 4: left child
        + struct.pack("<I", 0)      # 8: parent
        + struct.pack("<I", nxt)    # 12: next sibling
        + struct.pack("<I", 0)      # 16: right child
        + struct.pack("<H", count)  # 20: count (parser reads here)
        + struct.pack("<H", 0)      # 22: post
        + struct.pack("<H", 0)      # 24: (unused/padding)
        + struct.pack("<H", 0)      # 26: (unused/padding)
        + b"\x00" * 4               # 28-31: gap
        + b"".join(entries_bufs)
    ).ljust(_NODE_BLOCK, b"\x00")
    return nod


def _make_entry_buf(name: str, dat_offset: int) -> bytes:
    name_b = name.encode("cp1253") + b"\x00"
    return (
        b"ENT*"
        + b"\x00" * 4
        + struct.pack("<I", dat_offset)
        + struct.pack("<I", 0)
        + b"\x00" * 4
        + struct.pack("<H", 0)
        + struct.pack("<H", len(name_b))
        + name_b
    )


def _make_dat_block(content: str) -> bytes:
    chunk = content.encode("cp1253")[:502]
    return (
        b"DAT*"
        + struct.pack("<I", 0)
        + struct.pack("<H", len(chunk))
        + chunk
    ).ljust(_BLOCK, b"\x00")


def _build_tree_pbl(
    root_entries: list[tuple[str, str]],
    left_entries: list[tuple[str, str]],
) -> bytes:
    """Build an ANSI .pbl with root NOD* whose left pointer points to another NOD*."""
    # Layout: HDR(512) + FRE(512) + NOD_root(3072) + NOD_left(3072) + DAT* blocks
    hdr = (
        b"HDR*" + b"PowerBuilder  " + b"\x01\x00" + b"\x00\x00"
        + b"\x00" * 4 + b"\x00" * 256 + b"\x00" * 8
    ).ljust(_BLOCK, b"\x00")
    fre = b"FRE*" + b"\x00" * (_BLOCK - 4)

    nod_root_start = _BLOCK * 2  # 1024
    nod_left_start = nod_root_start + _NODE_BLOCK  # 4096
    dat_start = nod_left_start + _NODE_BLOCK  # 7168

    # Build entry+dat blocks for left entries first (they appear at lower offsets)
    left_ent_bufs: list[bytes] = []
    left_dat: list[bytes] = []
    dat_off = dat_start
    for name, content in left_entries:
        left_ent_bufs.append(_make_entry_buf(name, dat_off))
        left_dat.append(_make_dat_block(content))
        dat_off += _BLOCK

    # Then root entries
    root_ent_bufs: list[bytes] = []
    root_dat: list[bytes] = []
    for name, content in root_entries:
        root_ent_bufs.append(_make_entry_buf(name, dat_off))
        root_dat.append(_make_dat_block(content))
        dat_off += _BLOCK

    nod_root = _make_nod_block(root_ent_bufs, left=nod_left_start)
    nod_left = _make_nod_block(left_ent_bufs)

    return b"".join([hdr, fre, nod_root, nod_left] + left_dat + root_dat)


def test_tree_traversal_extracts_left_child(tmp_path):
    """Entries in a left-child NOD* are included in extraction."""
    pbl = tmp_path / "tree.pbl"
    pbl.write_bytes(_build_tree_pbl(
        root_entries=[("w_main.srw", "root content")],
        left_entries=[("u_svc.sru", "left content")],
    ))
    entries = extract(pbl)
    names = {e.name for e in entries}
    assert "w_main.srw" in names
    assert "u_svc.sru" in names
    assert len(entries) == 2


def test_tree_traversal_no_duplicates(tmp_path):
    """Tree traversal does not produce duplicate entries."""
    pbl = tmp_path / "tree.pbl"
    pbl.write_bytes(_build_tree_pbl(
        root_entries=[("w_main.srw", "a")],
        left_entries=[("u_svc.sru", "b")],
    ))
    entries = extract(pbl)
    names = [e.name for e in entries]
    assert len(names) == len(set(names))


# ── extract_to_dir ────────────────────────────────────────────────────────────


def test_extract_to_dir_writes_files_with_header(tmp_path):
    content = "global type w_main from window\nend type\n"
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(_make_ansi_pbl([("w_main.srw", content)]))

    dest = tmp_path / "out"
    dest.mkdir()
    written = extract_to_dir(pbl, dest)

    assert len(written) == 1
    out_file = dest / "w_main.srw"
    assert out_file.exists()

    text = out_file.read_text(encoding="utf-8")
    assert text.startswith(f"{PBL_HEADER}w_main.srw\n")
    assert f"{PBL_COMMENTS}\n" in text
    assert content in text


def test_extract_to_dir_returns_paths(tmp_path):
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(
        _make_ansi_pbl(
            [
                ("w_main.srw", "a"),
                ("u_svc.sru", "b"),
            ]
        )
    )
    dest = tmp_path / "out"
    dest.mkdir()
    written = extract_to_dir(pbl, dest)
    assert sorted(p.name for p in written) == ["u_svc.sru", "w_main.srw"]


# ── resolve_source_dir ────────────────────────────────────────────────────────


def test_resolve_passthrough_plain_src_dir(tmp_path):
    """Directory with no .pbl files is yielded as-is."""
    (tmp_path / "w_main.srw").write_text("source")
    reporter = RecordingReporter()

    with resolve_source_dir(tmp_path, reporter) as src:
        assert src == tmp_path

    assert not any(e["type"] == "extracting_start" for e in reporter.events)


def test_resolve_single_pbl_file(tmp_path):
    """Single .pbl → extract to temp dir, yield that dir."""
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(_make_ansi_pbl([("w_main.srw", "source")]))
    reporter = RecordingReporter()

    with resolve_source_dir(pbl, reporter) as src:
        assert (src / "w_main.srw").exists()
        text = (src / "w_main.srw").read_text()
        assert PBL_HEADER in text

    assert any(e == {"type": "extracting_start", "total": 1} for e in reporter.events)
    assert sum(1 for e in reporter.events if e["type"] == "extracting_advance") == 1


def test_resolve_directory_of_pbls(tmp_path):
    """Directory of .pbl files → each in its own foo.pbl/ sub-dir."""
    (tmp_path / "a.pbl").write_bytes(_make_ansi_pbl([("w_main.srw", "a")]))
    (tmp_path / "b.pbl").write_bytes(_make_ansi_pbl([("u_svc.sru", "b")]))
    reporter = RecordingReporter()

    with resolve_source_dir(tmp_path, reporter) as src:
        assert (src / "a.pbl" / "w_main.srw").exists()
        assert (src / "b.pbl" / "u_svc.sru").exists()

    assert any(e == {"type": "extracting_start", "total": 2} for e in reporter.events)
    assert sum(1 for e in reporter.events if e["type"] == "extracting_advance") == 2


def test_resolve_temp_dir_cleaned_up(tmp_path):
    """Temp dir is removed after the context exits."""
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(_make_ansi_pbl([("w_main.srw", "source")]))
    reporter = RecordingReporter()

    captured: list[Path] = []
    with resolve_source_dir(pbl, reporter) as src:
        captured.append(src)

    assert not captured[0].exists()


def test_resolve_extracting_progress_total(tmp_path):
    pbl = tmp_path / "mylib.pbl"
    pbl.write_bytes(_make_ansi_pbl([("w_main.srw", "x")]))
    reporter = RecordingReporter()

    with resolve_source_dir(pbl, reporter):
        pass

    assert any(e == {"type": "extracting_start", "total": 1} for e in reporter.events)
    assert any(e == {"type": "extracting_end"} for e in reporter.events)


# ── openpay corpus integration test ──────────────────────────────────────────

_OPENPAY_DIR = find_repo() / "example" / "openpay-0.1.1b"
_OPENPAY_PBLS = (
    sorted(p for p in _OPENPAY_DIR.iterdir() if p.is_file() and p.suffix.lower() == ".pbl")
    if _OPENPAY_DIR.is_dir()
    else []
)


@pytest.mark.skipif(not _OPENPAY_PBLS, reason="no .pbl files in example/openpay-0.1.1b/")
def test_openpay_corpus_extracts_without_error(tmp_path):
    """All openpay .pbl files extract cleanly; total source files match corpus baseline."""
    total = 0
    for pbl in _OPENPAY_PBLS:
        entries = extract(pbl)
        # Every extracted entry must have a non-empty name and some content
        for e in entries:
            assert e.name, f"empty name in {pbl.name}"
            assert _is_source(e.name), f"{e.name!r} is not a source file (from {pbl.name})"
        total += len(entries)

    # 422 .sr* files after tree-traversal fix (was 396 with chain-only)
    assert total == 422, f"Expected 422 source files, got {total}"
