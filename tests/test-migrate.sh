#!/bin/bash
# test-migrate.sh — Tests for the migration script (migrate.sh, Layer 1)
# Run: bash tests/test-migrate.sh
# Shell-level tests that validate migrate.sh behavior with stubbed binaries
# (pg_dump, pg_restore, rclone, psql) so they run without a real Supabase
# project or database. Stubs log their argv so tests can assert the
# read-only-source invariant.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$SCRIPT_DIR/.."
MIGRATE="$WORKTREE/migrate.sh"
EXAMPLE="$WORKTREE/env/migrate.example.yml"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

ok()   { printf "  \033[0;32mPASS\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[0;31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

# ─── Sandbox builder ─────────────────────────────────────────────────────────
# Creates a sandbox dir with migrate.sh, env/migrate.example.yml, and a
# stub-bin directory populated with stubbed pg_dump/pg_restore/rclone/psql.
# Stubs log their argv to $SANDBOX/stub-bin/<name>.calls and behave per the
# env vars the test sets (e.g. STUB_PSQL_PUBLIC_TABLES=5).
make_sandbox() {
  local name="$1"
  local d="$TMPDIR_BASE/$name"
  mkdir -p "$d/env" "$d/stub-bin"
  cp "$MIGRATE" "$d/migrate.sh"
  cp "$EXAMPLE" "$d/env/migrate.example.yml"
  chmod +x "$d/migrate.sh"

  # Stub each binary. Each stub appends its argv (one line per arg, NUL-separated
  # for safety) to its .calls file, then behaves per env vars.
  for bin in pg_dump pg_restore rclone psql supabase docker; do
    cat > "$d/stub-bin/$bin" <<STUB
#!/bin/bash
# stub for $bin — logs argv, behaves per env vars
{
  printf 'CALL %s\n' "$bin"
  for a in "\$@"; do printf '  ARG %s\n' "\$a"; done
  # Append to a single globally-ordered timeline so tests can assert ordering
  # of invocations ACROSS different tools (e.g. buckets dump before rclone copy).
  {
    printf '%s' "$bin"
    for a in "\$@"; do printf ' ⟨%s⟩' "\$a"; done
    printf '\n'
  } >> "$d/stub-bin/call-timeline"
} >> "$d/stub-bin/$bin.calls"
case "$bin" in
  psql)
    # Matched against the whole argv rather than against a 'SELECT count(*)'
    # pattern: the schema probe is not a count, so it used to fall through to
    # the catch-all and answer "0". migrate.sh took that as a schema name and
    # dumped --schema=0, which the pg_dump stub accepted — so the happy path
    # asserted a migration of a schema that cannot exist.
    argv="\$(printf '%s ' "\$@")"
    case "\$argv" in
      *"information_schema.schemata"*)
        printf '%s\n' \${STUB_PSQL_SCHEMAS:-public}
        ;;
      *"information_schema.tables"*)
        echo "\${STUB_PSQL_PUBLIC_TABLES:-0}"
        ;;
      *"auth.users"*)
        echo "\${STUB_PSQL_AUTH_USERS:-0}"
        ;;
      *"count(*) FROM vault.decrypted_secrets"*)
        # Vault preflight: count of decrypted secrets. On privilege-denied the
        # source DSN cannot select from vault.decrypted_secrets.
        if [[ "\${STUB_PSQL_VAULT_DECRYPT_FAIL:-0}" == "1" ]]; then
          echo "permission denied for table decrypted_secrets" >&2
          exit 1
        fi
        echo "\${STUB_PSQL_VAULT_COUNT:-0}"
        ;;
      *"decrypted_secret, COALESCE"*)
        # Vault data select: name\tdecrypted_secret\tdescription rows.
        echo "\${STUB_PSQL_VAULT_ROWS:-}"
        ;;
      *)
        echo "0"
        ;;
    esac
    ;;
  pg_dump)
    # pg_dump succeeds unless STUB_PGDUMP_FAIL_SCHEMA is set to a schema name
    # present in argv.
    for a in "\$@"; do
      case "\$a" in
        --schema=*)
          schema="\${a#--schema=}"
          if [[ "\${STUB_PGDUMP_FAIL_SCHEMA:-}" == "\$schema" ]]; then
            echo "STUB_PGDUMP_FAIL: \$schema" >&2
            exit 1
          fi
          ;;
      esac
    done
    exit 0
    ;;
  pg_restore)
    [[ "\${STUB_PGRESTORE_FAIL:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  rclone)
    [[ "\${STUB_RCLONE_FAIL:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  supabase)
    # Supabase CLI stub. Logs argv via the header block above, then:
    #   functions list   -> prints STUB_SUPABASE_FUNCTIONS (a CLI table:
    #                       "ID SLUG STATUS ..." — the parser reads SLUG as col 2)
    #   functions download <slug> -> writes ./supabase/functions/<slug>/index.ts
    #                                relative to CWD (mimics the real CLI)
    #   secrets list     -> prints STUB_SUPABASE_SECRETS (a "DIGEST NAME" table)
    case "\${1:-}" in
      functions)
        case "\${2:-}" in
          list)
            printf '%s\n' "\${STUB_SUPABASE_FUNCTIONS:-}"
            ;;
          download)
            slug="\${3:-}"
            mkdir -p "supabase/functions/\$slug"
            printf 'export default function handler(){ return new Response("ok"); }\n' > "supabase/functions/\$slug/index.ts"
            ;;
        esac
        ;;
      secrets)
        case "\${2:-}" in
          list)
            printf '%s\n' "\${STUB_SUPABASE_SECRETS:-}"
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
esac
STUB
    chmod +x "$d/stub-bin/$bin"
  done

  echo "$d"
}

