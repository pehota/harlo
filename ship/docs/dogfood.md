# Dogfood data: where it lives and how to recover it

A dogfood run keeps everything under `~/.local/state/ship/dogfood/`. There are three
locations, and each is protected differently.

| Location | Holds | Protection |
|---|---|---|
| `tracker/*.md` | one WorkItem per file (`<key>.md`) | its **own git repo**, created inside `tracker/` by the md tracker adapter |
| `state/<delivery-id>/*.json` | the Delivery's snapshot + journal, one file per version | **reconstructable**: not backed up, and rebuilt by re-running |
| `machine.json` | the machine-level config | **re-authorable** from the project's `ship.config.json` |

`state/` and `machine.json` are deliberately not git-tracked, and no cron, launchd or backup
script exists. The only repo is the one inside `tracker/`.

## Tracker: git history

On the first write (`update` or `comment`) the md adapter runs `git init` inside the tracker
directory if `tracker/.git` does not exist. It never uses or touches a parent repo. Files already
there are committed first as `tracker: initial import of existing WorkItems`. A local committer
identity (`ship <ship@localhost>`) is set only when none is configured, so it works with no global
git config.

Every mutation is exactly one commit containing only the changed file:
`update <key>: status <status>` and `comment <key>`. Reads (`read`, `next`) commit nothing, and a
write that changes nothing commits nothing. If git is missing or a commit fails, the tracker op
still succeeds and a `warning:` goes to stderr (stdout stays a single Result line).

Recover from it:

```bash
T=~/.local/state/ship/dogfood/tracker
git -C $T log --oneline -- PROJ-1.md          # history of one item (drop `-- file` for all)
git -C $T log --diff-filter=D --format=%h -- PROJ-1.md   # the commit that deleted it, if any
git -C $T checkout <sha>^ -- PROJ-1.md        # restore a deleted file (state before <sha>)
git -C $T show <sha>:PROJ-1.md                # view an earlier version
git -C $T checkout HEAD -- PROJ-1.md          # restore a file removed with a manual `rm`
```

A manual `rm` outside the adapter is not committed, but the file is recoverable from the last
commit, because its content was committed at its last write (the initial import covers files that
existed before the first write).

**A WorkItem that has no Delivery yet is covered only by this repo**: there is no journal to
rebuild it from. Items never touched by the adapter since they were created are covered only if
they existed at init time; hand-written files should be committed (`git -C $T add -A && git -C $T commit`).

## Journals: rebuild a WorkItem from the start entry

Starting a Delivery stores the WorkItem verbatim in the first version,
`state/<delivery-id>/1.json`, at `state.workItem` (and again at `entries[0].signal.workItem`).
`title` and `body` are embedded verbatim, so the md file can be rebuilt byte-for-byte.

File name: `<key>.md` (key = `workItem.key`). Format, as the adapter reads and writes it:

```
---
status: <status>
title: <title>        <- only if the title is not the body's first "# " heading
---
<body>

<!-- ship:log -->
```

`body` already includes the `# Title` line when the file had one. The start entry does not record
the status; an item that was started was `ready`. Comments written below the marker are not in the
journal.

```bash
D=~/.local/state/ship/dogfood
jq -j '.state.workItem | . as $w
  | "---\nstatus: ready\n"
    + (if (.body | split("\n") | any(. == "# " + $w.title)) then "" else "title: \($w.title)\n" end)
    + "---\n\(.body)\n\n<!-- ship:log -->\n"' \
  $D/state/PROJ-1-1/1.json > $D/tracker/PROJ-1.md
```

If the file is in the tracker repo, `git -C $D/tracker diff` shows only what differs (typically the lost comment lines).

## machine.json: re-author from `ship.config.json`

`machine.json` holds no data that exists nowhere else. If it is lost, write it again from the
project's `ship.config.json` (`projectId`, `adapters`, `policy`; see the README). Nothing in it
needs recovering.
