#!/usr/bin/env bash
# Fixture State adapter for cli.test.ts: every save is a CAS conflict; other ops go to the file State adapter.
# argv: <state-files.ts> --dir <dir> state <op>
op=${!#}
if [ "$op" = save ]; then cat >/dev/null; echo '{"status":"ok","body":{"conflict":true}}'; exit 0; fi
exec bun "$@"