# Run migrate in sandbox; sets OUT and RC variables in caller scope.
run_migrate_rc() {
  local dir="$1"; shift
  # Put stub-bin first on PATH so the stubs shadow any real binaries.
  OUT="$( cd "$dir" && PATH="$dir/stub-bin:$PATH" bash migrate.sh "$@" 2>&1 )" && RC=0 || RC=$?
}

# Fill all required fields in a config.yml with valid test values.
# Fills every field migrate.sh requires, keyed by section, and fails loudly if
# it misses one.
#
# This used to be a list of seds that matched on the *comments* in the example
# config. When those comments were reworded and target.db_url lost its trailing
# one, two fields silently stopped being filled — so migrate.sh refused at
# validation and every scenario below reported its own failure message while
# never reaching the code it names. Fourteen of them, for one drifted comment.
#
# The field list is now read out of migrate.sh, so adding a required field
# breaks this helper visibly instead of quietly disarming the whole suite.
fill_required() {
  local c="$1/env/migrate.yml"
  python3 - "$MIGRATE" "$c" <<'PY'
import re, sys

migrate, cfg = sys.argv[1], sys.argv[2]

block = re.search(r'REQUIRED_FIELDS=\((.*?)\n\)', open(migrate).read(), re.S)
if not block:
    sys.exit("fill_required: could not find REQUIRED_FIELDS in migrate.sh")
required = re.findall(r'"([^"]+)"', block.group(1))

# Source and target must stay distinct — migrate.sh refuses when they match,
# and TC-MIG-003/004 rewrite these exact strings to build their scenarios.
values = {
    "source.project_ref":        "testprojref12345",
    "source.db_url":             "postgresql://postgres.testprojref12345:pwd"
                                 "@db.testprojref12345.supabase.co:6543/postgres",
    "source.storage_endpoint":   "https://testprojref12345.storage.supabase.co/storage/v1/s3",
    "source.storage_access_key": "srcak12345",
    "source.storage_secret_key": "srcsk12345",
    "source.storage_region":     "us-east-1",
    "target.db_url":             "postgresql://postgres:postgres@localhost:5432/postgres",
    "target.storage_endpoint":   "http://localhost:8000/storage/v1/s3",
    "target.storage_access_key": "tgtak12345",
    "target.storage_secret_key": "tgtsk12345",
    "target.storage_region":     "local",
}

missing = [f for f in required if f not in values]
if missing:
    sys.exit("fill_required: migrate.sh requires fields this helper does not "
             "know how to fill: %s" % ", ".join(missing))

section, out = None, []
for line in open(cfg).read().split("\n"):
    top = re.match(r"^([a-z_]+):\s*$", line)
    if top:
        section = top.group(1)
    field = re.match(r"^(\s+)([a-z_]+):[ \t]*(\S*)(.*)$", line)
    if field and section:
        indent, key, val, rest = field.groups()
        name = "%s.%s" % (section, key)
        if name in required and val in ("changeit", ""):
            line = "%s%s: %s%s" % (indent, key, values[name], rest)
    out.append(line)
open(cfg, "w").write("\n".join(out))

# Prove the file no longer holds a placeholder for anything required, rather
# than trusting that the rewrite above matched.
text = open(cfg).read()
section, seen = None, {}
for line in text.split("\n"):
    top = re.match(r"^([a-z_]+):\s*$", line)
    if top:
        section = top.group(1)
    field = re.match(r"^\s+([a-z_]+):[ \t]*(\S*)", line)
    if field and section:
        seen["%s.%s" % (section, field.group(1))] = field.group(2)
unfilled = [f for f in required if seen.get(f, "") in ("changeit", "")]
if unfilled:
    sys.exit("fill_required: still unset after filling: %s" % ", ".join(unfilled))
PY
}

