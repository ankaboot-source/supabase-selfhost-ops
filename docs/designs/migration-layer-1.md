# Design Canvas: Migration Script (Layer 1) — `migrate.sh`

**Issue:** #99 — Migration script from supabase.com
**Labels:** feature, migration, layer-1
**Status:** Approved (autonomous mode — no interactive approval gate)

---

## 1. Goal

A single command that takes a Supabase Cloud project and migrates it end-to-end
into a freshly installed self-hosted instance (this repo's own stack), accepting
downtime and a short list of manual steps printed at the end.

```bash
./migrate.sh --config env/migrate.yml --yes
```

This is the **walking skeleton**: the entire functional perimeter touched, none
of it deeply. Incomplete, but never silently incomplete.

---

## 2. Non-Goals (Deliberately excluded — each has its own layer)

- Verification / dry-run
- Session continuity / resumability
- Auth config import (manual checklist only)
- Downtime reduction
- Edge-function SECRET VALUES (write-only in Cloud — only NAMES are retrievable;
  values are left to the operator, see §6 Phase 7)
- Per-bucket storage RLS policies (listed as manual steps; they live in
  `pg_catalog.pg_policy`, not `storage.policies`, and the stack seeds its own)

Under the walking-skeleton principle, **storage bucket definitions, vault secrets,
and edge-function CODE** are migrated (Phase 3, Phase 5, Phase 6) — they are
feasible without breaking the read-only-source invariant, so they are no longer
non-goals. Edge-function code is downloadable from Cloud via `supabase functions
download` (see the Supabase transfer guide); only edge-function secret values
cannot be retrieved.

---

## 3. Fidelity Contract (what "done" means at this layer)

| Surface | After this issue |
|---|---|
| Schema + data | Dumped and restored, including Supabase-managed schemas |
| Roles | `anon`, `authenticated`, `service_role` recreated; custom roles best-effort |
| Auth users | Migrated with UUIDs preserved — users must log in again |
| Auth configuration | Manual, printed as a checklist |
| Storage bucket definitions | Migrated (data-only `storage.buckets` restore, before object copy) |
| Storage objects | Copied — no per-bucket RLS policy reconciliation |
| Storage per-bucket RLS policies | Manual (in `pg_catalog.pg_policy`) |
| Vault secrets | Migrated, re-encrypted on the target via `vault.create_secret`; skipped (non-fatal) if the source cannot decrypt |
| Edge Function code | Migrated — downloaded from Cloud (`supabase functions download`, read-only), deployed into `<supabase_path>/volumes/functions/`, container restarted. Skipped if the CLI is missing / list empty / download fails (non-fatal) |
| Edge Function secrets | NAMES staged as empty `NAME=` entries in `<supabase_path>/.env.functions`; VALUES are operator-supplied (not retrievable from Cloud). Requires a manual fill + container recreate |
| Cron jobs, webhooks | Carried over best-effort by the schema dump (`cron.job`, `supabase_webhooks.hooks`) — verify |
| Downtime | A maintenance window, accepted and documented |
| Restartability | None. A failure means starting over |

---

## 4. Conventions (must match `setup.sh`)

- **YAML config file**, non-interactive by default.
- **Flags are verbs only**: `--config <path>`, `--yes`, `--dry-run`, `--help`, `-v/--verbose`.
  No `--config=foo` form (matches `setup.sh`'s `case` parser).
- **Read-only against the source project. Always, at every layer.** This is a hard
  invariant — enforced by (a) using only read-only `pg_dump`/`pg_restore` flags and
  read-only S3 `GET`/`LIST` via rclone, and (b) a preflight assertion that the source
  DSN is not the target DSN.
- **Refuses to run against a non-empty target.** A preflight check counts relations
  in `public` and rows in `auth.users`; if either is non-zero, abort before touching
  anything.
- **Runs with no TTY attached.** All prompts gated behind `--yes`; colors disabled
  when `[[ -t 1 ]]` is false (same idiom as `setup.sh`).
- **Logging helpers** (`log`/`ok`/`warn`/`die`) copied verbatim from `setup.sh` so the
  two scripts feel like one tool.
- **YAML parsing** via the same `python3 -c 'import yaml'` helper pattern (`cfg_get`/
  `cfg_bool`), so no new runtime dependency is introduced.

---

## 5. Inputs (`env/migrate.example.yml`)

A new example config, separate from `config.example.yml` (migration is an
opt-in operation, not part of install). Copied to `env/migrate.yml` by the
operator and edited.

```yaml
# Migration configuration — copy to env/migrate.yml and edit.
# READ-ONLY against source. The script refuses to write to the source project.

source:
  # Supabase Cloud project ref (found in Dashboard URL / Settings / API).
  project_ref: changeit            # e.g. abcdefghijklmnop

  # Direct Postgres connection string to the Cloud project's pooler.
  # Use the TRANSACTION/SESSION mode URL (port 6543 or 5432 per your pooler).
  # Must be a libpq DSN. The script opens it READ-ONLY.
  db_url: changeit                 # postgresql://postgres.[ref]:[pwd]@db.[ref].supabase.co:6543/postgres

  # S3-compatible storage endpoint credentials (Supabase Cloud S3 API).
  # Found in Dashboard / Settings / Storage.
  storage_endpoint: changeit       # https://[ref].supabase.co/storage/v1
  storage_access_key: changeit
  storage_secret_key: changeit
  storage_region: changeit         # e.g. us-east-1

  # Optional: Supabase CLI access token (Dashboard → Account → Access Tokens),
  # needed to list/download edge functions and list secret names. Alternatively
  # export SUPABASE_ACCESS_TOKEN or run `supabase login`.
  access_token: changeit

# Edge-function migration (defaults to enabled; self-skips when the CLI is
# missing or the function/secret lists are empty).
functions:
  enabled: true
  target_dir: supabase/docker/volumes/functions   # self-hosted functions mount

target:
  # Self-hosted Postgres DSN (the stack this repo deploys).
  # Default matches the local docker-compose service name + default password.
  db_url: postgresql://postgres:postgres@localhost:5432/postgres

  # Self-hosted storage endpoint (Kong /storage/v1).
  storage_endpoint: http://localhost:8000/storage/v1
  storage_access_key: changeit     # from env/supabase.yml s3_protocol_access_key_id
  storage_secret_key: changeit     # from env/supabase.yml s3_protocol_access_key_secret
  storage_region: us-east-1

# Tools — paths to required binaries. Defaults resolve via PATH.
tools:
  pg_dump: pg_dump
  pg_restore: pg_restore
  rclone: rclone
  psql: psql
  supabase: supabase
```

### Validation rules

- `source.project_ref` must not be `changeit`.
- `source.db_url` must not be `changeit` and must start with `postgresql://` (or
  `postgres://`).
- `target.db_url` must start with `postgresql://` and must **not equal**
  `source.db_url` (read-only-source invariant).
- `source.storage_*` and `target.storage_*` must not be `changeit`.
- Required binaries (`pg_dump`, `pg_restore`, `rclone`, `psql`) must be on PATH.

---

## 6. Execution Phases

```
Phase 0: Preflight
  ├─ parse args (--config, --yes, --dry-run, --help, -v)
  ├─ load + validate migrate.yml (cfg_get / cfg_bool helpers)
  ├─ assert required binaries on PATH
  ├─ assert source.db_url != target.db_url
  ├─ assert target is empty (count relations in public + rows in auth.users)
  └─ if --dry-run: print plan and exit 0

Phase 1: Database — schema + data
  ├─ pg_dump source (per-schema, custom format)
  │     flags: --format=custom --no-owner --no-privileges --schema=<name>
  │     + discovered user schemas only (Supabase-managed schemas excluded)
  ├─ pg_restore into target (DSN via --dbname=, archive file as positional)
  └─ on failure: warn() + add to runtime notes (non-fatal)

Phase 2: Auth users (UUIDs preserved)
  ├─ pg_dump auth.users auth.identities from source (data-only)
  ├─ pg_restore into target
  └─ NOTE: users must log in again (password hashes migrate, but sessions do not)

Phase 3: Storage bucket definitions (MUST precede the object copy)
  ├─ pg_dump storage.buckets from source (data-only)
  ├─ pg_restore into target
  └─ if absent, object copy hits NoSuchBucket on a fresh instance

Phase 4: Storage objects (rclone copy)
  ├─ configure rclone remote for source S3 endpoint (read-only)
  ├─ configure rclone remote for target S3 endpoint
  ├─ rclone copy source:bucket target:bucket --progress=no
  └─ on failure: warn (storage is best-effort) + add to manual report

Phase 5: Vault secrets (re-encrypted on the target)
  ├─ preflight: SELECT count(*) FROM vault.decrypted_secrets on source (read-only)
  │     on failure (source cannot decrypt) → warn + skip + manual note, continue
  ├─ SELECT name, decrypted_secret, description FROM vault.decrypted_secrets
  │     (read-only on source)
  ├─ build SQL: SELECT vault.create_secret(...) for each secret
  │     (encrypts with the TARGET's root key)
  ├─ psql -f against target (re-creates + re-encrypts secrets)
  └─ on target failure: warn + add to manual report

Phase 6: Edge function CODE (downloaded read-only from Cloud)
  ├─ preflight: command -v supabase; if absent → warn + skip + note (never die)
  ├─ CLI auth: source.access_token → SUPABASE_ACCESS_TOKEN, else existing login
  ├─ enumerate slugs: supabase functions list --project-ref <ref> (read-only)
  │     empty list → ok "no functions to migrate", skip
  ├─ for each: (cd temp && supabase functions download <slug> --project-ref <ref>)
  │     on failure → warn + note, continue (best-effort network/deploy)
  ├─ copy each downloaded <slug>/ into <functions_dir> (filesystem-based deploy —
  │     supabase functions deploy targets Cloud, so it is NOT used)
  └─ docker compose -f <supabase_path>/docker-compose-supabase.yml restart functions

Phase 7: Edge-function SECRET NAMES (values are write-only in Cloud)
  ├─ only runs when functions enabled AND CLI present; otherwise skip + note
  ├─ enumerate names: supabase secrets list --project-ref <ref> (read-only)
  ├─ append `NAME=` (empty) for each to <supabase_path>/.env.functions, never
  │     overwriting an existing NAME= entry
  └─ runtime note: fill values + recreate container
       (docker compose -f <supabase_path>/docker-compose-supabase.yml up -d --force-recreate functions)

Phase 8: Manual-steps report
  ├─ print a fixed checklist of everything NOT migrated
  └─ exit 0
```

### Read-only-source enforcement

- `pg_dump` is inherently read-only (no `--write` flag exists).
- `rclone copy` (not `sync`, not `move`) — source is never mutated.
- A preflight assertion `source.db_url != target.db_url` prevents the catastrophic
  case of pointing both ends at the same database.
- All `psql` calls against the source are **read-only `SELECT`s only**:
  - the empty-target preflight probes (against the **target**), and
  - the vault phase reads `vault.decrypted_secrets` via `SELECT` (source) before
    re-creating secrets on the **target** with `vault.create_secret`.
  The source is otherwise touched only by `pg_dump` (read-only). Every write
  (`pg_restore`, `rclone`, `psql -f` with `vault.create_secret`) targets the target DSN.
- The Supabase CLI is used read-only against the source: `functions list`,
  `functions download`, and `secrets list` only READ the Cloud project.
  `supabase functions deploy` targets **Cloud**, not a self-hosted instance, so
  it is never issued (a test asserts this). The CLI needs auth (`source.access_token`
  → `SUPABASE_ACCESS_TOKEN`, or an existing `supabase login` session).

### Non-empty-target refusal

Before any restore, the script runs (against the **target** only):

```sql
SELECT count(*) FROM information_schema.tables
 WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
SELECT count(*) FROM auth.users;
```

If either is non-zero, `die` with a clear message: "target is not empty — Layer 1
migrates into a fresh instance only. Re-provision the target and re-run."

---

## 7. Manual-Steps Report (the contract of this layer)

Printed to stdout at the end, always. The report is the **authoritative list of
what the operator must now do by hand**. It is generated from a fixed template
plus runtime-discovered items (e.g. storage copy failures, missing schemas).

Template (printed verbatim, with runtime substitutions):

```
================================================================================
 MANUAL STEPS — complete these by hand. Migration is NOT finished until you do.
================================================================================

1. AUTH CONFIGURATION (not migrated)
   - [ ] Review and re-create auth providers in the self-hosted Studio:
         Dashboard → Authentication → Providers
   - [ ] Re-create any custom email templates (Dashboard → Auth → Email Templates)
   - [ ] Re-configure SMTP settings (already in env/supabase.yml — verify)
   - [ ] Re-create any MFA / SAML / hooks configuration

2. EDGE FUNCTIONS (code migrated automatically; SECRET VALUES are manual)
   - [x] Function source downloaded from Cloud and deployed into
         <supabase_path>/volumes/functions/; the functions service was restarted
   - [ ] Fill in the edge-function SECRET VALUES in
         <supabase_path>/.env.functions (each staged as NAME=) and recreate the
         functions container so the env_file is re-read:
         docker compose -f <supabase_path>/docker-compose-supabase.yml up -d --force-recreate functions
   - [ ] If any function failed to download, or the Supabase CLI was missing,
         deploy the affected function(s) manually: copy the folder into
         <supabase_path>/volumes/functions/ and: docker compose restart functions

3. CRON JOBS (migrated best-effort via the schema dump)
   - [x] pg_cron job definitions carried over by the schema+data restore
   - [ ] Verify on the target: SELECT * FROM cron.job;

4. WEBHOOKS (migrated best-effort via the schema dump)
   - [x] Database webhook definitions (supabase_webhooks.hooks) carried over
   - [ ] Verify the hooks were reinstalled onto their tables

5. STORAGE BUCKET CONFIGURATION (definitions migrated; RLS policies manual)
   - [x] Bucket definitions (public/private, size limits, MIME types) — migrated
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
- <list of skipped schemas, storage failures, etc. — empty if none>
================================================================================
```

---

## 8. Error Handling

- `set -euo pipefail` (same as `setup.sh`).
- Every phase wrapped in a function; failures call `die` with the phase name +
  tail of the captured log.
- No retry, no resume (explicitly out of scope). A failure means starting over.
- `--dry-run` prints the plan (phases + commands that would run) and exits 0
  before touching anything.

---

## 9. Testing Strategy

Shell-level tests in `tests/test-migrate.sh`, mirroring `tests/test-setup.sh`'s
shape (sandbox + stubbed binaries). The test harness stubs `pg_dump`, `pg_restore`,
`rclone`, and `psql` so tests run without a real Supabase project or database.

Test categories:
- Config validation (missing file, `changeit` fields, invalid DSN, source==target)
- Preflight (missing binaries, non-empty target refusal)
- Dry-run (no side effects, prints plan)
- Non-interactive (`--yes` with no TTY)
- Help output
- Phase execution with stubs (asserts the right commands are invoked)
- Manual-steps report is always printed
- Read-only-source invariant (no write command ever issued against source DSN)

---

## 10. File Manifest

| Path | Purpose |
|---|---|
| `migrate.sh` | The migration script (root, sibling to `setup.sh`) |
| `env/migrate.example.yml` | Example config (operator copies to `env/migrate.yml`) |
| `docs/designs/migration-layer-1.md` | This design canvas |
| `docs/test-cases/migration-layer-1.md` | Test case document |
| `tests/test-migrate.sh` | Shell-level test harness |
| `README.md` | Add a "Migration from Supabase Cloud" section |

---

## 11. Acceptance Criteria Mapping

| Issue criterion | How this design satisfies it |
|---|---|
| Test project migrates in one command | `./migrate.sh --config env/migrate.yml --yes` |
| Application reconnects after env var update | Manual-steps report item 6 + auth users migrated with UUIDs intact |
| Every unmigrated item in manual-steps report | Section 7 template — fixed + runtime items |
| Source provably never written to | `pg_dump` (read-only) + `rclone copy` (not sync/move) + preflight `source != target` assertion + no write `psql` against source |
| Runs with no TTY | `--yes` gates all prompts; colors off when `! [[ -t 1 ]]` |