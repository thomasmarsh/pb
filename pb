#!/usr/bin/env bash
# Wrapper: delegates to the Python CLI via uv --project
exec uv run --project cli pb "$@"
