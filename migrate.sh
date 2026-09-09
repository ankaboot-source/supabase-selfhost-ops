#!/bin/bash
# =============================================================================
# migrate.sh — Migrate a Supabase Cloud project into a self-hosted instance.
# =============================================================================
# Walking skeleton: schema+data, auth users (UUIDs preserved), storage bucket
# definitions + objects, vault secrets (re-encrypted on the target), and a
# manual-steps report. Read-only against the source. Refuses a non-empty target.
# No resumability — a failure means starting over.
#
# The script is ALWAYS read-only against the source:
#   - pg_dump (no write flags) reads the source.
#   - psql against the source is only ever SELECT.
#   - All writes (pg_restore, rclone, vault.create_secret) target the target DSN.
#
# Usage:
#   ./migrate.sh --config env/migrate.yml --yes
#   ./migrate.sh --config env/migrate.yml --dry-run
#   ./migrate.sh --help
#
# Conventions mirror setup.sh: YAML config, non-interactive by default, flags
# are verbs only. See docs/designs/migration-layer-1.md for the full design.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_CONFIG="${SCRIPT_DIR}/env/migrate.example.yml"

CONFIG_FILE=""
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0

# ─── Colors (disabled when not a TTY — runs with no TTY attached) ───────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()     { printf "${BLUE}[migrate]${NC} %s\n" "$*"; }
ok()      { printf "${GREEN}[ok]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[warn]${NC} %s\n" "$*" >&2; }
die()     { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
migrate.sh — Migrate a Supabase Cloud project into a self-hosted instance (Layer 1)

Usage:
  ./migrate.sh --config <path> [options]

Options:
  --config <path>   Path to the migration config file (required)
  --dry-run         Preview the migration plan without modifying anything
  --yes             Non-interactive (skip confirmation prompts) — for AI/CI
  -v, --verbose     Verbose output
  -h, --help        Show this help and exit

Workflow:
  1. Copy env/migrate.example.yml to env/migrate.yml
  2. Edit the SOURCE and TARGET sections in env/migrate.yml
  3. Run: ./migrate.sh --config env/migrate.yml --yes

The script:
  - Validates the config (required fields, DSN schemes, source != target)
  - Asserts required binaries are on PATH (pg_dump, pg_restore, rclone, psql)
  - Refuses to run against a non-empty target
  - Dumps and restores the database (schema + data, Supabase-managed schemas)
  - Migrates auth.users and auth.identities with UUIDs preserved
  - Restores storage bucket definitions (required for the object copy)
  - Copies storage objects via rclone (read-only against source)
  - Migrates vault secrets, re-encrypted on the target
  - Prints a manual-steps report listing everything NOT migrated

INVARIANT: read-only against the source project. Always. At every layer.
EOF
}

# ─── Argument parsing (verbs only, matches setup.sh style) ───────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --yes)      ASSUME_YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ $VERBOSE -eq 1 ]] && set -x

# --config is required
[[ -n "$CONFIG_FILE" ]] || die "--config is required. Usage: ./migrate.sh --config env/migrate.yml --yes"

# ─── Preflight: config file exists ───────────────────────────────────────────
[[ -f "$EXAMPLE_CONFIG" ]] || die "env/migrate.example.yml not found in $SCRIPT_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "Config file not found: $CONFIG_FILE

  Copy the example and edit it:
    cp env/migrate.example.yml env/migrate.yml
    # edit env/migrate.yml, then re-run:
    ./migrate.sh --config env/migrate.yml --yes"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required (YAML parsing depends on it). Install with: sudo apt install -y python3"

# ─── YAML parsing via python3 (same pattern as setup.sh) ─────────────────────
# Reads a value from the config. Usage: cfg_get "source.project_ref"
cfg_get() {
  python3 - "$CONFIG_FILE" "$1" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
keys = sys.argv[2].split('.')
node = data
for k in keys:
    if isinstance(node, dict) and k in node:
        node = node[k]
    else:
        print("")
        sys.exit(0)
if isinstance(node, bool):
    print("true" if node else "false")
elif isinstance(node, (list, dict)):
    print(yaml.dump(node, default_flow_style=False).strip())
else:
    print(node if node is not None else "")
PYEOF
}

# ─── Config validation ───────────────────────────────────────────────────────
log "Validating $CONFIG_FILE…"