# ─── TC-MIG-001: Missing config file ─────────────────────────────────────────
echo "TC-MIG-001: missing config file"
d="$(make_sandbox tc001)"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "Config file not found"; then
  ok "exits non-zero with clear message"
else
  fail "expected non-zero exit + 'Config file not found' (got rc=$RC)"
fi

# ─── TC-MIG-002: Required fields left as changeit ─────────────────────────────
echo "TC-MIG-002: required fields left as changeit"
d="$(make_sandbox tc002)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "changeit"; then
  ok "exits non-zero listing changeit fields"
else
  fail "expected non-zero exit listing changeit fields (got rc=$RC)"
fi

# ─── TC-MIG-003: Invalid source DSN scheme ────────────────────────────────────
echo "TC-MIG-003: invalid source DSN scheme"
d="$(make_sandbox tc003)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
sed -i 's|db_url: postgresql://postgres.testprojref12345:pwd@db.testprojref12345.supabase.co:6543/postgres|db_url: mysql://user@host/db|' "$d/env/migrate.yml"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "must start with postgresql://"; then
  ok "exits non-zero on invalid DSN scheme"
else
  fail "expected non-zero exit on invalid DSN scheme (got rc=$RC)"
fi

# ─── TC-MIG-004: Source DSN equals target DSN ─────────────────────────────────
echo "TC-MIG-004: source DSN equals target DSN"
d="$(make_sandbox tc004)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
# Make target equal source
sed -i 's|db_url: postgresql://postgres:postgres@localhost:5432/postgres|db_url: postgresql://postgres.testprojref12345:pwd@db.testprojref12345.supabase.co:6543/postgres|' "$d/env/migrate.yml"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "must not be the same database"; then
  ok "exits non-zero when source == target"
else
  fail "expected non-zero exit on source==target (got rc=$RC)"
fi

# ─── TC-MIG-005: Missing required binary ──────────────────────────────────────
echo "TC-MIG-005: missing required binary (rclone)"
d="$(make_sandbox tc005)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
# Remove the rclone stub so it's not on PATH
rm "$d/stub-bin/rclone"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "required binary not found: rclone"; then
  ok "exits non-zero on missing rclone"
else
  fail "expected non-zero exit on missing rclone (got rc=$RC)"
fi

# ─── TC-MIG-006: Non-empty target refusal (relations present) ─────────────────
echo "TC-MIG-006: non-empty target refusal (public tables)"
d="$(make_sandbox tc006)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_PSQL_PUBLIC_TABLES=5 run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "target is not empty"; then
  ok "exits non-zero on non-empty target (public tables)"
else
  fail "expected non-zero exit on non-empty target (got rc=$RC)"
fi

# ─── TC-MIG-007: Non-empty target refusal (auth.users present) ─────────────────
echo "TC-MIG-007: non-empty target refusal (auth.users)"
d="$(make_sandbox tc007)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_PSQL_AUTH_USERS=3 run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "target is not empty"; then
  ok "exits non-zero on non-empty target (auth.users)"
else
  fail "expected non-zero exit on non-empty target (auth.users) (got rc=$RC)"
fi

# ─── TC-MIG-008: Dry-run does not modify anything ─────────────────────────────
echo "TC-MIG-008: dry-run does not invoke any binary"
d="$(make_sandbox tc008)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --dry-run --yes
no_calls=true
for bin in pg_dump pg_restore rclone psql; do
  if [[ -f "$d/stub-bin/$bin.calls" ]]; then
    no_calls=false
    break
  fi
done
if [[ $RC -eq 0 ]] && $no_calls; then
  ok "dry-run exits 0 and invokes no stubbed binary"
