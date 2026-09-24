#!/bin/bash
#
# Scenario: dod-reviewer runs its lenses in order — scope, impact, spec,
# standards, security, correctness — and tags every finding with its lens.
#
#   (a) creep stops the review: an unrequested CLAUDE.md edit plus an obvious
#       logic bug -> only lens:scope findings (a blocking kind:creep one),
#       verdict fail, no correctness finding, no impact trace.
#   (b) impact: a write through a separate connection, outside the caller's
#       transaction -> blocking lens:impact finding, and an impact_trace
#       entry naming the transaction with inside:false.
#   (c) gap: the task asks for two flags, the diff adds one -> blocking
#       lens:scope kind:gap finding, and the other lenses still report.
#   (d) depth scope with clean scope -> depth "scope", no non-scope finding.
#   (e) standards, brief as floor: the diff breaks a rule the brief cites ->
#       a lens:standards finding.
#   (f) standards, not a ceiling: the diff breaks a CLAUDE.md rule the brief
#       left out -> still a lens:standards finding.
#   (g) standards, N/A fallback: brief n/a, the diff breaks a CLAUDE.md rule
#       -> still a lens:standards finding.
#   (h) standards, requested override: the task asks to change a rule, the
#       code follows the NEW rule -> no standards finding, no creep finding.
#   (i) lenses 3-6 together: a spec miss, a security hole and a logic bug, no
#       creep -> one run reports all three, tagged spec / security /
#       correctness.
#
# Tool-less: the diff and every file the reviewer would open are inline.
# Usage: bash dod/tests/scenario/test-reviewer-lenses.sh [DOD_REVIEWER_AGENT_PATH]

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/scenario-helpers.sh"
AGENT="${1:-$DIR0/../../agents/dod-reviewer.md}"

SYS=$(mktemp)
trap 'rm -f "$SYS"' EXIT
{
  echo "You are this agent, spawned by /dod:verify:"
  echo
  cat "$AGENT"
} > "$SYS"

PREAMBLE='You have no tools in this exercise: the output of the git commands you would
run (the changeset against baseline_sha) and the contents of every file you
would open are given inline below — treat them as exactly what those commands
returned. Return your final message only.'

# lens__reqs <docs_json> — the standard requirement set with a given docs entry.
lens__reqs() {
  printf '[{"id":"tests","type":"check","cmd":"make test","expect_exit":0,"source":"auto-detected","proves":"the changed behaviour is covered by unit tests"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"no user-facing flow","proves":"n/a: no user-facing flow"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"tests fully prove works_when","proves":"n/a: tests row proves works_when"},{"id":"review","type":"judgement","agent":"dod-reviewer","source":"protocol","proves":"independent check the change is correct and in scope"},%s]' "$1"
}
DOCS_NA='{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"no documented behaviour changes","proves":"n/a: no documented behaviour changes"}'
DOCS_CLAUDE='{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":true,"doc_paths":["CLAUDE.md"],"reason":"the task changes the id rule in CLAUDE.md","proves":"the project rule matches the new id scheme"}'

# lens__prompt <task> <works_when> <docs_json> <brief> <changed_standards> <depth> <body>
lens__prompt() {
  cat <<EOF
$PREAMBLE

Inputs:
baseline_sha : base01
mode         : full
task         : $1
works_when   : $2
requirements : $(lens__reqs "$3")
brief        : $4
changed_standards : $5
depth        : $6

$7
EOF
}

# ---------------------------------------------------------------- (a) creep
BODY_A=$(cat <<'EOF'
Changed files: net/config.py, CLAUDE.md

git diff base01 -- net/config.py
@@ -10,6 +10,8 @@ def parse_port(value: str) -> int:
     port = int(value)
+    if port < 65535:
+        raise ValueError(f"port out of range: {port}")
     return port

git diff base01 -- CLAUDE.md
@@ -3,3 +3,4 @@
 - Keep functions under 40 lines.
+- Config parsing may accept any integer as a port.
EOF
)
PROMPT_A=$(lens__prompt \
  "Make parse_port() in net/config.py reject ports above 65535." \
  "It works when parse_port(\"70000\") raises ValueError and parse_port(\"8080\") returns 8080." \
  "$DOCS_NA" "n/a: contract predates the context brief" '["CLAUDE.md"]' "full" "$BODY_A")

