# Cursor Agent CLI. VERIFY flags (`cursor-agent --help`). -p/--print = headless one-shot.
agent_run()  { cursor-agent --print --force "$1"; }
agent_cost() { :; }   # no documented cost field; rely on iteration/time budgets