else
  fail "dry-run invoked a binary or exited non-zero (rc=$RC)"
fi

# ─── TC-MIG-009: Help output ──────────────────────────────────────────────────
echo "TC-MIG-009: help output"
d="$(make_sandbox tc009)"
run_migrate_rc "$d" --help
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -qi "Usage"; then
  ok "prints usage and exits 0"
else
  fail "expected exit 0 with Usage (got rc=$RC)"
fi

# ─── TC-MIG-010: Non-interactive execution (no TTY) ───────────────────────────
echo "TC-MIG-010: non-interactive (--yes) execution with no TTY"
d="$(make_sandbox tc010)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
OUT="$( cd "$d" && PATH="$d/stub-bin:$PATH" bash migrate.sh --config "$d/env/migrate.yml" --yes </dev/null 2>&1 )" && RC=0 || RC=$?
if [[ $RC -eq 0 ]]; then
  ok "completes non-interactively with --yes and no TTY"
else
  fail "blocked or failed with --yes (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-MIG-011: Full happy path with stubs ───────────────────────────────────
echo "TC-MIG-011: full happy path with stubs"
d="$(make_sandbox tc011)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] \
  && [[ -f "$d/stub-bin/pg_dump.calls" ]] \
  && [[ -f "$d/stub-bin/pg_restore.calls" ]] \
  && [[ -f "$d/stub-bin/rclone.calls" ]]; then
  ok "happy path invokes pg_dump, pg_restore, rclone"
else
  fail "happy path did not invoke all expected binaries (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-MIG-012: Manual-steps report is always printed ────────────────────────
echo "TC-MIG-012: manual-steps report is always printed"
# Reuse tc011 output
if echo "$OUT" | grep -q "MANUAL STEPS" \
  && echo "$OUT" | grep -q "AUTH CONFIGURATION" \
  && echo "$OUT" | grep -q "EDGE FUNCTIONS" \
  && echo "$OUT" | grep -q "CRON JOBS" \
  && echo "$OUT" | grep -q "WEBHOOKS" \
  && echo "$OUT" | grep -q "STORAGE BUCKET CONFIGURATION" \
  && echo "$OUT" | grep -q "CLIENT ENV VARS" \
  && echo "$OUT" | grep -q "USERS MUST LOG IN AGAIN" \
  && echo "$OUT" | grep -q "VAULT"; then
  ok "manual-steps report contains all sections"
else
  fail "manual-steps report missing sections"
fi

# ─── TC-MIG-013: Read-only-source invariant ───────────────────────────────────
echo "TC-MIG-013: read-only-source invariant (no write command against source)"
d="$(make_sandbox tc013)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
# Assert: pg_dump is the only binary pointed at the source DSN
src_dsn="db.testprojref12345.supabase.co"
# Named, not counted. "1 violation(s)" says the source may have been written to
# and gives you no way to find out which of the three checks fired.
violations=()
# pg_restore must never reference the source DSN
if [[ -f "$d/stub-bin/pg_restore.calls" ]] && grep -q "$src_dsn" "$d/stub-bin/pg_restore.calls"; then
  violations+=("pg_restore was pointed at the source DSN")
fi
# rclone must use copy, not sync/move/delete
if [[ -f "$d/stub-bin/rclone.calls" ]]; then
  grep -q "ARG copy" "$d/stub-bin/rclone.calls" \
    || violations+=("rclone ran without 'copy'")
  if grep -qE "ARG (sync|move|delete|purge|rmdir)" "$d/stub-bin/rclone.calls"; then
    violations+=("rclone used a mutating subcommand against the source")
  fi
else
  violations+=("rclone was never called")
fi
# psql may read from the source: migrate.sh works out which schemas to dump by
# querying information_schema. What must never happen is a write.
#
# This used to assert that the source DSN never appeared in psql.calls at all,
# on the stated assumption that "psql is only called against the target in our
# implementation". That stopped being true when schema discovery was added, and
# the assertion was a poor guard even while it held — it would have passed just
# as happily on a DELETE aimed at the target.
if [[ -f "$d/stub-bin/psql.calls" ]]; then
  bad_psql="$(python3 - "$d/stub-bin/psql.calls" "$src_dsn" <<'PY'
import re, sys

