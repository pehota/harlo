// The free-text mapper: pure matching against hand-written candidate files (nothing Principal-specific), the
// exact argv handed to `ship signal`, every refusal, and two real gates of the terminal Principal end to end.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { D, HAPPY, lifecycle } from "../test/fixtures/lifecycle.fixture";
import { convert, lastBlockFor, mapReply, shellWords } from "./text-to-signal-mapper";

const ROOT = join(import.meta.dir, "..");
const BIN = join(ROOT, "bin", "ship");
const MAPPER = join(import.meta.dir, "text-to-signal-mapper.ts");

const dirs: string[] = [];
const cleanups: (() => void)[] = [];
afterAll(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
  for (const c of cleanups) c();
});

const line = (delivery: string, id: string, answer: string) =>
  `  ship signal ${delivery} ${id} '${JSON.stringify({ status: "ok", body: { answer, by: "person" } })}'`;

/** A hand-written file: not a Principal gate block, just two `ship signal` lines with their own options. */
const HAND = ["please pick", line("d-1", "d-1/verify-1", "live"), line("d-1", "d-1/verify-1", "not_live")].join("\n");
const GATE = [
  "── d-1: decide accept (min 1) ──", line("d-1", "d-1/accept-1", "accept"), line("d-1", "d-1/accept-1", "reject"),
  `  (optional: add "comment":"…" to the body)`,
].join("\n");

const block = (text: string, id: string) => lastBlockFor(text, "d-1", id)!;
const json = (answer: string, comment?: string) =>
  JSON.stringify({ status: "ok", body: { answer, by: "person", ...(comment === undefined ? {} : { comment }) } });

describe("shellWords", () => {
  test("bare words and single-quoted runs with the '\\'' escape", () => {
    expect(shellWords(`a d-1/x '{"t":"it'\\''s"}'`)).toEqual(["a", "d-1/x", `{"t":"it's"}`]);
  });
});

describe("mapReply on a hand-written (non-Principal) candidate file", () => {
  const b = block(HAND, "d-1/verify-1");
  test("exact option names", () => {
    expect(mapReply("live", b)).toMatchObject({ ok: true, answer: "live" });
    expect(mapReply("not_live", b)).toMatchObject({ ok: true, answer: "not_live" });
    expect(mapReply("Not Live", b)).toMatchObject({ ok: true, answer: "not_live" });
  });
  test("aliases resolve by polarity", () => {
    expect(mapReply("looks good", b)).toMatchObject({ ok: true, answer: "live" });
    expect(mapReply("no", b)).toMatchObject({ ok: true, answer: "not_live" });
  });
  test("argv is exactly the printed line, unchanged", () => {
    expect(mapReply("live", b)).toEqual({
      ok: true, answer: "live", argv: ["signal", "d-1", "d-1/verify-1", json("live")],
    });
  });
  test("no comment hint → free text is refused, not dropped", () => {
    expect(mapReply("live, thanks", b)).toMatchObject({ ok: false, options: ["live", "not_live"] });
  });
});

describe("mapReply on a decide gate", () => {
  const b = block(GATE, "d-1/accept-1");
  test("accept, reject and aliases", () => {
    expect(mapReply("accept", b)).toMatchObject({ ok: true, answer: "accept" });
    expect(mapReply("reject", b)).toMatchObject({ ok: true, answer: "reject" });
    expect(mapReply("yes", b)).toMatchObject({ ok: true, answer: "accept" });
    expect(mapReply("looks good!", b)).toMatchObject({ ok: true, answer: "accept" });
  });
  test("comment is added via JSON, quotes, ' and $ intact", () => {
    const text = `it's "flaky" $HOME \`x\``;
    const mapped = mapReply(`reject, ${text}`, b);
    expect(mapped).toEqual({ ok: true, answer: "reject", argv: ["signal", "d-1", "d-1/accept-1", json("reject", text)] });
  });
  test.each(["", "   ", "maybe", "yes but reject", "yes, but reject", "accept or reject"])("refuses %p and lists options", (reply) => {
    const mapped = mapReply(reply, b);
    expect(mapped).toMatchObject({ ok: false, options: ["accept", "reject"] });
  });
  test("an alias fitting two options is ambiguous", () => {
    const two = [GATE, line("d-1", "d-1/accept-1", "adjust")].join("\n");
    expect(mapReply("no", block(two, "d-1/accept-1"))).toMatchObject({ ok: false });
  });
});

