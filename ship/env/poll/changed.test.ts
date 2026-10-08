// M1.4: the WorkItem-change poller, driven as an executable against the real `bin/ship` CLI (state: the real
// file adapter; every other port: the scripted fake), exactly as test/e2e/lifecycle.test.ts drives `ship`.
import { afterAll, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { lifecycle } from "../../test/fixtures/lifecycle.fixture";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin", "ship");
const CHANGED = join(import.meta.dir, "changed.ts");

type Project = ReturnType<typeof lifecycle>;
const projects: Project[] = [];
afterAll(() => {
  for (const p of projects.splice(0)) p.cleanup();
});
const project = (...args: Parameters<typeof lifecycle>): Project => {
  const p = lifecycle(...args);
  projects.push(p);
  return p;
};

const ok = (body: unknown) => ({ status: "ok", body });
const wi = (key: string) => ok({ workItem: { key, title: "t", body: "b" } });

/** Run the poller with `bin/ship` on the project's own state/config, as cron would. */
const poll = async (p: Project) => {
  const ran = await p.bash(`bun ${CHANGED} --ship ${BIN}`);
  return { exit: ran.exit, stdout: ran.stdout, stderr: ran.stderr };
};

describe("poll/changed", () => {
  test("calls `ship changed` once per non-terminal Delivery, in `ship status` order", async () => {
    const p = project({
      // Every start reads its own key's WorkItem; the poller's `ship changed` re-reads it (unchanged: W1).
      "tracker.read": [wi("k1"), wi("k2"), wi("k1"), wi("k2")],
      "workspace.setup": ok({ path: "/ws/k-1", base: "trunk" }),
      "define.run": ok({ requirements: { criteria: ["c"], runbook: ["r"] } }), // one reply answers every call (both Deliveries)
    });

    const start1 = await p.ship("start", "k1");
    const start2 = await p.ship("start", "k2");
    expect(start1.out).toMatchObject({ awaiting: "k1-1/accept-1" });
    expect(start2.out).toMatchObject({ awaiting: "k2-1/accept-1" });

    const before = p.log().filter((s) => s.port === "tracker" && s.op === "read");
    expect(before).toHaveLength(2);

    const ran = await poll(p);
    expect({ exit: ran.exit, stderr: ran.stderr }).toEqual({ exit: 0, stderr: "" });

    const after = p.log().filter((s) => s.port === "tracker" && s.op === "read");
    expect(after.map((s) => s.delivery)).toEqual([null, null, "k1-1", "k2-1"]);

    // `changed` left both Deliveries exactly where they were: unchanged WorkItem, no new commands.
    const status = await p.ship("status");
    expect(status.out).toEqual({
      deliveries: [
        { delivery: "k1-1", at: "accept", awaiting: "k1-1/accept-1" },
        { delivery: "k2-1", at: "accept", awaiting: "k2-1/accept-1" },
      ],
    });
  }, 30_000);

  test("no non-terminal Deliveries: no `ship changed` call, exit 0", async () => {
    const p = project({});
    const ran = await poll(p);
    expect({ exit: ran.exit, stderr: ran.stderr }).toEqual({ exit: 0, stderr: "" });
  }, 30_000);
});