calls, src = open(sys.argv[1]).read(), sys.argv[2]
writes = re.compile(r"\b(insert|update|delete|drop|create|alter|truncate|grant|revoke|copy)\b", re.I)
offending = []
for block in calls.split("CALL psql")[1:]:
    args = re.findall(r"^  ARG (.*)$", block, re.M)
    if not any(src in a for a in args):
        continue
    # Everything that is not a flag and not the DSN itself is a statement.
    for arg in args:
        if arg.startswith("-") or src in arg:
            continue
        if not re.match(r"\s*select\b", arg, re.I) or writes.search(arg):
            offending.append(" ".join(arg.split())[:90])
print("\n".join(offending))
PY
)"
  if [[ -n "$bad_psql" ]]; then
    violations+=("psql issued a non-read-only statement against the source: $bad_psql")
  fi
fi
if [[ ${#violations[@]} -eq 0 ]]; then
  ok "no write command issued against source DSN"
else
  fail "read-only-source invariant violated (${#violations[@]} violation(s))"
  for v in "${violations[@]}"; do echo "      - $v"; done
fi

# ─── TC-MIG-014: Storage failure is non-fatal + appears in runtime notes ──────
echo "TC-MIG-014: storage failure is non-fatal + in runtime notes"
d="$(make_sandbox tc014)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_RCLONE_FAIL=1 run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -qi "storage copy failed"; then
  ok "storage failure is non-fatal and reported"
else
  fail "storage failure should be non-fatal (got rc=$RC)"
fi

# ─── TC-MIG-015: Discovered schemas are dumped; a dump failure is fatal ───────
# This used to assert that a missing 'pgsodium' schema was "skipped with a
# warning, not fatal". migrate.sh has no such behaviour and never had: it dumps
# every discovered schema in one pg_dump call and dies if that call fails. The
# test could not even provoke the case, because pgsodium is one of the
# Supabase-managed schemas the probe excludes by name, so the stub's
# fail-on-this-schema hook never fired and the assertion failed on a message
# nothing was ever going to print.
#
# What is worth pinning down is what the script really does: dump exactly the
# schemas the source reported, and refuse to continue when that dump fails —
# silently restoring a partial dump would be far worse than stopping.
echo "TC-MIG-015: discovered schemas are dumped, and a dump failure is fatal"
d="$(make_sandbox tc015)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_PSQL_SCHEMAS="public app_data" run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] \
  && grep -q "ARG --schema=public" "$d/stub-bin/pg_dump.calls" \
  && grep -q "ARG --schema=app_data" "$d/stub-bin/pg_dump.calls"; then
  ok "every schema reported by the source is dumped"
else
  fail "discovered schemas were not all dumped (rc=$RC)"
  grep "ARG --schema" "$d/stub-bin/pg_dump.calls" 2>/dev/null || echo "      (no --schema flags at all)"
fi

# The probe must exclude Supabase-managed schemas: the self-hosted stack
# provisions those itself, and restoring the source's copy over them is how a
# migration corrupts auth or storage.
if grep -q "auth" "$d/stub-bin/psql.calls" \
  && ! grep -q "ARG --schema=auth" "$d/stub-bin/pg_dump.calls"; then
  ok "Supabase-managed schemas are excluded from the dump"
else
  fail "the schema probe does not exclude Supabase-managed schemas"
fi

d="$(make_sandbox tc015b)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_PSQL_SCHEMAS="public app_data" STUB_PGDUMP_FAIL_SCHEMA=app_data \
  run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "pg_dump failed"; then
  ok "a failing dump aborts instead of restoring a partial one"
else
  fail "a failing pg_dump should be fatal (got rc=$RC)"
  echo "$OUT" | tail -10
fi

# ─── TC-MIG-016: env/migrate.example.yml is valid YAML ────────────────────────
echo "TC-MIG-016: env/migrate.example.yml is valid YAML"
if python3 -c "import yaml; d=yaml.safe_load(open('$EXAMPLE')); \
  assert set(['source','target','tools']).issubset(d.keys())" 2>/dev/null; then
  ok "valid YAML with expected top-level keys"
else
  fail "env/migrate.example.yml is not valid YAML or missing top-level keys"
fi

# ─── TC-MIG-017: Unknown flag rejected ────────────────────────────────────────
echo "TC-MIG-017: unknown flag rejected"
d="$(make_sandbox tc017)"
run_migrate_rc "$d" --bogus
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "Unknown option"; then
  ok "exits non-zero on unknown flag"
else
  fail "expected non-zero exit on unknown flag (got rc=$RC)"
fi

# ─── TC-MIG-018: --config is required ──────────────────────────────────────────
echo "TC-MIG-018: --config is required"
d="$(make_sandbox tc018)"
run_migrate_rc "$d" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi -- "--config is required"; then
  ok "exits non-zero when --config missing"
else
  fail "expected non-zero exit when --config missing (got rc=$RC)"
fi

# ─── TC-MIG-019: pg_dump uses read-only-compatible flags ──────────────────────
echo "TC-MIG-019: pg_dump uses read-only-compatible flags"
d="$(make_sandbox tc019)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ -f "$d/stub-bin/pg_dump.calls" ]] \
  && grep -q "ARG --no-owner" "$d/stub-bin/pg_dump.calls" \
  && grep -q "ARG --no-privileges" "$d/stub-bin/pg_dump.calls"; then
  ok "pg_dump invoked with --no-owner --no-privileges"
else
  fail "pg_dump missing --no-owner/--no-privileges flags"
fi

# ─── TC-MIG-020: pg_restore targets the target DSN only ───────────────────────
echo "TC-MIG-020: pg_restore targets the target DSN only (via --dbname=)"
d="$(make_sandbox tc020)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
tgt_dsn="localhost:5432"
src_dsn="db.testprojref12345.supabase.co"
# Strengthened per review (H1): assert the DSN is passed via --dbname= (the
# correct pg_restore connection option), NOT as a bare positional filename.
# pg_restore's positional arg is the archive FILE; the DSN must go via --dbname=.
if [[ -f "$d/stub-bin/pg_restore.calls" ]] \
  && grep -q "ARG --dbname=postgresql://postgres:postgres@${tgt_dsn}/postgres" "$d/stub-bin/pg_restore.calls" \
  && ! grep -q "$src_dsn" "$d/stub-bin/pg_restore.calls"; then
  ok "pg_restore targets target DSN via --dbname=, never source"
else
  fail "pg_restore DSN not passed via --dbname= or targets source"
fi

# ─── TC-MIG-021: Storage bucket definitions are dumped before the object copy ─
echo "TC-MIG-021: storage.buckets dumped before rclone object copy"
d="$(make_sandbox tc021)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
timeline="$d/stub-bin/call-timeline"
# The buckets dump is the pg_dump invocation carrying --table=storage.buckets;
# the object copy is the only rclone invocation. Their order in the shared
# timeline proves Phase 3 precedes Phase 4.
bucket_dump_line="$(grep -n 'storage.buckets' "$timeline" | head -1 | cut -d: -f1)"
copy_pos="$(grep -n '^rclone' "$timeline" | head -1 | cut -d: -f1)"
if [[ -n "$bucket_dump_line" && -n "$copy_pos" ]] \
  && [[ "$bucket_dump_line" -lt "$copy_pos" ]]; then
  ok "storage.buckets dump precedes rclone object copy"
else
  fail "storage.buckets not dumped, or not before rclone (bucket=$bucket_dump_line copy=$copy_pos)"
fi

# ─── TC-MIG-022: Bucket restore is data-only + read-only, never touches source ─
echo "TC-MIG-022: storage.buckets restore is data-only and read-only on source"
d="$(make_sandbox tc022)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
src_dsn="db.testprojref12345.supabase.co"
# The bucket dump must be a data-only, no-owner row restore (read-only flags),
# and neither the dump nor any pg_restore may touch the source DSN.
if grep -q "ARG --data-only" "$d/stub-bin/pg_dump.calls" \
  && grep -q "ARG --no-owner" "$d/stub-bin/pg_dump.calls" \
  && grep -q "ARG --no-privileges" "$d/stub-bin/pg_dump.calls" \
  && grep -q "ARG --table=storage.buckets" "$d/stub-bin/pg_dump.calls" \
  && ! grep -q "$src_dsn" "$d/stub-bin/pg_restore.calls"; then
  ok "bucket restore uses read-only dump flags and never targets the source"
else
  fail "bucket dump flags or read-only-source invariant violated"
fi

# ─── TC-MIG-023: Vault preflight failure is skipped with a note, exit 0 ───────
echo "TC-MIG-023: vault migration skipped when source cannot decrypt"
d="$(make_sandbox tc023)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_PSQL_VAULT_DECRYPT_FAIL=1 run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -qi "vault migration skipped"; then
  ok "vault preflight failure is non-fatal and reported"
else
  fail "vault preflight failure should be non-fatal (got rc=$RC)"
fi

# ─── TC-MIG-024: Vault secrets re-created on target via vault.create_secret ───
echo "TC-MIG-024: vault secrets re-encrypted on target via vault.create_secret"
d="$(make_sandbox tc024)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
# One secret: name "api-key", decrypted value "sk_live_abc", no description.
STUB_PSQL_VAULT_COUNT=1 STUB_PSQL_VAULT_ROWS=$'api-key\tsk_live_abc\t' \
  run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "vault secrets re-created"; then
  ok "vault secrets re-created on target"
else
  fail "vault secrets were not re-created (rc=$RC)"
  echo "$OUT" | tail -10
fi
# The target psql invocation must carry -f <sqlscript> and the read-only-source
# invariant must still hold — no write statement issued against the source.
src_dsn="db.testprojref12345.supabase.co"
bad_psql="$(python3 - "$d/stub-bin/psql.calls" "$src_dsn" <<'PY'
import re, sys
calls, src = open(sys.argv[1]).read(), sys.argv[2]
writes = re.compile(r"\b(insert|update|delete|drop|create|alter|truncate|grant|revoke|copy)\b", re.I)
offending = []
for block in calls.split("CALL psql")[1:]:
    args = re.findall(r"^  ARG (.*)$", block, re.M)
    if not any(src in a for a in args):
        continue
    for arg in args:
        if arg.startswith("-") or src in arg:
            continue
        if not re.match(r"\s*select\b", arg, re.I) or writes.search(arg):
            offending.append(" ".join(arg.split())[:90])
print("\n".join(offending))
PY
)"
if [[ -z "$bad_psql" ]]; then
  ok "read-only-source invariant holds during vault migration"
else
  fail "vault migration issued a write against the source: $bad_psql"
fi

# ─── TC-MIG-025: No vault secrets → clean "none" result ───────────────────────
echo "TC-MIG-025: no vault secrets produces a clean no-op"
d="$(make_sandbox tc025)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_PSQL_VAULT_COUNT=0 run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "no vault secrets to migrate"; then
  ok "zero vault secrets handled cleanly"
else
  fail "zero vault secrets not handled cleanly (rc=$RC)"
fi

# ─── TC-MIG-026: functions disabled → edge phases skipped ───────────────────
echo "TC-MIG-026: functions.enabled=false skips edge-function phases cleanly"
d="$(make_sandbox tc026)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
sed -i 's|^  enabled: true|  enabled: false|' "$d/env/migrate.yml"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] \
  && echo "$OUT" | grep -qi "Phase 6 skipped (functions.enabled is false)" \
  && echo "$OUT" | grep -qi "Phase 7 skipped (functions.enabled is false)" \
  && [[ ! -f "$d/stub-bin/supabase.calls" ]]; then
  ok "edge phases skipped and Supabase CLI never invoked"
else
  fail "functions disabled should skip edge phases without CLI calls (rc=$RC)"
fi

# ─── TC-MIG-027: Edge functions happy path (download → copy → restart) ───────
echo "TC-MIG-027: edge functions downloaded, copied into mount, service restarted"
d="$(make_sandbox tc027)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
mkdir -p "$d/funcs"
sed -i "s|target_dir: supabase/docker/volumes/functions|target_dir: $d/funcs|" "$d/env/migrate.yml"
STUB_SUPABASE_FUNCTIONS="$(
  printf '%s\n' 'c731abc  my-func   DEPLOYED  1  2024-01-01T00:00:00Z  2024-01-01T00:00:00Z'
  printf '%s\n' '8f2d00e  helper    DEPLOYED  2  2024-01-01T00:00:00Z  2024-01-01T00:00:00Z'
  printf '%s\n' 'a1b2c3d  my-func   DEPLOYED  1  2024-01-01T00:00:00Z  2024-01-01T00:00:00Z' # dup slug
)" STUB_SUPABASE_SECRETS="$(
  printf '%s\n' 'abc12  SEMAPHORE'
  printf '%s\n' 'def34  REDIS_URL'
)" \
  run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] \
  && [[ -d "$d/funcs/my-func" && -f "$d/funcs/my-func/index.ts" ]] \
  && [[ -d "$d/funcs/helper" && -f "$d/funcs/helper/index.ts" ]] \
  && grep -q "ARG download" "$d/stub-bin/supabase.calls" \
  && grep -qE "ARG restart" "$d/stub-bin/docker.calls" \
  && grep -qE "ARG functions" "$d/stub-bin/docker.calls" \
  && ! grep -qE "ARG deploy" "$d/stub-bin/supabase.calls"; then
  ok "functions downloaded, copied (deduped), container restarted, never deployed"
