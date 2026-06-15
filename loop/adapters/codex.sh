# OpenAI Codex CLI. VERIFY flags against your version (`codex exec --help`).
# Contract: run non-interactively with auto-approval, edit files in CWD, exit.
agent_run()  { codex exec --json --dangerously-bypass-approvals-and-sandbox "$1"; }
agent_cost() { jq -r 'select(.type=="usage")|.cost_usd // empty' 2>/dev/null | tail -n1; }