# ---------------------------------------------------------------- (b) impact
BODY_B=$(cat <<'EOF'
Changed files: shop/audit.py, shop/orders.py

git diff base01 -- shop/audit.py
@@ -0,0 +1,9 @@
+from shop import db
+
+
+def record(event: str, order_id: int) -> None:
+    conn = db.connect()
+    conn.execute("INSERT INTO audit_log (event, order_id) VALUES (?, ?)",
+                 (event, order_id))
+    conn.commit()
+    conn.close()

git diff base01 -- shop/orders.py
@@ -20,9 +20,11 @@ def cancel_order(order_id: int) -> None:
     with db.transaction() as tx:
         order = tx.fetch_order(order_id, for_update=True)
         if order.status == "shipped":
             raise CannotCancel(order_id)
         tx.execute("UPDATE orders SET status = 'cancelled' WHERE id = ?", (order_id,))
+        audit.record("order_cancelled", order_id)
         tx.execute("UPDATE stock SET qty = qty + ? WHERE item_id = ?",
                    (order.qty, order.item_id))

Full shop/db.py (unchanged):
    def connect():
        """Open a NEW connection with its own transaction scope."""
        return _pool.new_connection()

    @contextmanager
    def transaction():
        """Yield a connection inside one transaction; commit on exit, roll back on error."""
        conn = _pool.new_connection()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
EOF
)
PROMPT_B=$(lens__prompt \
  "Record an audit_log row whenever an order is cancelled." \
  "It works when cancelling an order leaves exactly one audit_log row with event order_cancelled for it." \
  "$DOCS_NA" "n/a: contract predates the context brief" '[]' "full" "$BODY_B")

# ---------------------------------------------------------------- (c) gap
BODY_C=$(cat <<'EOF'
Changed files: tool/cli.py

git diff base01 -- tool/cli.py
@@ -5,6 +5,10 @@ def build_parser() -> argparse.ArgumentParser:
     p = argparse.ArgumentParser(prog="tool")
     p.add_argument("path")
+    p.add_argument("--verbose", action="store_true")
     return p
@@ -14,5 +18,8 @@ def main(argv=None) -> int:
     args = build_parser().parse_args(argv)
+    if args.verbose:
+        logging.basicConfig(level=logging.ERROR)
     return run(args.path)
EOF
)
PROMPT_C=$(lens__prompt \
  "Add --verbose (debug-level logging) and --quiet (errors only) flags to the tool CLI." \
  "It works when 'tool --verbose x' logs at DEBUG level and 'tool --quiet x' logs only errors." \
  "$DOCS_NA" "n/a: contract predates the context brief" '[]' "full" "$BODY_C")

# ---------------------------------------------------------------- (d) depth scope
BODY_D=$(cat <<'EOF'
Changed files: billing/util.py, billing/invoice.py

git diff base01 -- billing/util.py
@@ -1,3 +1,3 @@
-def fmt(amount):
+def format_amount(amount):
     return "%.2f" % eval(amount)

git diff base01 -- billing/invoice.py
@@ -8,4 +8,4 @@ def render(inv):
-    total = fmt(inv.total)
+    total = format_amount(inv.total)
     return f"Total: {total}"
EOF
)
PROMPT_D=$(lens__prompt \
  "Rename billing/util.py's fmt() to format_amount() and update its callers." \
  "It works when billing code calls format_amount() and no reference to fmt() remains." \
  "$DOCS_NA" "n/a: contract predates the context brief" '[]' "scope" "$BODY_D")