else
  fail "edge happy path broken (rc=$RC)"
  echo "$OUT" | tail -20
fi
# The secret NAMES must be staged as empty entries in .env.functions.
ENV_FUNCS="$d/funcs/.env.functions"
if [[ -f "$ENV_FUNCS" ]] \
  && grep -qE '^SEMAPHORE=$' "$ENV_FUNCS" && grep -qE '^REDIS_URL=$' "$ENV_FUNCS"; then
  ok "secret names staged as empty NAME= entries in .env.functions"
else
  fail ".env.functions missing expected secret name entries"
fi
# Phase-7 note must instruct value fill + container recreate.
echo "$OUT" | grep -qi "force-recreate functions" \
  && ok "report instructs operator to fill secrets and recreate the container" \
  || fail "report missing recreate-instruction for secret values"

# ─── TC-MIG-028: no functions on source → clean skip ─────────────────────────
echo "TC-MIG-028: empty function list produces a clean skip (exit 0)"
d="$(make_sandbox tc028)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_SUPABASE_FUNCTIONS="" run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -qi "no edge functions on the source"; then
  ok "no functions on source handled cleanly"
else
  fail "empty function list not handled cleanly (rc=$RC)"
fi

# ─── TC-MIG-029: missing Supabase CLI → graceful skip, not a failure ─────────
echo "TC-MIG-029: missing Supabase CLI skips edge phases without failing"
d="$(make_sandbox tc029)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
# Point tools.supabase at a path that cannot exist so the missing-CLI branch is
# exercised even on a machine where a real `supabase` binary is installed.
sed -i 's|^  supabase: supabase$|  supabase: /nonexistent/supabase-cli|' "$d/env/migrate.yml"
run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] \
  && echo "$OUT" | grep -qi "Supabase CLI not found — skipping edge-function code migration" \
  && echo "$OUT" | grep -qi "skipping edge-function secrets"; then
  ok "edge phases skipped gracefully when the CLI is absent"
