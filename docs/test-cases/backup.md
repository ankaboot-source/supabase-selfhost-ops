# Test Cases: Backup Role (pgBackRest)

> Issue: #118 — `feat(backup): automated backups + PITR with pgBackrest`

Tests are shell-level (matching `tests/test-setup.sh` / `tests/test-migrate.sh` conventions). They stub `docker`, `pgbackrest`, `cron`, and `ansible` and assert on rendered config files and script invocations. No real Supabase/DB/Docker is required.

## TC-BACKUP-001: defaults render hobby-safe values

**Given** `config.yml` has `components.backup: true` and only `backup_repo_type: rustfs`.
**When** `setup.sh` runs.
**Then** `env/supabase.yml` contains:
- `backup_repo_type: rustfs`
- `backup_encryption: false`
- `backup_creds_source: env`
- `backup_restore_drill: false`
- `backup_retention_full: 3`
- `backup_retention_diff: 3`
- `backup_retention_archive: 3`
- `backup_wal_archiving: true`
- `backup_initial_on_enable: true`

## TC-BACKUP-002: local repo warning is printed

**Given** `backup_repo_type: rustfs` (or `posix`).
**When** `setup.sh` runs.
**Then** stdout contains a loud warning mentioning "same machine" / "no off-box protection".

## TC-BACKUP-003: external repo forces encryption on

**Given** `backup_repo_type: s3` and `backup_encryption` unset (or `false`).
**When** `setup.sh` runs.
**Then** `env/supabase.yml` contains `backup_encryption: true` (forced on for external repo).

## TC-BACKUP-004: pgbackrest.conf renders correct repo type

**Given** `backup_repo_type: s3` with s3 endpoint/bucket/region/keys set.
**When** the `pgbackrest.conf.j2` template is rendered.
**Then** output contains `repo1-type=s3`, `repo1-s3-bucket`, `repo1-s3-endpoint`, `repo1-s3-region`, `repo1-s3-key`, `repo1-s3-key-secret`, `repo1-s3-uri-style=path` (for path-style stores) or `host` (for AWS).

## TC-BACKUP-005: pgbackrest.conf renders encryption for external repo

**Given** `backup_repo_type: s3`, `backup_encryption: true`, `backup_cipher_pass: testpass`.
**When** `pgbackrest.conf.j2` is rendered.
**Then** output contains `repo1-cipher-type=aes-256-cbc` and `repo1-cipher-pass=testpass`.

## TC-BACKUP-006: pgbackrest.conf omits encryption for local repo

**Given** `backup_repo_type: rustfs`, `backup_encryption: false`.
**When** `pgbackrest.conf.j2` is rendered.
**Then** output does **not** contain `repo1-cipher-type` or `repo1-cipher-pass`.

## TC-BACKUP-007: docker-compose-backup renders rustfs + rustfs-init for local repo

**Given** `backup_repo_type: rustfs`.
**When** `docker-compose-backup.yml.j2` is rendered.
**Then** output contains `rustfs` and `rustfs-init` services, bound to `127.0.0.1:9000` and `127.0.0.1:9001`.

## TC-BACKUP-008: docker-compose-backup omits rustfs for s3 repo

**Given** `backup_repo_type: s3`.
**When** `docker-compose-backup.yml.j2` is rendered.
**Then** output does **not** contain `rustfs` or `rustfs-init` services.

## TC-BACKUP-009: supabase compose adds archive_command when backup enabled

**Given** `backup_enabled: true`.
**When** `docker-compose-supabase.yml.j2` is rendered.
**Then** the `db` service command contains `-c archive_mode=on` and `-c archive_command=pgbackrest --stanza=main archive-push %p`, the db service mounts `/usr/bin/pgbackrest:/usr/bin/pgbackrest:ro` and the pgbackrest config, and joins the backup network.

## TC-BACKUP-010: supabase compose omits archive_command when backup disabled

**Given** `backup_enabled: false`.
**When** `docker-compose-supabase.yml.j2` is rendered.
**Then** the `db` service command does **not** contain `archive_mode` or `archive_command`, does **not** mount pgbackrest, and does **not** join the backup network.

## TC-BACKUP-011: stanza-create is called once on enable

**Given** backup role runs with `backup_enabled: true` for the first time.
**When** the role executes.
**Then** `docker exec supabase-db pgbackrest --stanza=main stanza-create` is invoked exactly once (after `supabase-rustfs-init` has exited 0).

## TC-BACKUP-012: stanza-create is not re-called on re-run (idempotency)

**Given** backup role has already run successfully.
**When** the role runs again.
**Then** `stanza-create` is **not** invoked (or is invoked but pgBackRest reports "already exists" and the task does not fail).

## TC-BACKUP-013: initial full backup runs on enable

**Given** `backup_initial_on_enable: true`.
**When** the role runs for the first time (stanza created).
**Then** `pgbackrest --stanza=main backup --type=full` is invoked.

## TC-BACKUP-014: cron schedules render correctly

**Given** default schedules.
**When** the role runs.
**Then** cron files are created with:
- full backup: `0 3 * * 1`
- diff backup: `0 3 * * 2-7`
- verify: `0 4 * * *`

