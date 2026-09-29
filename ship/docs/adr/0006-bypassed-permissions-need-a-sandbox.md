# Bypassed permissions require a sandboxed workspace

Real coding-agent calls (M1.9–M1.11, `adapters/agent/claude/index.ts`) run
unattended with `--permission-mode bypassPermissions`: no person is at a
terminal to approve anything, so a mode that would otherwise prompt is
useless there, and the loosest mode is simply correct for automation. This
removes every one of Claude Code's own safety prompts, not only around the
files Implement is meant to touch — a bypassed-permissions call can run
arbitrary Bash (delete files, exfiltrate secrets, push to a real remote)
with zero gate.

The adapter's own defenses do not sandbox this. `--disallowedTools` on
Define/Check blocks their own file-editing tools, not Bash. A git worktree
as Implement's workspace is a directory like any other on the same
filesystem, reachable and escapable by `cd`/absolute paths from any spawned
Bash call, and network access is unrestricted either way.

Decided: `bypassPermissions` stays, but a real (non-dogfood) deployment
must confine the process with something OUTSIDE Claude Code — an OS-level
sandbox, a container with a scoped filesystem/network policy, or
equivalent — so a bypassed-permissions call cannot reach beyond its own
workspace even if it tries. This is deployment configuration, not adapter
code: `agent/claude/index.ts` does not, and should not, implement
sandboxing itself (P6: the environment, not the core or an adapter, owns
operational safety outside the adapter's own narrow job). Documented as a
requirement here; not yet built — found dogfooding M1.12 on a plain local
clone with no such confinement.