else
  fail "missing CLI should yield a graceful skip (rc=$RC)"
fi

# ─── TC-MIG-030: secrets staging never clobbers an existing .env.functions ────
echo "TC-MIG-030: existing .env.functions entries are never overwritten"
d="$(make_sandbox tc030)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
mkdir -p "$d/funcs"
sed -i "s|target_dir: supabase/docker/volumes/functions|target_dir: $d/funcs|" "$d/env/migrate.yml"
printf 'SEMAPHORE=sk_real_value\n' > "$d/funcs/.env.functions"
STUB_SUPABASE_SECRETS="$(
  printf '%s\n' 'abc12  SEMAPHORE'
  printf '%s\n' 'def34  NEW_SECRET'
)" run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if grep -q '^SEMAPHORE=sk_real_value$' "$d/funcs/.env.functions" \
  && grep -qE '^NEW_SECRET=$' "$d/funcs/.env.functions"; then
  ok "existing value preserved; only new name appended"
else
  fail "existing secret value clobbered, or new name not appended"
  cat "$d/funcs/.env.functions"
fi

# ─── TC-MIG-031: read-only-source invariant holds for the Supabase CLI ───────
echo "TC-MIG-031: Supabase CLI is never asked to deploy (deploy targets Cloud)"
d="$(make_sandbox tc031)"
cp "$d/env/migrate.example.yml" "$d/env/migrate.yml"
fill_required "$d"
STUB_SUPABASE_FUNCTIONS="c731abc  my-func   DEPLOYED  1  2024-01-01T00:00:00Z  2024-01-01T00:00:00Z" \
  run_migrate_rc "$d" --config "$d/env/migrate.yml" --yes
if [[ $RC -eq 0 ]] && [[ -f "$d/stub-bin/supabase.calls" ]] \
  && ! grep -qE "ARG functions deploy|ARG deploy" "$d/stub-bin/supabase.calls"; then
  ok "no 'supabase functions deploy' issued against Cloud"
else
  fail "read-only-source invariant violated by the CLI (deploy issued)"
  cat "$d/stub-bin/supabase.calls" 2>/dev/null
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]