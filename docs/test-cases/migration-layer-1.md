# Test Cases: Migration Script (Layer 1) — `migrate.sh`

Feature: One-command migration of a Supabase Cloud project into a self-hosted
instance (`migrate.sh` + `env/migrate.example.yml`)
Issue: #99

## Scope

Layer 1 is the walking skeleton: schema+data, auth users (UUIDs preserved),
storage bucket definitions + objects, vault secrets (re-encrypted on the target),
and a manual-steps report. No verification, dry-run-only side effects, no
resumability, no auth-config import. The script is read-only against the source
and refuses a non-empty target.

Tests are shell-level (mirroring `tests/test-setup.sh`): they sandbox the
script and stub `pg_dump`, `pg_restore`, `rclone`, and `psql` so they run
without a real Supabase project or database. The stubs record the argv they
received so tests can assert the **read-only-source invariant** (no write
command is ever issued against the source DSN).

## Test Scenarios

### TC-MIG-001: Missing config file
- **Given**: no `env/migrate.yml`
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits non-zero with a clear error pointing to `env/migrate.example.yml`

### TC-MIG-002: Required fields left as "changeit"
- **Given**: `env/migrate.yml` with `source.project_ref: changeit`
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits non-zero, listing every field still set to `changeit`

### TC-MIG-003: Invalid source DSN scheme
- **Given**: `source.db_url: mysql://user@host/db` (not postgresql://)
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits non-zero with "must start with postgresql://"

### TC-MIG-004: Source DSN equals target DSN (read-only-source invariant)
- **Given**: `source.db_url` and `target.db_url` are identical
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits non-zero with "source and target must not be the same database"

### TC-MIG-005: Missing required binary
- **Given**: `rclone` not on PATH (PATH scrubbed in sandbox)
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits non-zero with "required binary not found: rclone"

### TC-MIG-006: Non-empty target refusal (relations present)
- **Given**: stubbed `psql` returns count > 0 for `public` tables
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits non-zero with "target is not empty" before any `pg_dump`/`pg_restore` runs

### TC-MIG-007: Non-empty target refusal (auth.users present)
- **Given**: stubbed `psql` returns count > 0 for `auth.users`
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits non-zero with "target is not empty"

### TC-MIG-008: Dry-run does not modify anything
- **Given**: valid config + stubbed binaries
- **When**: `bash migrate.sh --config env/migrate.yml --dry-run --yes`
- **Then**: exits 0, prints the plan (phases + commands), and no stubbed
  `pg_dump`/`pg_restore`/`rclone`/`psql` is invoked

### TC-MIG-009: Help output
- **When**: `bash migrate.sh --help`
- **Then**: prints usage with all supported flags and exits 0

### TC-MIG-010: Non-interactive execution (no TTY)
- **Given**: valid config + stubbed binaries + `</dev/null`
- **When**: `bash migrate.sh --config env/migrate.yml --yes </dev/null`
- **Then**: completes without blocking on stdin; stubs record expected commands

### TC-MIG-011: Full happy path with stubs
- **Given**: valid config + stubbed binaries (psql returns 0 for both counts)
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits 0, invokes `pg_dump` against source DSN, invokes `pg_restore`
  against target DSN, lists source storage via `rclone lsf -R` and uploads each
  object to the target Storage REST API (never mutating the source), and prints the
  manual-steps report

### TC-MIG-012: Manual-steps report is always printed
- **Given**: any successful run (happy path)
- **When**: the script completes
- **Then**: stdout contains the "MANUAL STEPS" header and all numbered sections
  (auth config, edge functions, cron/webhooks [migrated best-effort], storage bucket
  config, vault, client env vars, users must log in again)

### TC-MIG-013: Read-only-source invariant — no write command against source
- **Given**: full happy path with stubs that log their argv
- **When**: the script runs
- **Then**: no stubbed binary is invoked with a write subcommand against the
  source DSN. Specifically:
  - `pg_dump` (read-only) is the only binary pointed at the source DSN
  - `rclone` is invoked with `copy` (not `sync`, not `move`, not `delete`)
  - `psql` against the source is only ever `SELECT count(*)` (preflight)

### TC-MIG-014: Storage failure is non-fatal + appears in runtime notes
- **Given**: stubbed `rclone` exits non-zero
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: script warns, continues, and the manual-steps report's "RUNTIME NOTES"
  section lists the storage copy failure

### TC-MIG-015: Missing optional schema is skipped with warning, not fatal
- **Given**: stubbed `pg_dump` exits non-zero for one `--schema=` flag
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: script warns about the skipped schema, continues with the others,
  and the skipped schema name appears in RUNTIME NOTES

### TC-MIG-016: env/migrate.example.yml is valid YAML
- **When**: `env/migrate.example.yml` is parsed
- **Then**: it is valid YAML with `source`, `target`, `tools` top-level keys

### TC-MIG-017: Unknown flag rejected
- **When**: `bash migrate.sh --bogus`
- **Then**: exits non-zero with "Unknown option" (matches `setup.sh` behavior)

### TC-MIG-018: --config is required
- **Given**: no `--config` flag
- **When**: `bash migrate.sh --yes`
- **Then**: exits non-zero with a message telling the user to pass `--config`

### TC-MIG-019: pg_dump uses read-only-compatible flags
- **Given**: full happy path with stubs
- **When**: the script runs
- **Then**: the `pg_dump` invocation includes `--no-owner --no-privileges` and
  does NOT include any write flag (pg_dump has none, but assert the flag set)

### TC-MIG-020: pg_restore targets the target DSN only
- **Given**: full happy path with stubs
- **When**: the script runs
- **Then**: `pg_restore` is invoked with the target DSN, never the source DSN

### TC-MIG-021: Storage bucket definitions are dumped before the object copy
- **Given**: full happy path with stubs that log a shared invocation timeline
- **When**: the script runs
- **Then**: the `pg_dump` carrying `--table=storage.buckets` appears in the shared
  timeline **before** the storage object listing/upload (Phase 3 precedes Phase 4)

### TC-MIG-022: Storage bucket restore is data-only + read-only on source
- **Given**: full happy path with stubs
- **When**: the script runs
- **Then**: the bucket `pg_dump` uses `--data-only --no-owner --no-privileges
  --table=storage.buckets`, and no `pg_restore` ever references the source DSN

### TC-MIG-023: Vault migration skipped (non-fatal) when source cannot decrypt
- **Given**: stubbed `psql` fails on `SELECT count(*) FROM vault.decrypted_secrets`
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits 0, prints "vault migration skipped", and the manual report's
  RUNTIME NOTES explains that secrets must be re-created manually

### TC-MIG-024: Vault secrets re-encrypted on the target via vault.create_secret
- **Given**: stubbed `psql` returns one secret from `vault.decrypted_secrets`
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits 0 with "vault secrets re-created on the target", and the
  read-only-source invariant holds (the vault `SELECT` against the source is a
  read, never a write)

### TC-MIG-025: No vault secrets produces a clean no-op
- **Given**: stubbed `psql` returns 0 secrets
- **When**: `bash migrate.sh --config env/migrate.yml --yes`
- **Then**: exits 0 with "no vault secrets to migrate" (clean skip, no error)