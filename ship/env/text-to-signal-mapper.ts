#!/usr/bin/env bun
// Free-text reply → `ship signal` (environment code; must not import `src/core`). A person types "looks good" or
// "reject, the tests are flaky"; this script finds the `ship signal <delivery> <id> '<json>'` lines the awaited
// gate offered, picks the one line the reply unambiguously names, and runs it exactly as printed. It decides
// nothing itself: no LLM, no default. An empty, unclear or multi-match reply runs nothing and prints the options.
//
// The candidate source is any file containing `ship signal …` lines (default: the Principal's `--out` file), so
// nothing here is Principal-specific beyond the gate layout it tolerates: blocks start at a line beginning `── `
// (a file without such lines is one block). Option names are read from each candidate's JSON `body.answer`.
//
// AC5 amendment (requested during dogfooding): the printed JSON is edited in exactly two ways — `"comment"` added
// where the gate allows one, and, for an option-less gate (one line whose answer is the `…` placeholder), the
// whole reply written as `answer`. Nothing else is ever re-serialized.
//
// argv: --ship <path to bin/ship> --delivery <id> [--candidates <file>] [--reply <text> | <text…>]
//   The reply is `--reply`, else the remaining words, else stdin. `--candidates` defaults to
//   $SHIP_PRINCIPAL_OUT, else ~/.local/state/ship/dogfood/principal.log.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type Candidate = { line: string; delivery: string; id: string; json: string; answer: string };
export type Block = { candidates: Candidate[]; commentAllowed: boolean };
export type Mapped =
  | { ok: true; argv: string[]; answer: string }
  | { ok: false; reason: string; options: string[] };

const BLOCK_HEADER = "── ";
/** The Principal adapter's stand-in answer for a gate with no options. */
const PLACEHOLDER = "…";
const COMMENT_HINT = /add\s+"comment"/;

/** Split one printed shell line into words: bare words and `'…'` runs (with `'\''` for a quote), as `shellQuote` prints. */
export const shellWords = (text: string): string[] | null => {
  const words: string[] = [];
  let i = 0;
  while (i < text.length) {
    if (/\s/.test(text[i]!)) { i += 1; continue; }
    let word = "";
    while (i < text.length && !/\s/.test(text[i]!)) {
      const ch = text[i]!;
      if (ch === "'") {
        const end = text.indexOf("'", i + 1);
        if (end === -1) return null;
        word += text.slice(i + 1, end);
        i = end + 1;
      } else if (ch === "\\" && i + 1 < text.length) {
        word += text[i + 1];
        i += 2;
      } else {
        word += ch;
        i += 1;
      }
    }
    words.push(word);
  }
  return words;
};

const parseCandidate = (line: string): Candidate | null => {
  const m = /^\s*ship signal\s+(.*)$/.exec(line);
  const words = m ? shellWords(m[1]!) : null;
  if (!words || words.length !== 3) return null;
  const [delivery, id, json] = words as [string, string, string];
  try {
    const answer = (JSON.parse(json) as { body?: { answer?: unknown } }).body?.answer;
    return typeof answer === "string" && answer !== "" ? { line, delivery, id, json, answer } : null;
  } catch {
    return null;
  }
};

/** The last block of `text` that offers `ship signal <delivery> <id> …` lines, or null if none does. */
export const lastBlockFor = (text: string, delivery: string, id: string): Block | null => {
  const blocks: string[][] = [[]];
  for (const line of text.split("\n")) {
    if (line.startsWith(BLOCK_HEADER)) blocks.push([]);
    blocks.at(-1)!.push(line);
  }
  for (const lines of blocks.reverse()) {
    const candidates = lines.flatMap((l) => parseCandidate(l) ?? []).filter((c) => c.delivery === delivery && c.id === id);
    if (candidates.length > 0) return { candidates, commentAllowed: lines.some((l) => COMMENT_HINT.test(l)) };
  }
  return null;
};

