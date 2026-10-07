#!/usr/bin/env bash
# Fixture telemetry adapter for cli.test.ts: appends each received event (stdin) as one JSON line to $RECORD_TO.
# argv: telemetry notify
# A single printf writes the whole line (json + newline) in one syscall, so concurrent appends from other
# `ship` invocations' telemetry fires (each its own process) can't interleave mid-line.
printf '%s\n' "$(cat)" >> "$RECORD_TO"
