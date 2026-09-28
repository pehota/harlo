#!/usr/bin/env bash
# Fixture adapter for spawn.test.ts. argv: <mode> [mode args…] <port> <op>; stdin: Stdin.
mode=$1
case "$mode" in
  ok)             cat >/dev/null; echo '{"status":"ok","body":{"path":"/ws/k-1"}}' ;;
  accepted)       cat >/dev/null; echo '{"status":"accepted"}' ;;
  failed)         cat >/dev/null; echo '{"status":"failed","info":"disk full"}' ;;
  invalid_json)   echo 'this is not json' ;;
  schema_invalid) echo '{"status":"ok","body":{}}' ;;
  question)       echo '{"status":"question","prompt":"Which disk?","about":"clarify"}' ;;
  exit1)          echo 'boom' >&2; echo '{"status":"ok","body":{"path":"/ws/k-1"}}'; exit 1 ;;
  noisy)          head -c 5000 /dev/zero | tr '\0' 'x' >&2; printf 'END' >&2; exit 1 ;;
  env)            env > "$2"; echo '{"status":"ok","body":{"path":"/ws/k-1"}}' ;;
  wait)           until [ -e "$2" ]; do sleep 0.05; done; echo '{"status":"ok","body":{"path":"/ws/k-1"}}' ;;
  record)         out=$2; code=$3; shift 3; printf '%s\n' "$@" > "$out.argv"; cat > "$out.stdin"; exit "$code" ;;
  *)              echo "unknown mode $mode" >&2; exit 2 ;;
esac