## TC-BACKUP-015: restore.yml refuses without target_time

**Given** `restore.yml` is run without `target_time` extra var.
**When** the playbook executes.
**Then** it fails immediately with a message requiring `target_time`.

## TC-BACKUP-016: restore.yml requires explicit confirmation

**Given** `restore.yml` is run with `target_time` set.
**When** the playbook executes.
**Then** it prints the target time + current time + overwrite warning and waits for confirmation. Without `confirm=yes` it aborts.

## TC-BACKUP-017: restore.yml takes a fresh backup before overwrite

**Given** `restore.yml` is run with confirmation.
**When** the playbook executes.
**Then** `pgbackrest --stanza=main backup --type=full` is invoked **before** the restore step.

## TC-BACKUP-018: restore.yml runs pgbackrest restore with target-time

**Given** `restore.yml` is run with `target_time='2026-08-01 12:30:00+00'`.
**When** the playbook executes.
**Then** `pgbackrest --stanza=main --type=time --target='2026-08-01 12:30:00+00' --target-action=promote --delta restore` is invoked after stopping the db container.

## TC-BACKUP-019: restore-verify.yml does not touch prod PGDATA

**Given** `restore-verify.yml` is run.
**When** the playbook executes.
**Then** it restores into a throwaway volume (not the live PGDATA), starts a separate Postgres container, and runs healthchecks. The live `supabase-db` container is never stopped.

## TC-BACKUP-020: pgsodium key is backed up

**Given** backup role runs.
**When** the pgsodium backup task executes.
**Then** `docker compose run --rm db cat /etc/postgresql-custom/pgsodium_root.key` is invoked and the key is written to `{{ backup_dir }}/pgsodium_root.key`.

## TC-BACKUP-021: storage volume backup detects backend

**Given** `STORAGE_BACKEND: file` in the supabase compose.
**When** the storage backup task executes.
**Then** `./volumes/storage/` is tarred into the backup repo.

**Given** `STORAGE_BACKEND: s3`.
**When** the storage backup task executes.
**Then** the volume backup is skipped with a log message.

## TC-BACKUP-022: prometheus scrape target added when backup enabled

**Given** `backup_enabled: true`.
**When** `prometheus.yml.j2` is rendered.
**Then** output contains a scrape target for `pgbackrest_exporter:9854` (or `host.docker.internal:9854`).

## TC-BACKUP-023: grafana dashboard renders without Ansible var collision

**Given** the backup Grafana dashboard JSON template.
**When** it is rendered.
**Then** any `{{label}}` legend refs are preserved verbatim (wrapped in `{% raw %}`), and the dashboard JSON is valid.

## TC-BACKUP-024: alert rules render for always-on alerts

**Given** backup role enabled.
**When** the alert rules template is rendered.
**Then** output contains alert rules for: stanza_status > 0, last_full age > 25h, archive lag, backup error, verify failure.

## TC-BACKUP-025: vault creds source does not write plaintext .env

**Given** `backup_creds_source: vault`.
**When** the role runs.
**Then** S3 keys are **not** written to the backup `.env` file; they are consumed from Ansible Vault variables directly.

## TC-BACKUP-026: .env creds source warns

**Given** `backup_creds_source: env` (default).
**When** `setup.sh` runs.
**Then** stdout contains a warning about plaintext credentials.

## TC-BACKUP-027: backup.yml runs on-demand full backup

**Given** `backup.yml` playbook.
**When** it is executed.
**Then** `pgbackrest --stanza=main backup --type=full` is invoked.

## TC-BACKUP-028: verify runs daily, distinct from restore drill

**Given** default schedules.
**When** the role runs.
**Then** a daily cron for `pgbackrest verify` is created, and the restore drill cron is **not** created (off by default).

## TC-BACKUP-029: restore drill is opt-in

**Given** `backup_restore_drill: false` (default).
**When** the role runs.
**Then** no restore drill cron is created.

**Given** `backup_restore_drill: true`.
**When** the role runs.
**Then** a restore drill cron is created and a resource warning is printed.

## TC-BACKUP-030: playbook-supabase.yml includes backup role when enabled

**Given** `components.backup: true`.
**When** `setup.sh` regenerates `playbook-supabase.yml`.
**Then** the playbook contains `- backup` role line.

## TC-BACKUP-031: playbook-supabase.yml omits backup role when disabled

**Given** `components.backup: false`.
**When** `setup.sh` regenerates `playbook-supabase.yml`.
**Then** the playbook does **not** contain `- backup`.

## TC-BACKUP-032: old S3-dump config fields are removed

**Given** the new `config.example.yml`.
**When** inspected.
**Then** the old `advanced.backup` fields (s3_remote_name, s3_provider, s3_access_key, s3_secret_key, s3_endpoint, s3_bucket_name, backup_cron_hour, backup_cron_minute) are **removed** and replaced with the new pgBackRest fields.

## TC-BACKUP-033: no duplicate networks/volumes block in supabase compose

**Given** `backup_enabled: true`.
**When** `docker-compose-supabase.yml.j2` is rendered.
**Then** there is exactly one top-level `networks:` block and one top-level `volumes:` block (no duplicate keys — merge into existing, per AGENTS.md pitfall).