#!/usr/bin/env bash
# Wrapper: delegates to the Python CLI via uv --project
# TEMPORARY shim during P1-P3: pb_cli is not an installed package while the
# workspace restructure is in progress. Fixed properly in P3 when code moves
# to pb.pipeline and the entry point becomes "pb".
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPT_DIR}/cli${PYTHONPATH:+:$PYTHONPATH}"
exec uv run --project cli python -c "import sys; sys.argv[0]='pb'; from pb_cli.cli import app; app()" "$@"
