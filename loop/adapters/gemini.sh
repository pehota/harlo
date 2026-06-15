# Gemini CLI. VERIFY flags (`gemini --help`). --yolo auto-approves tool calls.
agent_run()  { gemini --yolo -p "$1"; }
agent_cost() { :; }