REQUIRED_FIELDS=(
  "source.project_ref"
  "source.db_url"
  "source.storage_endpoint"
  "source.storage_access_key"
  "source.storage_secret_key"
  "source.storage_region"
  "target.db_url"
  "target.storage_endpoint"
  "target.storage_access_key"
  "target.storage_secret_key"
  "target.storage_region"
)

MISSING=()
for field in "${REQUIRED_FIELDS[@]}"; do
  val="$(cfg_get "$field")"
  if [[ -z "$val" || "$val" == "changeit" ]]; then
    MISSING+=("$field")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  die "The following fields in $CONFIG_FILE are still set to 'changeit' or empty:

  $(printf '  - %s\n' "${MISSING[@]}")

Edit $CONFIG_FILE and fill in every field under SOURCE and TARGET."
fi

# Resolve tool paths (defaults via PATH, overridable in config)
PG_DUMP="$(cfg_get "tools.pg_dump")";    PG_DUMP="${PG_DUMP:-pg_dump}"
PG_RESTORE="$(cfg_get "tools.pg_restore")"; PG_RESTORE="${PG_RESTORE:-pg_restore}"
RCLONE="$(cfg_get "tools.rclone")";      RCLONE="${RCLONE:-rclone}"
PSQL="$(cfg_get "tools.psql")";          PSQL="${PSQL:-psql}"

# DSN scheme validation
SRC_DB_URL="$(cfg_get "source.db_url")"
TGT_DB_URL="$(cfg_get "target.db_url")"