# ---------------------------------------------------------------- (e) brief floor
BODY_E=$(cat <<'EOF'
The brief file (.dod/main/brief.md):
    # Context brief
    ## Project standards
    - Every stored timestamp is timezone-aware UTC (datetime.now(timezone.utc)); never naive local time — `CLAUDE.md:7`
    ## Domain invariants
    - none
    ## Neighbouring-code idioms
    - Models set timestamps in their save() method — `notes/models.py:12`

Changed files: notes/models.py

git diff base01 -- notes/models.py
@@ -10,6 +10,8 @@ class Note:
     def save(self, store) -> None:
+        if self.pinned:
+            self.pinned_at = datetime.now()
         store.put(self)
EOF
)
PROMPT_E=$(lens__prompt \
  "Record when a note was pinned: set Note.pinned_at on save when the note is pinned." \
  "It works when saving a pinned note stores its pinned_at timestamp." \
  "$DOCS_NA" ".dod/main/brief.md" '[]' "full" "$BODY_E")

# ---------------------------------------------------------------- (f) not a ceiling
BODY_F=$(cat <<'EOF'
The brief file (.dod/main/brief.md):
    # Context brief
    ## Project standards
    - Every stored timestamp is timezone-aware UTC — `CLAUDE.md:3`
    ## Domain invariants
    - none
    ## Neighbouring-code idioms
    - none

Full CLAUDE.md (unchanged):
    1  # Rules
    2
    3  - Every stored timestamp is timezone-aware UTC.
    4  - Read configuration only through settings.get("<KEY>"); never read os.environ directly.

Changed files: sync/client.py

git diff base01 -- sync/client.py
@@ -4,7 +4,9 @@ from sync import settings
 def fetch(url: str) -> bytes:
-    return http.get(url).body
+    timeout = float(os.environ.get("SYNC_TIMEOUT", "10"))
+    return http.get(url, timeout=timeout).body
EOF
)
PROMPT_F=$(lens__prompt \
  "Make the sync client's HTTP timeout configurable through the SYNC_TIMEOUT setting (default 10 seconds)." \
  "It works when setting SYNC_TIMEOUT=3 makes fetch() time out after 3 seconds." \
  "$DOCS_NA" ".dod/main/brief.md" '[]' "full" "$BODY_F")

# ---------------------------------------------------------------- (g) N/A fallback
BODY_G=$(cat <<'EOF'
Full CLAUDE.md (unchanged):
    1  # Rules
    2
    3  - Money amounts are integer cents everywhere; never store money as float.

Changed files: cart/cart.py

git diff base01 -- cart/cart.py
@@ -12,5 +12,9 @@ class Cart:
     def total_cents(self) -> int:
         return sum(line.price_cents * line.qty for line in self.lines)
+
+    def apply_discount(self, percent: int) -> None:
+        self.discount = self.total_cents() * percent / 100
EOF
)
PROMPT_G=$(lens__prompt \
  "Add Cart.apply_discount(percent) that stores the discount amount for the cart." \
  "It works when apply_discount(10) on a 2000-cent cart stores a 200-cent discount." \
  "$DOCS_NA" "n/a: contract predates the context brief" '[]' "full" "$BODY_G")

# ---------------------------------------------------------------- (h) requested override
BODY_H=$(cat <<'EOF'
The brief file (.dod/main/brief.md):
    # Context brief
    ## Project standards
    - Record ids are sequential integers — `CLAUDE.md:3`
    ## Domain invariants
    - none
    ## Neighbouring-code idioms
    - New records get their id in create() — `users/repo.py:8`

Changed files: CLAUDE.md, users/repo.py

git diff base01 -- CLAUDE.md
@@ -1,3 +1,3 @@
 # Rules

-- Record ids are sequential integers.
+- Record ids are UUIDv4 strings.

git diff base01 -- users/repo.py
@@ -6,6 +6,6 @@ class UserRepo:
     def create(self, name: str) -> User:
-        user = User(name=name)  # the database assigns the next integer id
+        user = User(id=str(uuid.uuid4()), name=name)
         self.db.insert(user)
         return user

(users/repo.py already has `import uuid` at line 1.)
EOF
)
PROMPT_H=$(lens__prompt \
  "Change the project rule in CLAUDE.md from sequential integer ids to UUIDv4 ids, and make UserRepo.create() give new users a UUIDv4 id." \
  "It works when CLAUDE.md states the UUIDv4 id rule and a newly created user's id is a UUIDv4 string." \
  "$DOCS_CLAUDE" ".dod/main/brief.md" '["CLAUDE.md"]' "full" "$BODY_H")