// ── Matching ──
// Decision (AC2/AC4): these word lists are the alias mechanism and nothing else. An alias ("yes", "no") can only
// select an option by the option's polarity, and the candidate lines carry none, so a small polarity vocabulary is
// unavoidable. Exact option names never consult it; an alias fitting zero or several options is refused.
const POSITIVE_ALIASES = ["yes", "y", "yep", "yeah", "ok", "okay", "sure", "lgtm", "looks good", "looks fine", "good", "go ahead", "approve", "accept"];
const NEGATIVE_ALIASES = ["no", "n", "nope", "reject", "deny", "not ok", "not good", "fail"];
const POSITIVE_STEMS = new Set(["accept", "approve", "pass", "live", "yes", "ok", "good", "go", "ship", "land", "done"]);
const NEGATIVE_STEMS = new Set(["reject", "rejected", "fail", "failed", "deny", "denied", "no", "not", "non", "rollback", "abort", "block", "abandon", "adjust", "rework", "rescope", "stop"]);

const norm = (s: string): string => s.toLowerCase().replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim();
const polarity = (option: string): "positive" | "negative" | null => {
  const stems = norm(option).split(" ");
  if (stems.some((s) => NEGATIVE_STEMS.has(s))) return "negative";
  return stems.some((s) => POSITIVE_STEMS.has(s)) ? "positive" : null;
};

/** Every phrase (option name or alias) with the candidates it selects; an alias selects those of its polarity. */
const vocabulary = (candidates: Candidate[]): Map<string, Set<Candidate>> => {
  const vocab = new Map<string, Set<Candidate>>();
  const add = (phrase: string, picked: Candidate[]) => {
    if (picked.length > 0) vocab.set(phrase, new Set([...(vocab.get(phrase) ?? []), ...picked]));
  };
  const withPolarity = (p: "positive" | "negative") => candidates.filter((c) => polarity(c.answer) === p);
  for (const a of POSITIVE_ALIASES) add(a, withPolarity("positive"));
  for (const a of NEGATIVE_ALIASES) add(a, withPolarity("negative"));
  for (const c of candidates) vocab.set(norm(c.answer), new Set(candidates.filter((o) => norm(o.answer) === norm(c.answer)))); // exact names win over aliases
  return vocab;
};

const SEPARATOR = /^[\s,;:.!\-–—]+/;
/** What may follow the chosen phrase before free text: punctuation, so "yes but reject" is not "yes" + comment. */
const CLAUSE_BREAK = /^\s*[,;:.!\-–—]/;

/** Match `reply` against `block`; on success the exact argv for `ship signal`, else the reason and the valid options. */
export const mapReply = (reply: string, block: Block): Mapped => {
  const options = block.candidates.map((c) => c.answer);
  const refuse = (reason: string): Mapped => ({ ok: false, reason, options });
  const text = reply.trim();
  if (text === "") return refuse("empty reply");

  // Deliberate extension beyond AC4/AC5: this is the one case where the printed JSON's `answer` is rewritten, and
  // the placeholder is the Principal's printed convention. An open-ended ask/decide prints one line whose answer is the placeholder to hand-replace: the whole reply is the answer.
  const [only] = block.candidates;
  if (block.candidates.length === 1 && only!.answer === PLACEHOLDER) {
    const body = JSON.parse(only!.json) as { body: Record<string, unknown> };
    body.body.answer = text;
    return { ok: true, argv: ["signal", only!.delivery, only!.id, JSON.stringify(body)], answer: text };
  }

  const vocab = vocabulary(block.candidates);
  const phrases = [...vocab.keys()].sort((a, b) => b.length - a.length);
  const lower = text.toLowerCase();
  const flat = lower.replace(/[_-]/g, " "); // same length as `text`, so phrase lengths index both
  const hit = phrases.find((p) => flat.startsWith(p) && (flat.length === p.length || CLAUSE_BREAK.test(lower.slice(p.length))));
  if (hit === undefined) return refuse(`unclear reply: ${JSON.stringify(text)}`);

  const remainder = text.slice(hit.length).replace(SEPARATOR, "").replace(/[\s.!]+$/, "");
  const picked = vocab.get(hit)!;
  // Another option named in the rest of the reply ("yes, but reject") means the person did not decide one thing.
  const words = new Set(norm(remainder).split(/[^a-z0-9 ]+|\s+/).filter(Boolean));
  const others = [...vocab].filter(([phrase, set]) => !norm(phrase).includes(" ") && words.has(phrase) && [...set].some((c) => !picked.has(c)));
  if (others.length > 0) return refuse(`ambiguous reply: also mentions ${others.map(([p]) => JSON.stringify(p)).join(", ")}`);
  if (picked.size !== 1) return refuse(`ambiguous reply: ${JSON.stringify(hit)} fits ${picked.size} options`);

  const [chosen] = [...picked] as [Candidate];
  const argv = shellWords(chosen.line.trim().slice("ship signal".length))!;
  if (remainder === "") return { ok: true, argv: ["signal", ...argv], answer: chosen.answer };
  if (!block.commentAllowed) return refuse("this gate does not accept a comment; reply with just an option");
  const body = JSON.parse(chosen.json) as { body: Record<string, unknown> };
  body.body.comment = remainder;
  return { ok: true, argv: ["signal", chosen.delivery, chosen.id, JSON.stringify(body)], answer: chosen.answer };
};