describe("lastBlockFor", () => {
  test("takes the last block for the id, not a stale earlier one", () => {
    const text = [GATE, "── d-1: decide accept (min 1) ──", line("d-1", "d-1/accept-1", "accept")].join("\n");
    const b = block(text, "d-1/accept-1");
    expect(b.candidates.map((c) => c.answer)).toEqual(["accept"]);
    expect(b.commentAllowed).toBe(false);
  });
  test("null for another id or delivery", () => {
    expect(lastBlockFor(GATE, "d-1", "d-1/accept-2")).toBeNull();
    expect(lastBlockFor(GATE, "d-2", "d-1/accept-1")).toBeNull();
  });
});

describe("convert (refusals send nothing)", () => {
  const file = (text: string) => {
    const dir = mkdtempSync(join(tmpdir(), "ship-map-"));
    dirs.push(dir);
    const path = join(dir, "gates.txt");
    writeFileSync(path, text);
    return path;
  };
  const harness = (statusOut: { code: number; stdout: string }) => {
    const calls: string[][] = [];
    const run = async (argv: string[]) => {
      calls.push(argv);
      return argv[1] === "status" ? { exitCode: statusOut.code, stdout: statusOut.stdout, stderr: "boom" } : { exitCode: 0, stdout: "{}", stderr: "" };
    };
    return { calls, run };
  };
  const status = (awaiting: string | null) => ({ code: 0, stdout: JSON.stringify({ deliveries: [{ delivery: "d-1", at: "accept", awaiting }] }) });

  test("runs `ship signal` via argv with the printed line", async () => {
    const h = harness(status("d-1/accept-1"));
    const out = await convert({ ship: "SHIP", delivery: "d-1", candidates: file(GATE), reply: "looks good" }, h.run);
    expect(out.exit).toBe(0);
    expect(h.calls).toEqual([["SHIP", "status", "d-1"], ["SHIP", "signal", "d-1", "d-1/accept-1", json("accept")]]);
  });
  test("nothing awaiting, unknown delivery, no block for the awaited id, unclear reply", async () => {
    for (const [st, reply, text] of [
      [status(null), "yes", GATE], [{ code: 1, stdout: "" }, "yes", GATE], [status("d-1/accept-9"), "yes", GATE], [status("d-1/accept-1"), "maybe", GATE],
    ] as const) {
      const h = harness(st);
      const out = await convert({ ship: "SHIP", delivery: "d-1", candidates: file(text), reply }, h.run);
      expect(out.exit).toBe(1);
      expect(h.calls.filter((c) => c[1] === "signal")).toEqual([]);
    }
  });
  test("unclear reply prints the valid options", async () => {
    const out = await convert({ ship: "SHIP", delivery: "d-1", candidates: file(GATE), reply: "maybe" }, harness(status("d-1/accept-1")).run);
    expect(out.err).toContain("valid options: accept, reject");
  });
});

describe("through the real CLI and terminal Principal", () => {
  /** The gates the terminal Principal printed so far, as a candidate file for the mapper. */
  const gatesOf = (p: ReturnType<typeof lifecycle>): string => {
    const dir = mkdtempSync(join(tmpdir(), "ship-gates-"));
    dirs.push(dir);
    const path = join(dir, "principal.txt");
    writeFileSync(path, p.printed());
    return path;
  };
  const mapper = (p: ReturnType<typeof lifecycle>, reply: string, candidates: string) =>
    p.bash(`bun ${MAPPER} --ship ${BIN} --delivery ${D} --candidates ${candidates} --reply '${reply.replaceAll("'", `'\\''`)}'`);
  const at = async (p: ReturnType<typeof lifecycle>) => {
    const s = (await p.ship("status", D)).out as { deliveries: { at: string; awaiting: string | null }[] };
    return s.deliveries[0]!;
  };

  test("'looks good' accepts the Accept gate and the Delivery advances", async () => {
    const p = lifecycle(HAPPY, {}, { principal: "terminal" });
    cleanups.push(p.cleanup);
    await p.ship("start", "k");
    const before = await at(p);
    const ran = await mapper(p, "looks good", gatesOf(p));
    expect(ran.exit).toBe(0);
    expect(await at(p)).not.toEqual(before);
    expect((await at(p)).awaiting).toBe(`${D}/land-1`);
  }, 30_000);

  test("'reject, …' takes the negative branch with the comment", async () => {
    const p = lifecycle(HAPPY, {}, { principal: "terminal" });
    cleanups.push(p.cleanup);
    await p.ship("start", "k");
    const ran = await mapper(p, "reject, the tests are 'flaky' $HOME", gatesOf(p));
    expect(ran.exit).toBe(0);
    const after = await at(p);
    expect(after.awaiting).not.toBe(`${D}/land-1`); // accept would have reached land
    expect(JSON.stringify(await p.journal())).toContain("the tests are 'flaky' $HOME");
  }, 30_000);
});