# ---------------------------------------------------------------- (i) lenses 3-6
BODY_I=$(cat <<'EOF'
Changed files: web/files.py

git diff base01 -- web/files.py
@@ -0,0 +1,14 @@
+import os
+
+UPLOADS = "/srv/uploads"
+
+
+@route("GET", "/files/<name>")
+def get_file(name: str) -> Response:
+    path = os.path.join(UPLOADS, name)
+    if not os.path.exists(path):
+        return Response(status=200, body=b"")
+    with open(path, "rb") as f:
+        data = f.read()
+    headers = {"Content-Length": str(len(name))}
+    return Response(status=200, body=data, headers=headers)
EOF
)
PROMPT_I=$(lens__prompt \
  "Add a GET /files/<name> endpoint that serves a file from the uploads directory." \
  "It works when GET /files/report.txt returns report.txt's bytes with status 200, and GET for a missing file returns 404." \
  "$DOCS_NA" "n/a: contract predates the context brief" '[]' "full" "$BODY_I")

# ---------------------------------------------------------------- asserts
lens__json() { printf '%s' "$1" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }; }
# lens__q <reply> <jq filter> — prints jq output
lens__q() { printf '%s' "$1" | jq -r "$2"; }

assert_creep() {
  local r; r=$(cat); lens__json "$r" || return 1
  [ "$(lens__q "$r" '[.findings[] | select(.lens=="scope" and .kind=="creep" and .severity=="blocking")] | length')" -ge 1 ] \
    || { echo "no blocking lens:scope kind:creep finding"; return 1; }
  [ "$(lens__q "$r" '[.findings[] | select(.lens != "scope")] | length')" -eq 0 ] \
    || { echo "non-scope findings reported despite creep: $(lens__q "$r" '[.findings[] | select(.lens != "scope") | .lens] | join(",")')"; return 1; }
  [ "$(lens__q "$r" '.verdict')" = "fail" ] || { echo "verdict not fail"; return 1; }
  [ "$(lens__q "$r" '(.impact_trace // []) | length')" -eq 0 ] || { echo "impact_trace recorded despite creep stop"; return 1; }
}

assert_impact() {
  local r; r=$(cat); lens__json "$r" || return 1
  [ "$(lens__q "$r" '[.findings[] | select(.lens=="impact" and .severity=="blocking")] | length')" -ge 1 ] \
    || { echo "no blocking lens:impact finding"; return 1; }
  [ "$(lens__q "$r" '[(.impact_trace // [])[] | select(.inside == false and ((.guarantees // []) | map(ascii_downcase) | any(test("transaction"))))] | length')" -ge 1 ] \
    || { echo "no impact_trace entry naming the transaction with inside:false"; return 1; }
}

assert_gap() {
  local r; r=$(cat); lens__json "$r" || return 1
  [ "$(lens__q "$r" '[.findings[] | select(.lens=="scope" and .kind=="gap" and .severity=="blocking")] | length')" -ge 1 ] \
    || { echo "no blocking lens:scope kind:gap finding"; return 1; }
  [ "$(lens__q "$r" '[.findings[] | select(.lens != "scope")] | length')" -ge 1 ] \
    || { echo "no other lens reported alongside the gap"; return 1; }
  [ "$(lens__q "$r" '(.impact_trace // []) | length')" -ge 1 ] || { echo "impact lens did not run (empty impact_trace)"; return 1; }
}

