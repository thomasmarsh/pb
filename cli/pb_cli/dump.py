"""Implementation of `pb dump` — parse a PB source tree to a mirrored JSON file tree."""
from __future__ import annotations

import json
from pathlib import Path

from pb_cli.build import count_sr_files
from pb_cli.parse import parse_stream
from pb_cli.reporter import Reporter


def run(src_dir: Path, out: Path, binary: Path, reporter: Reporter) -> None:
    total = count_sr_files(src_dir)
    with reporter.parse_progress(total, 'Parsing ') as progress:
        for is_err, obj in parse_stream(src_dir, binary):
            if is_err:
                progress.on_error(obj)
            else:
                _write(obj, src_dir, out)
            progress.advance()
    reporter.done(parsed=total, errors=progress.error_count)


def _write(obj: dict, src_dir: Path, out: Path) -> None:
    src_file = obj.get('file', '')
    try:
        rel = Path(src_file).relative_to(src_dir)
    except ValueError:
        rel = Path(Path(src_file).name)
    out_path = out / (str(rel) + '.json')
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(obj))
