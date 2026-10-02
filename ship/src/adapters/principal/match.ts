// Free-text reply → one of a gate's typed options. Extracted from the old env/text-to-signal-mapper.ts, which
// solved a harder problem (re-deriving candidate options by re-parsing a previously-printed log, because it ran
// as a separate, later process). tty.ts runs inside the same call that received `options: string[]` directly, so
// only the alias/polarity matching core survives here — no log re-parsing, no JSON body concerns.
//
// Decision (carried over unchanged): these word lists are the alias mechanism and nothing else. An alias ("yes",
// "no") can only select an option by the option's polarity; exact option names never consult it, and an alias
// fitting zero or several options is refused.
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

/** Every phrase (option name or alias) with the options it selects; an alias selects those of its polarity. */
const vocabulary = (options: string[]): Map<string, Set<string>> => {
  const vocab = new Map<string, Set<string>>();
  const add = (phrase: string, picked: string[]) => {
    if (picked.length > 0) vocab.set(phrase, new Set([...(vocab.get(phrase) ?? []), ...picked]));
  };
  const withPolarity = (p: "positive" | "negative") => options.filter((o) => polarity(o) === p);
  for (const a of POSITIVE_ALIASES) add(a, withPolarity("positive"));
  for (const a of NEGATIVE_ALIASES) add(a, withPolarity("negative"));
  for (const o of options) vocab.set(norm(o), new Set(options.filter((other) => norm(other) === norm(o)))); // exact names win over aliases
  return vocab;
};

const SEPARATOR = /^[\s,;:.!\-–—]+/;
/** What may follow the chosen phrase before free text: punctuation, so "yes but reject" is not "yes" + comment. */
const CLAUSE_BREAK = /^\s*[,;:.!\-–—]/;

export type Matched = { ok: true; answer: string; comment?: string } | { ok: false; reason: string; options: string[] };

/**
 * Match `reply` against `options`. `commentAllowed` mirrors the port's body schema: `decide`'s DecideBody accepts
 * a trailing comment, `ask`'s AskBody does not — a reply with leftover text is refused there instead of dropped.
 */
export const match = (reply: string, options: string[], commentAllowed: boolean): Matched => {
  const refuse = (reason: string): Matched => ({ ok: false, reason, options });
  const text = reply.trim();
  if (text === "") return refuse("empty reply");

  const vocab = vocabulary(options);
  const phrases = [...vocab.keys()].sort((a, b) => b.length - a.length);
  const lower = text.toLowerCase();
  const flat = lower.replace(/[_-]/g, " "); // same length as `text`, so phrase lengths index both
  const hit = phrases.find((p) => flat.startsWith(p) && (flat.length === p.length || CLAUSE_BREAK.test(lower.slice(p.length))));
  if (hit === undefined) return refuse(`unclear reply: ${JSON.stringify(text)}`);

  const remainder = text.slice(hit.length).replace(SEPARATOR, "").replace(/[\s.!]+$/, "");
  const picked = vocab.get(hit)!;
  // Another option named in the rest of the reply ("yes, but reject") means the person did not decide one thing.
  // Not when the reply leads with an exact option name ("approve: checks fail as required"): `hit` is only ever
  // followed by end-of-reply or a clause break, so that is the explicit "option: comment" form, and the comment's
  // words — alias or stem words included — are the person's text, not a second pick.
  const explicit = options.some((o) => norm(o) === hit);
  const words = new Set(explicit ? [] : norm(remainder).split(/[^a-z0-9 ]+|\s+/).filter(Boolean));
  const others = [...vocab].filter(([phrase, set]) => !norm(phrase).includes(" ") && words.has(phrase) && [...set].some((c) => !picked.has(c)));
  if (others.length > 0) return refuse(`ambiguous reply: also mentions ${others.map(([p]) => JSON.stringify(p)).join(", ")}`);
  if (picked.size !== 1) return refuse(`ambiguous reply: ${JSON.stringify(hit)} fits ${picked.size} options`);

  const [chosen] = [...picked] as [string];
  if (remainder === "") return { ok: true, answer: chosen };
  if (!commentAllowed) return refuse("this gate does not accept a comment; reply with just an option");
  return { ok: true, answer: chosen, comment: remainder };
};