[[ "$SRC_DB_URL" == postgresql://* || "$SRC_DB_URL" == postgres://* ]] \
  || die "source.db_url must start with postgresql:// (got: ${SRC_DB_URL:0:20}…)"
[[ "$TGT_DB_URL" == postgresql://* || "$TGT_DB_URL" == postgres://* ]] \
  || die "target.db_url must start with postgresql:// (got: ${TGT_DB_URL:0:20}…)"

# Read-only-source invariant: source != target
if [[ "$SRC_DB_URL" == "$TGT_DB_URL" ]]; then
  die "source.db_url and target.db_url must not be the same database.
  The source project is read-only; migrating a database into itself is refused."
fi

# ─── Required binaries on PATH ───────────────────────────────────────────────
log "Checking required binaries…"
for bin in "$PG_DUMP" "$PG_RESTORE" "$RCLONE" "$PSQL"; do
  command -v "$bin" >/dev/null 2>&1 || die "required binary not found: $bin"
done
ok "All required binaries found."

# Capture runtime notes for the manual-steps report.
RUNTIME_NOTES=()
add_note() { RUNTIME_NOTES+=("$1"); }

# ─── Temp files + cleanup ────────────────────────────────────────────────────
# Single LOG_DIR for all error logs (avoids /tmp collisions on concurrent runs).
# Temp dump/config files are declared empty here so cleanup() is safe even if
# the script exits before they are created.
LOG_DIR="$(mktemp -d -t migrate-logs-XXXXXX)"
DUMP_FILE=""
AUTH_DUMP=""
BUCKET_DUMP=""
VAULT_ROWS=""
VAULT_SQL=""
RCLONE_CONF=""
cleanup() {
  rm -f "$DUMP_FILE" "$AUTH_DUMP" "$BUCKET_DUMP" "$VAULT_ROWS" "$VAULT_SQL" "$RCLONE_CONF"
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT

# ─── Dry-run: print plan and exit ─────────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY RUN — no files will be modified, no commands will execute."
  log "Plan:"
  log "  Phase 1: pg_dump source → pg_restore target (schema + data)"
  log "    source DSN: ${SRC_DB_URL}"
  log "    target DSN: ${TGT_DB_URL}"
  log "    schemas: auto-discovered (excluding Supabase system schemas: auth, storage, realtime, etc.)"
  log "  Phase 2: pg_dump auth.users + auth.identities → pg_restore target (UUIDs preserved)"
  log "  Phase 3: pg_dump storage.buckets → pg_restore target (bucket definitions)"
  log "  Phase 4: rclone copy source-storage → target-storage (read-only against source)"
  log "  Phase 5: vault secrets → re-encrypted on the target via vault.create_secret"
  log "  Phase 6: print manual-steps report"
  ok "Dry run complete. Re-run without --dry-run to migrate."
  exit 0
fi

# ─── Confirmation ─────────────────────────────────────────────────────────────
if [[ $ASSUME_YES -eq 0 ]]; then
  printf "About to migrate:\n  source: %s\n  target: %s\n\n" "$SRC_DB_URL" "$TGT_DB_URL"
  printf "This accepts DOWNTIME. The target will be written to; the source is read-only.\n"
  read -rp "Proceed? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

# ─── Non-empty target refusal ─────────────────────────────────────────────────
log "Checking target is empty…"

# Count base tables in public schema (target only — read-only probe).
# A connection failure to the target must NOT be masked as "empty" — die with
# the real psql error so the operator fixes the DSN before any restore runs.
if ! tgt_public_tables=$("$PSQL" "$TGT_DB_URL" -tAX \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';" 2>"$LOG_DIR/psql-public.err"); then
  die "cannot reach target database (public-tables probe failed).
  Verify target.db_url is correct and the database is running.
  psql error: $(cat "$LOG_DIR/psql-public.err")"
fi
if ! tgt_auth_users=$("$PSQL" "$TGT_DB_URL" -tAX \
  -c "SELECT count(*) FROM auth.users;" 2>"$LOG_DIR/psql-auth.err"); then
  die "cannot reach target database (auth.users probe failed).
  Verify target.db_url is correct and the database is running.
  psql error: $(cat "$LOG_DIR/psql-auth.err")"
fi

reasons=()
[[ "${tgt_public_tables:-0}" -gt 0 ]] && reasons+=("${tgt_public_tables} base table(s) in schema 'public'")
[[ "${tgt_auth_users:-0}" -gt 0 ]]    && reasons+=("${tgt_auth_users} row(s) in auth.users")
if [[ ${#reasons[@]} -gt 0 ]]; then
  die "target is not empty — Layer 1 migrates into a fresh instance only.
  Found: $(printf '%s, ' "${reasons[@]}" | sed 's/, $//').
  Re-provision the target and re-run."
fi
ok "Target is empty."

# ─── Phase 1: Database — schema + data ────────────────────────────────────────
log "Phase 1: dumping and restoring schema + data…"

# Probe source for user schemas only — exclude Postgres built-in, temporary
# system schemas, and Supabase-managed schemas (auth, storage, realtime, etc.)
# that are already provisioned by the self-hosted stack. User data from auth
# and storage is handled by Phase 2 and Phase 3 respectively.
log "  probing source schemas (excluding Supabase system schemas)…"
source_schemas=$("$PSQL" "$SRC_DB_URL" -tAX \
  -c "SELECT schema_name FROM information_schema.schemata
      WHERE schema_name NOT IN (
              'pg_catalog','information_schema','pg_toast',
              'auth','storage','realtime','extensions',
              'graphql','graphql_public','pgbouncer','vault','pgsodium')
        AND schema_name NOT LIKE 'pg\_temp\_%'
        AND schema_name NOT LIKE 'pg\_toast\_temp\_%'
      ORDER BY schema_name;" 2>"$LOG_DIR/probe.err") \
  || die "cannot reach source database (probe failed)."

SCHEMA_FLAGS=()
while IFS= read -r s; do
  [[ -n "$s" ]] && SCHEMA_FLAGS+=(--schema="$s")
done <<< "$source_schemas"

[[ ${#SCHEMA_FLAGS[@]} -eq 0 ]] && die "no schemas found on source — nothing to migrate."
log "  schemas to migrate (user schemas only): ${SCHEMA_FLAGS[*]}"

DUMP_FILE="$(mktemp -t migrate-dump-XXXXXX.dump)"
log "  dumping database…"
"$PG_DUMP" "$SRC_DB_URL" --format=custom --no-owner --no-privileges \
  "${SCHEMA_FLAGS[@]}" --file="$DUMP_FILE" 2>"$LOG_DIR/dump.err" \
  || die "pg_dump failed. See $LOG_DIR/dump.err."

log "  restoring all schemas…"
if ! "$PG_RESTORE" --dbname="$TGT_DB_URL" --no-owner --no-privileges \
     "$DUMP_FILE" 2>"$LOG_DIR/restore.err"; then
  warn "restore had errors — see $LOG_DIR/restore.err"
  add_note "Restore had errors. See $LOG_DIR/restore.err."
fi
rm -f "$DUMP_FILE"
ok "Phase 1 complete (schema + data)."

# ─── Phase 2: Auth users (UUIDs preserved) ───────────────────────────────────
log "Phase 2: migrating auth.users and auth.identities (UUIDs preserved)…"

# Data-only dump of auth.users and auth.identities. UUIDs are preserved because
# we dump with --data-only (INSERT copy via COPY), not --schema-only.
AUTH_DUMP="$(mktemp -t migrate-auth-XXXXXX.dump)"
if "$PG_DUMP" "$SRC_DB_URL" \
      --format=custom \
      --no-owner --no-privileges \
      --data-only \
      --table="auth.users" \
      --table="auth.identities" \
      --file="$AUTH_DUMP" 2>"$LOG_DIR/auth-dump.err"; then
  # pg_restore: DSN via --dbname=, archive file as the sole positional (see Phase 1).
  "$PG_RESTORE" \
    --dbname="$TGT_DB_URL" \
    --no-owner --no-privileges \
    --data-only \
    --exit-on-error \
    "$AUTH_DUMP" 2>"$LOG_DIR/auth-restore.err" \
    || { warn "auth.users restore failed — see $LOG_DIR/auth-restore.err"; add_note "auth.users restore failed. See $LOG_DIR/auth-restore.err."; }
  ok "Phase 2 complete (auth users migrated with UUIDs preserved)."
else
  warn "auth.users dump failed — see $LOG_DIR/auth-dump.err"
  add_note "auth.users dump failed. See $LOG_DIR/auth-dump.err. Users must be re-created manually."
fi
rm -f "$AUTH_DUMP"

# ─── Phase 3: Storage bucket definitions (before the object copy) ────────────
# Bucket definitions (id, name, public, file_size_limit, allowed_mime_types,
# created_at, updated_at) must exist on the target BEFORE rclone copies objects
# into them — otherwise the object copy hits NoSuchBucket on a fresh instance.
# Data-only row restore of storage.buckets; the target's own storage schema
# provides the DDL. Per-bucket RLS policies are NOT migrated (they live in
# pg_catalog.pg_policy, not storage.policies, and the stack seeds its own
# defaults) — those remain a manual step.
log "Phase 3: restoring storage bucket definitions…"

BUCKET_DUMP="$(mktemp -t migrate-buckets-XXXXXX.dump)"
if "$PG_DUMP" "$SRC_DB_URL" \
      --format=custom \
      --no-owner --no-privileges \
      --data-only \
      --table="storage.buckets" \
      --file="$BUCKET_DUMP" 2>"$LOG_DIR/bucket-dump.err"; then
  if "$PG_RESTORE" \
      --dbname="$TGT_DB_URL" \
      --no-owner --no-privileges \
      --data-only \
      --exit-on-error \
      "$BUCKET_DUMP" 2>"$LOG_DIR/bucket-restore.err"; then
    ok "Phase 3 complete (storage bucket definitions restored)."
  else
    warn "storage.buckets restore failed — see $LOG_DIR/bucket-restore.err"
    add_note "storage.buckets restore failed. Object copy may hit NoSuchBucket."
  fi
else
  warn "storage.buckets dump failed — see $LOG_DIR/bucket-dump.err"
  add_note "storage.buckets dump failed. Bucket definitions must be re-created manually before object copy."
fi
rm -f "$BUCKET_DUMP"

# ─── Phase 4: Storage objects (rclone copy — read-only against source) ───────
log "Phase 4: copying storage objects via rclone (read-only against source)…"

SRC_STORAGE_ENDPOINT="$(cfg_get "source.storage_endpoint")"
SRC_STORAGE_AK="$(cfg_get "source.storage_access_key")"
SRC_STORAGE_SK="$(cfg_get "source.storage_secret_key")"
SRC_STORAGE_REGION="$(cfg_get "source.storage_region")"
TGT_STORAGE_ENDPOINT="$(cfg_get "target.storage_endpoint")"
TGT_STORAGE_AK="$(cfg_get "target.storage_access_key")"
TGT_STORAGE_SK="$(cfg_get "target.storage_secret_key")"
TGT_STORAGE_REGION="$(cfg_get "target.storage_region")"

# Build ephemeral rclone config. rclone reads config from a file via --config.
RCLONE_CONF="$(mktemp -t migrate-rclone-XXXXXX.conf)"
cat > "$RCLONE_CONF" <<EOF
[src]
type = s3
provider = Supabase
endpoint = ${SRC_STORAGE_ENDPOINT}
access_key_id = ${SRC_STORAGE_AK}
secret_access_key = ${SRC_STORAGE_SK}
region = ${SRC_STORAGE_REGION}

[tgt]
type = s3
provider = Supabase
endpoint = ${TGT_STORAGE_ENDPOINT}
access_key_id = ${TGT_STORAGE_AK}
secret_access_key = ${TGT_STORAGE_SK}
region = ${TGT_STORAGE_REGION}
EOF

# rclone copy (NOT sync, NOT move) — source is never mutated.
# --progress=no keeps output TTY-free (runs with no TTY attached).
if "$RCLONE" --config "$RCLONE_CONF" copy src: tgt: \
     --progress=no 2>"$LOG_DIR/rclone.err"; then
  ok "Phase 4 complete (storage objects copied)."
else
  warn "storage copy failed — see $LOG_DIR/rclone.err (best-effort at this layer)"
  add_note "Storage copy failed. See $LOG_DIR/rclone.err. Re-run rclone manually after fixing the config."
fi

# ─── Phase 5: Vault secrets (re-encrypted on the target) ─────────────────────
# vault.secrets values are pgsodium ciphertext bound to the SOURCE root key, so
# they cannot be moved verbatim — a data-only restore would yield undecryptable
# ciphertext on the target. Instead: decrypt each secret on the source (SELECT
# via vault.decrypted_secrets, read-only) and re-create it on the target via
# vault.create_secret, which encrypts with the TARGET's own root key.
log "Phase 5: migrating vault secrets (re-encrypted on the target)…"

# Preflight: the source DSN must be able to decrypt. If it cannot (the pooler
# role lacks pgsodium privileges), skip the phase with a manual note rather than
# failing the whole migration.
if ! "$PSQL" "$SRC_DB_URL" -tAX \
     -c "SELECT count(*) FROM vault.decrypted_secrets;" 2>"$LOG_DIR/vault-preflight.err"; then
  warn "vault migration skipped: source cannot decrypt vault.decrypted_secrets."
  warn "  Grant the source role access to pgsodium, or re-create vault secrets manually."
  add_note "Vault migration skipped: source cannot decrypt. Secrets must be re-created manually."
else
  VAULT_ROWS="$(mktemp -t migrate-vault-rows-XXXXXX.tsv)"
  VAULT_SQL="$(mktemp -t migrate-vault-XXXXXX.sql)"

  # Read each secret (name, decrypted_secret, description) from the source.
  # This is a SELECT-only statement — the read-only-source invariant holds.
  "$PSQL" "$SRC_DB_URL" -tAX -F $'\t' \
    -c "SELECT name, decrypted_secret, COALESCE(description, '') FROM vault.decrypted_secrets;" \
    2>"$LOG_DIR/vault-read.err" > "$VAULT_ROWS" \
    || { warn "could not read vault.decrypted_secrets — see $LOG_DIR/vault-read.err"; add_note "Vault read failed. See $LOG_DIR/vault-read.err."; }

  # Build a single SQL script (proper single-quote escaping via python) that
  # re-creates each secret on the target via vault.create_secret.
  python3 - "$VAULT_ROWS" "$VAULT_SQL" <<'PY' || warn "could not build vault SQL script"
import sys

rows_path, sql_path = sys.argv[1], sys.argv[2]

def esc(s):
    # Double any single quotes so the value is a valid SQL string literal.
    return s.replace("'", "''")

statements = []
seen = set()
with open(rows_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        # TSV: name \t decrypted_secret \t description
        parts = line.split("\t", 2)
        # Secrets may contain tabs only if the last column (description) is
        # absent; re-join with a guard: the decrypted secret is expected on
        # column 2, description on column 3. If fewer than 3 parts, pad.
        while len(parts) < 3:
            parts.append("")
        name, secret, desc = parts[0], parts[1], parts[2]
        # If tabs are truly embedded (unlikely for names/secrets), the safest
        # behaviour is to keep the value as-is; names with tabs are nonsense.
        if name in seen or not name:
            continue
        seen.add(name)
        stmt = "SELECT vault.create_secret('%s'::text, '%s'::text, NULLIF('%s','')::text);" \
               % (esc(name), esc(secret), esc(desc))
        statements.append(stmt)
if statements:
    with open(sql_path, "w") as f:
        f.write("\n".join(statements) + "\n")

if not statements:
    sys.stderr.write("vault: no secrets to migrate\n")
PY

  if [[ ! -s "$VAULT_SQL" ]]; then
    ok "Phase 5 complete (no vault secrets to migrate)."
  elif "$PSQL" "$TGT_DB_URL" -q -v ON_ERROR_STOP=1 -f "$VAULT_SQL" \
       2>"$LOG_DIR/vault-restore.err"; then
    ok "Phase 5 complete (vault secrets re-created on the target)."
  else
    warn "vault create failed — see $LOG_DIR/vault-restore.err"
    add_note "Vault migration had errors. See $LOG_DIR/vault-restore.err. Re-check secrets manually."
  fi
  rm -f "$VAULT_ROWS" "$VAULT_SQL"
fi

# ─── Phase 6: Manual-steps report ────────────────────────────────────────────
print_manual_steps() {
  cat <<'REPORT'
================================================================================
 MANUAL STEPS — complete these by hand. Migration is NOT finished until you do.
================================================================================

1. AUTH CONFIGURATION (not migrated)
   - [ ] Review and re-create auth providers in the self-hosted Studio:
         Dashboard → Authentication → Providers
   - [ ] Re-create any custom email templates (Dashboard → Auth → Email Templates)
   - [ ] Re-configure SMTP settings (already in env/supabase.yml — verify)
   - [ ] Re-create any MFA / SAML / hooks configuration

2. EDGE FUNCTIONS (not migrated automatically — code is not retrievable from Cloud)
   - [ ] Copy your function source from your project repo (supabase/functions/<name>/index.ts)
   - [ ] Deploy each onto the self-hosted host: copy the folder into
         <supabase_path>/volumes/functions/ and: docker compose restart functions
   - [ ] Re-create any function secrets/env vars as a .env.functions override

3. CRON JOBS (migrated best-effort via the schema dump)
   - [x] pg_cron job definitions carried over by the schema+data restore
   - [ ] Verify on the target: SELECT * FROM cron.job;

4. WEBHOOKS (migrated best-effort via the schema dump)
   - [x] Database webhook definitions (supabase_webhooks.hooks) carried over
   - [ ] Verify the hooks were reinstalled onto their tables (Dashboard → Database → Webhooks)

5. STORAGE BUCKET CONFIGURATION (definitions migrated; RLS policies manual)
   - [x] Bucket definitions (public/private, file size limits, MIME types) — migrated
   - [ ] Re-create any per-bucket RLS policies (not migrated)

6. VAULT (re-encrypted on the target, when the source could decrypt)
   - [ ] If the vault phase was skipped (source could not decrypt), re-create
         secrets manually in the self-hosted Dashboard → Database → Vault
   - [ ] Note: secrets were re-encrypted with the target root key; the original
         key_id is not preserved (functionally equivalent)

7. CLIENT ENV VARS (operator action)
   - [ ] Update your application's NEXT_PUBLIC_SUPABASE_URL / VITE_SUPABASE_URL
         to point at the self-hosted API URL
   - [ ] Update NEXT_PUBLIC_SUPABASE_ANON_KEY / VITE_SUPABASE_ANON_KEY
         to the self-hosted anon key (from env/supabase.yml)

8. USERS MUST LOG IN AGAIN
   - [ ] Notify users that sessions are invalidated; password hashes migrated,
         so existing passwords still work.

RUNTIME NOTES (discovered during this run):
REPORT
  if [[ ${#RUNTIME_NOTES[@]} -eq 0 ]]; then
    printf -- "- (none)\n"
  else
    for note in "${RUNTIME_NOTES[@]}"; do
      printf -- "- %s\n" "$note"
    done
  fi
  printf '================================================================================\n'
}

log "Phase 6: printing manual-steps report…"
print_manual_steps
ok "Migration complete. Complete the manual steps above to finish."