// ── CLI ──
const spawnText = async (argv: string[]): Promise<{ exitCode: number; stdout: string; stderr: string }> => {
  const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  return { exitCode, stdout, stderr };
};

export type Outcome = { exit: number; out: string; err: string };

/** Find the awaited id, its last printed block, and run the matching line; never signals on any refusal. */
export const convert = async (
  opts: { ship: string; delivery: string; candidates: string; reply: string },
  run: (argv: string[]) => Promise<{ exitCode: number; stdout: string; stderr: string }> = spawnText,
): Promise<Outcome> => {
  const fail = (err: string): Outcome => ({ exit: 1, out: "", err });
  const status = await run([opts.ship, "status", opts.delivery]);
  if (status.exitCode !== 0) return fail(`unknown delivery ${opts.delivery}: ${status.stderr.trim()}`);
  const awaiting = (JSON.parse(status.stdout) as { deliveries: { awaiting: string | null }[] }).deliveries[0]?.awaiting;
  if (!awaiting) return fail(`${opts.delivery} is not awaiting anything; nothing sent`);

  let text: string;
  try {
    text = readFileSync(opts.candidates, "utf8");
  } catch (error) {
    return fail(`cannot read ${opts.candidates}: ${error instanceof Error ? error.message : String(error)}`);
  }
  const block = lastBlockFor(text, opts.delivery, awaiting);
  if (!block) return fail(`no printed gate for awaited ${awaiting} in ${opts.candidates}; nothing sent`);

  const mapped = mapReply(opts.reply, block);
  if (!mapped.ok) return fail(`${mapped.reason}\nvalid options: ${mapped.options.join(", ")}`);
  const sent = await run([opts.ship, ...mapped.argv]);
  return { exit: sent.exitCode, out: `${mapped.answer}: ${sent.stdout}`, err: sent.stderr };
};

if (import.meta.main) {
  const args = process.argv.slice(2);
  const flags = new Map<string, string>();
  const rest: string[] = [];
  for (let i = 0; i < args.length; i += 1) {
    if (["--ship", "--delivery", "--candidates", "--reply"].includes(args[i]!)) flags.set(args[i]!, args[++i] ?? "");
    else rest.push(args[i]!);
  }
  const ship = flags.get("--ship");
  const delivery = flags.get("--delivery");
  if (!ship || !delivery) {
    console.error("usage: text-to-signal-mapper.ts --ship <bin/ship> --delivery <id> [--candidates <file>] [--reply <text> | <text…>]");
    process.exit(2);
  }
  const reply = flags.get("--reply") ?? (rest.length > 0 ? rest.join(" ") : await Bun.stdin.text());
  const candidates = flags.get("--candidates") ?? process.env.SHIP_PRINCIPAL_OUT ?? join(homedir(), ".local/state/ship/dogfood/principal.log");
  const result = await convert({ ship, delivery, candidates, reply });
  if (result.out) process.stdout.write(result.out.endsWith("\n") ? result.out : `${result.out}\n`);
  if (result.err) process.stderr.write(result.err.endsWith("\n") ? result.err : `${result.err}\n`);
  process.exit(result.exit);
}
