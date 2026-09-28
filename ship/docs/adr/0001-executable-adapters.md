# Adapters are executables speaking a JSON contract

Every port is filled by an executable that reads a JSON command on stdin and
answers with JSON on stdout and an exit code, validated against the port's
schema. Stdout is either the result (work finished within the call) or
`accepted` (the result arrives later as a signal); the Runner turns a stdout
result into a signal, so the core sees one path. We chose this over in-process TypeScript modules so adapters stay
trivially testable by piping JSON, can be written in whatever fits the setup
(bash for a homelab deploy, TS for Jira), and can be swapped per project and
per machine without touching the core.

## Considered Options

- In-process TS modules behind typed interfaces — stronger typing, lighter for
  one developer; rejected because every setup difference would become core
  code, and a reviewer suggested it only as a YAGNI trim.
- MCP servers — rejected as heavier than a process call with no benefit for
  the core.
