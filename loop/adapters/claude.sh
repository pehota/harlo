# Claude Code. HARNESS_ROLE=implement lets the (optional) orchestrator-guard hook allow source edits.
agent_run()  { HARNESS_ROLE=implement claude -p "$1" --output-format json \
                 --max-turns "${HARNESS_MAX_TURNS:-60}" --dangerously-skip-permissions; }
agent_cost() { jq -r '.total_cost_usd // empty' 2>/dev/null; }