assert_scope_depth() {
  local r; r=$(cat); lens__json "$r" || return 1
  [ "$(lens__q "$r" '.depth')" = "scope" ] || { echo "depth $(lens__q "$r" '.depth'), want scope"; return 1; }
  [ "$(lens__q "$r" '[.findings[] | select(.lens != "scope")] | length')" -eq 0 ] \
    || { echo "non-scope findings at depth scope: $(lens__q "$r" '[.findings[] | .lens // "untagged"] | join(",")')"; return 1; }
  [ "$(lens__q "$r" '.verdict')" = "pass" ] || { echo "verdict not pass on a clean scope"; return 1; }
}

# lens__has_standards — >=1 finding with lens standards
assert_standards_flagged() {
  local r; r=$(cat); lens__json "$r" || return 1
  [ "$(lens__q "$r" '[.findings[] | select(.lens=="standards")] | length')" -ge 1 ] \
    || { echo "no lens:standards finding (lenses: $(lens__q "$r" '[.findings[] | .lens // "untagged"] | join(",")'))"; return 1; }
}

assert_override() {
  local r; r=$(cat); lens__json "$r" || return 1
  lens__q "$r" '.depth' | grep -qx 'full' || { echo "depth not full (untagged output?)"; return 1; }
  [ "$(lens__q "$r" '[.findings[] | select(.lens=="standards")] | length')" -eq 0 ] \
    || { echo "standards finding against the requested new rule: $(lens__q "$r" '[.findings[] | select(.lens=="standards") | .summary] | join(" | ")')"; return 1; }
  [ "$(lens__q "$r" '[.findings[] | select(.kind=="creep")] | length')" -eq 0 ] \
    || { echo "requested standards change flagged as creep"; return 1; }
}

assert_lenses_3_6() {
  local r l; r=$(cat); lens__json "$r" || return 1
  for l in spec security correctness; do
    [ "$(lens__q "$r" "[.findings[] | select(.lens==\"$l\")] | length")" -ge 1 ] \
      || { echo "no lens:$l finding (lenses: $(lens__q "$r" '[.findings[] | .lens // "untagged"] | join(",")'))"; return 1; }
  done
  [ "$(lens__q "$r" '[.findings[] | select(.kind=="creep")] | length')" -eq 0 ] || { echo "creep finding on an in-scope diff"; return 1; }
}

fail=0
run_case() { echo "== scenario ($1): $2 ($AGENT) =="; scenario_run "$3" "$SYS" "$4" || fail=1; }
ONLY="${ONLY:-a b c d e f g h i}"
for c in $ONLY; do
  case $c in
    a) run_case a "creep stops the review, scope findings only" assert_creep "$PROMPT_A" ;;
    b) run_case b "write outside the caller's transaction -> impact finding + trace" assert_impact "$PROMPT_B" ;;
    c) run_case c "half the task missing -> scope gap, other lenses still report" assert_gap "$PROMPT_C" ;;
    d) run_case d "depth scope, clean scope -> no non-scope findings" assert_scope_depth "$PROMPT_D" ;;
    e) run_case e "brief rule broken -> standards finding" assert_standards_flagged "$PROMPT_E" ;;
    f) run_case f "CLAUDE.md rule missing from the brief broken -> still a standards finding" assert_standards_flagged "$PROMPT_F" ;;
    g) run_case g "brief n/a, CLAUDE.md rule broken -> standards finding" assert_standards_flagged "$PROMPT_G" ;;
    h) run_case h "requested rule change followed -> no standards / creep finding" assert_override "$PROMPT_H" ;;
    i) run_case i "spec miss + security hole + logic bug -> all three lenses" assert_lenses_3_6 "$PROMPT_I" ;;
  esac
done
exit $fail
