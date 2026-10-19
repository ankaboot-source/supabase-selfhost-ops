#!/bin/bash
# test-backup.sh — Tests for the backup role (pgBackRest) config rendering
# Run: bash tests/test-backup.sh
# Shell-level tests that validate setup.sh renders the new backup config
# correctly into env/supabase.yml and regenerates the playbook. No real
# Supabase/DB/Docker is required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$SCRIPT_DIR/.."
SETUP="$WORKTREE/setup.sh"
EXAMPLE="$WORKTREE/config.example.yml"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

ok()   { printf "  \033[0;32mPASS\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[0;31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }

make_sandbox() {
  local d="$TMPDIR_BASE/$1"
  mkdir -p "$d/env"
  cp "$WORKTREE/setup.sh" "$WORKTREE/config.example.yml" "$WORKTREE/install.sh" \
     "$WORKTREE/generate-keys.sh" "$WORKTREE/playbook-supabase.yml" "$d/" 2>/dev/null
  cp "$WORKTREE/env/supabase.yml" "$d/env/"
  cat > "$d/install.sh" <<'STUB'
#!/bin/bash
echo "STUBBED_INSTALL_OK"
STUB
  chmod +x "$d/install.sh" "$d/setup.sh"
  echo "$d"
}

run_setup_rc() {
  local dir="$1"; shift
  OUT="$( cd "$dir" && bash setup.sh "$@" 2>&1 )" && RC=0 || RC=$?
}

fill_required() {
  local c="$1/config.yml"
  sed -i 's|deploy_user: changeit|deploy_user: ubuntu|' "$c"
  sed -i 's|site_url: https://app.example.com|site_url: https://myapp.com|' "$c"
  sed -i 's|api_external_url: https://sb.example.com|api_external_url: https://sb.myapp.com|' "$c"
  sed -i 's|supabase_domain: sb.example.com|supabase_domain: sb.myapp.com|' "$c"
  sed -i 's|smtp_admin_email: changeit|smtp_admin_email: me@myapp.com|' "$c"
  sed -i 's|smtp_host: changeit|smtp_host: mail.myapp.com|' "$c"
  sed -i 's|smtp_user: changeit|smtp_user: me@myapp.com|' "$c"
  sed -i 's|smtp_password: changeit|smtp_password: secret123|' "$c"
}

# Enable backup with local (rustfs) repo
enable_backup_rustfs() {
  local c="$1/config.yml"
  sed -i 's|backup: false|backup: true|' "$c"
}

# Enable backup with s3 repo + fill s3 creds
enable_backup_s3() {
  local c="$1/config.yml"
  sed -i 's|backup: false|backup: true|' "$c"
  sed -i 's|repo_type: rustfs|repo_type: s3|' "$c"
  sed -i 's|s3_endpoint: changeit|s3_endpoint: https://s3.eu-west-1.amazonaws.com|' "$c"
  sed -i 's|s3_bucket: changeit|s3_bucket: my-backup-bucket|' "$c"
  sed -i 's|s3_access_key: changeit|s3_access_key: AKIATESTKEY|' "$c"
  sed -i 's|s3_secret_key: changeit|s3_secret_key: secretkey123|' "$c"
}

# ─── TC-BACKUP-001: defaults render hobby-safe values ────────────────────────
echo "TC-BACKUP-001: defaults render hobby-safe values"
d="$(make_sandbox tc001)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
enable_backup_rustfs "$d"
run_setup_rc "$d" --yes
ENV="$d/env/supabase.yml"
if grep -q "backup_repo_type: rustfs" "$ENV" \
  && grep -q "backup_encryption: false" "$ENV" \
  && grep -q "backup_creds_source: env" "$ENV" \
  && grep -q "backup_restore_drill: false" "$ENV" \
  && grep -q "backup_retention_full: 3" "$ENV" \
  && grep -q "backup_retention_diff: 3" "$ENV" \
  && grep -q "backup_retention_archive: 3" "$ENV" \
  && grep -q "backup_wal_archiving: true" "$ENV" \
  && grep -q "backup_initial_on_enable: true" "$ENV"; then
  ok "hobby-safe defaults rendered"
else
  fail "hobby-safe defaults not rendered (rc=$RC)"
fi

# ─── TC-BACKUP-002: local repo warning is printed ───────────────────────────
echo "TC-BACKUP-002: local repo warning is printed"
d="$(make_sandbox tc002)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
enable_backup_rustfs "$d"
run_setup_rc "$d" --yes
if echo "$OUT" | grep -qi "no off-box protection"; then
  ok "local repo warning printed"
else
  fail "local repo warning not printed"
fi

# ─── TC-BACKUP-003: external repo forces encryption on ──────────────────────
echo "TC-BACKUP-003: external repo forces encryption on"
d="$(make_sandbox tc003)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
enable_backup_s3 "$d"
run_setup_rc "$d" --yes
ENV="$d/env/supabase.yml"
if grep -q "backup_encryption: true" "$ENV"; then
  ok "encryption forced on for s3 repo"
else
  fail "encryption not forced on for s3 repo"
fi

# ─── TC-BACKUP-040: s3_endpoint with a URL path is rejected ─────────────────
echo "TC-BACKUP-040: s3_endpoint with a URL path is rejected"
d="$(make_sandbox tc040)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
enable_backup_s3 "$d"
sed -i 's|s3_endpoint: https://s3.eu-west-1.amazonaws.com|s3_endpoint: https://project.supabase.co/storage/v1/s3|' "$d/config.yml"
run_setup_rc "$d" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "INCOMPATIBLE\|NO path\|pgBackRest"; then
  ok "rejects path-bearing s3 endpoint with clear error (rc=$RC)"
else
  fail "expected non-zero exit + pgBackRest error for path-bearing endpoint (rc=$RC)"
fi

# ─── TC-BACKUP-041: host-only s3_endpoint passes validation ─────────────────
echo "TC-BACKUP-041: host-only s3_endpoint passes validation"
d="$(make_sandbox tc041)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
enable_backup_s3 "$d"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]] && grep -q "backup_s3_endpoint: https://s3.eu-west-1.amazonaws.com" "$d/env/supabase.yml"; then
  ok "host-only s3_endpoint accepted (rc=$RC)"
else
  fail "host-only s3_endpoint was rejected (rc=$RC)"
fi

# ─── TC-BACKUP-026: .env creds source warns ─────────────────────────────────
echo "TC-BACKUP-026: .env creds source warns"
d="$(make_sandbox tc026)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
enable_backup_rustfs "$d"
run_setup_rc "$d" --yes
if echo "$OUT" | grep -qi "plaintext"; then
  ok "plaintext creds warning printed"
else
  fail "plaintext creds warning not printed"
fi

# ─── TC-BACKUP-030: playbook includes backup role when enabled ──────────────
echo "TC-BACKUP-030: playbook includes backup role when enabled"
d="$(make_sandbox tc030)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
enable_backup_rustfs "$d"
run_setup_rc "$d" --yes
PB="$d/playbook-supabase.yml"
if grep -q "\- backup" "$PB"; then
  ok "playbook includes backup role"
else
  fail "playbook does not include backup role"
fi

# ─── TC-BACKUP-031: playbook omits backup role when disabled ────────────────
echo "TC-BACKUP-031: playbook omits backup role when disabled"
d="$(make_sandbox tc031)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
# backup stays false (default)
run_setup_rc "$d" --yes
PB="$d/playbook-supabase.yml"
if grep -q "\- backup" "$PB"; then
  fail "playbook includes backup role when disabled"
else
  ok "playbook omits backup role when disabled"
fi

# ─── TC-BACKUP-032: old S3-dump config fields are removed ───────────────────
echo "TC-BACKUP-032: old S3-dump config fields are removed"
if ! grep -q "s3_remote_name" "$EXAMPLE" \
  && ! grep -q "s3_provider" "$EXAMPLE" \
  && ! grep -q "backup_cron_hour" "$EXAMPLE"; then
  ok "old S3-dump fields removed from config.example.yml"
else
  fail "old S3-dump fields still in config.example.yml"
fi

# ─── TC-BACKUP-032b: old S3-dump vars removed from env/supabase.yml ─────────
echo "TC-BACKUP-032b: old S3-dump vars removed from env/supabase.yml"
ENV_TEMPLATE="$WORKTREE/env/supabase.yml"
if ! grep -q "s3_remote_name" "$ENV_TEMPLATE" \
  && ! grep -q "s3_provider" "$ENV_TEMPLATE" \
  && ! grep -q "exclude_tables" "$ENV_TEMPLATE"; then
  ok "old S3-dump vars removed from env/supabase.yml"
else
  fail "old S3-dump vars still in env/supabase.yml"
fi

# ─── TC-BACKUP-033: no duplicate networks/volumes block in supabase compose ─
echo "TC-BACKUP-033: no duplicate networks/volumes block in supabase compose"
COMPOSE="$WORKTREE/roles/supabase/templates/docker-compose-supabase.yml.j2"
networks_count=$(grep -c "^networks:" "$COMPOSE" 2>/dev/null || echo 0)
volumes_count=$(grep -c "^volumes:" "$COMPOSE" 2>/dev/null || echo 0)
if [[ "$networks_count" -le 1 && "$volumes_count" -le 1 ]]; then
  ok "no duplicate networks/volumes blocks"
else
  fail "duplicate networks/volumes blocks found (networks=$networks_count volumes=$volumes_count)"
fi

# ─── TC-BACKUP-009: supabase compose has archive_command when backup enabled ─
echo "TC-BACKUP-009: supabase compose has archive_command when backup enabled"
COMPOSE="$WORKTREE/roles/supabase/templates/docker-compose-supabase.yml.j2"
if grep -q "archive_mode=on" "$COMPOSE" \
  && grep -q "archive_command=pgbackrest" "$COMPOSE" \
  && grep -q "pgbackrest.conf" "$COMPOSE"; then
  ok "archive_command + pgbackrest mounts present in compose template"
else
  fail "archive_command or pgbackrest mounts missing from compose template"
fi

# ─── TC-BACKUP-023: grafana dashboard wraps {{label}} in raw ────────────────
echo "TC-BACKUP-023: grafana dashboard wraps {{label}} in raw"
DASHBOARD="$WORKTREE/roles/backup/templates/grafana/backup.json.j2"
if grep -q "{% raw %}" "$DASHBOARD" && grep -q "{% endraw %}" "$DASHBOARD"; then
  ok "grafana dashboard wrapped in raw"
else
  fail "grafana dashboard not wrapped in raw"
fi

# ─── TC-BACKUP-024: alert rules render for always-on alerts ────────────────
echo "TC-BACKUP-024: alert rules render for always-on alerts"
ALERTS="$WORKTREE/roles/backup/templates/prometheus-backup-alerts.yml.j2"
if grep -q "PgBackRestStanzaStatus" "$ALERTS" \
  && grep -q "PgBackRestFullBackupAge" "$ALERTS" \
  && grep -q "PgBackRestWalArchiveLag" "$ALERTS" \
  && grep -q "PgBackRestBackupError" "$ALERTS" \
  && grep -q "PgWalDiskUsage" "$ALERTS"; then
  ok "always-on alert rules present"
else
  fail "always-on alert rules missing"
fi

# ─── TC-BACKUP-015: restore.yml refuses without target_time ────────────────
echo "TC-BACKUP-015: restore.yml refuses without target_time"
RESTORE="$WORKTREE/restore.yml"
if grep -q "target_time is defined" "$RESTORE" \
  && grep -q "target_time | length > 0" "$RESTORE"; then
  ok "restore.yml asserts target_time"
else
  fail "restore.yml does not assert target_time"
fi

# ─── TC-BACKUP-016: restore.yml requires explicit confirmation ─────────────
echo "TC-BACKUP-016: restore.yml requires explicit confirmation"
RESTORE="$WORKTREE/restore.yml"
if grep -q "pause:" "$RESTORE" \
  && grep -qi "confirm" "$RESTORE"; then
  ok "restore.yml requires confirmation"
else
  fail "restore.yml does not require confirmation"
fi

# ─── TC-BACKUP-017: restore.yml takes fresh backup before overwrite ─────────
echo "TC-BACKUP-017: restore.yml takes fresh backup before overwrite"
RESTORE="$WORKTREE/restore.yml"
if grep -q "fresh full backup" "$RESTORE" \
  && grep -q "\-\-type=full" "$RESTORE"; then
  ok "restore.yml takes pre-restore backup"
else
  fail "restore.yml does not take pre-restore backup"
fi

# ─── TC-BACKUP-019: restore-verify.yml does not touch prod ─────────────────
echo "TC-BACKUP-019: restore-verify.yml does not touch prod"
VERIFY="$WORKTREE/restore-verify.yml"
if grep -q "throwaway" "$VERIFY" \
  && grep -q "\-\-no-delta" "$VERIFY" \
  && grep -q "\-\-archive-mode=off" "$VERIFY"; then
  ok "restore-verify.yml is non-destructive"
else
  fail "restore-verify.yml may touch prod"
fi

# ─── TC-BACKUP-027: backup.yml runs on-demand full backup ───────────────────
echo "TC-BACKUP-027: backup.yml runs on-demand full backup"
BACKUP_PB="$WORKTREE/backup.yml"
if grep -q "\-\-type=full" "$BACKUP_PB"; then
  ok "backup.yml runs full backup"
else
  fail "backup.yml does not run full backup"
fi

# ─── TC-BACKUP-020: pgsodium key backup script exists ──────────────────────
echo "TC-BACKUP-020: pgsodium key backup script exists"
PGSODIUM="$WORKTREE/roles/backup/templates/backup-scripts/backup-pgsodium.sh.j2"
if grep -q "pgsodium_root.key" "$PGSODIUM"; then
  ok "pgsodium key backup script exists"
else
  fail "pgsodium key backup script missing"
fi

# ─── TC-BACKUP-021: storage backup detects backend ─────────────────────────
echo "TC-BACKUP-021: storage backup detects backend"
STORAGE="$WORKTREE/roles/backup/templates/backup-scripts/backup-storage.sh.j2"
if grep -q "STORAGE_BACKEND" "$STORAGE" \
  && grep -qi "skipped" "$STORAGE"; then
  ok "storage backup detects backend"
else
  fail "storage backup does not detect backend"
fi

# ─── TC-BACKUP-022: prometheus scrape target in backup compose ─────────────
echo "TC-BACKUP-022: prometheus scrape target in backup compose"
COMPOSE_BACKUP="$WORKTREE/roles/backup/templates/docker-compose-backup.yml.j2"
if grep -q "pgbackrest-exporter" "$COMPOSE_BACKUP" \
  && grep -q "9854" "$COMPOSE_BACKUP"; then
  ok "exporter present in backup compose"
else
  fail "exporter missing from backup compose"
fi

# ─── TC-BACKUP-007: rustfs + rustfs-init render for local repo ────────────────
echo "TC-BACKUP-007: rustfs + rustfs-init render for local repo"
COMPOSE_BACKUP="$WORKTREE/roles/backup/templates/docker-compose-backup.yml.j2"
if grep -q "backup_repo_type == 'rustfs'" "$COMPOSE_BACKUP" \
  && grep -q "rustfs:" "$COMPOSE_BACKUP" \
  && grep -q "rustfs-init:" "$COMPOSE_BACKUP" \
  && grep -q "127.0.0.1" "$COMPOSE_BACKUP"; then
  ok "rustfs + rustfs-init present"
else
  fail "rustfs + rustfs-init missing"
fi

# ─── TC-BACKUP-014: cron schedules render correctly ────────────────────────
echo "TC-BACKUP-014: cron schedules render correctly"
TASKS="$WORKTREE/roles/backup/tasks/main.yml"
if grep -q "backup_cron_full" "$TASKS" \
  && grep -q "backup_cron_diff" "$TASKS" \
  && grep -q "backup_cron_verify" "$TASKS"; then
  ok "cron schedules referenced in tasks"
else
  fail "cron schedules not referenced in tasks"
fi

# ─── TC-BACKUP-029: restore drill is opt-in ────────────────────────────────
echo "TC-BACKUP-029: restore drill is opt-in"
DEFAULTS="$WORKTREE/roles/backup/defaults/main.yml"
if grep -q "backup_restore_drill: false" "$DEFAULTS"; then
  ok "restore drill off by default"
else
  fail "restore drill not off by default"
fi

# ─── TC-BACKUP-034: prometheus.yml.j2 wires pgbackrest_exporter + alert rules ─
echo "TC-BACKUP-034: prometheus.yml.j2 wires pgbackrest_exporter + alert rules"
PROM="$WORKTREE/roles/monitor/templates/prometheus.yml.j2"
if grep -q "pgbackrest_exporter" "$PROM" \
  && grep -q "9854" "$PROM" \
  && grep -q "prometheus-backup-alerts.yml" "$PROM"; then
  ok "prometheus.yml.j2 wires exporter + alert rules"
else
  fail "prometheus.yml.j2 missing exporter scrape or alert rule_files"
fi

# ─── TC-BACKUP-035: pgsodium script uses docker exec (not docker compose run) ─
echo "TC-BACKUP-035: pgsodium script uses docker exec (not docker compose run)"
PGSODIUM="$WORKTREE/roles/backup/templates/backup-scripts/backup-pgsodium.sh.j2"
if grep -q "docker exec" "$PGSODIUM" \
  && ! grep -q "docker compose run" "$PGSODIUM"; then
  ok "pgsodium script uses docker exec"
else
  fail "pgsodium script still uses docker compose run"
fi

# ─── TC-BACKUP-036: db container does NOT mount docker binary (no docker socket) ──
echo "TC-BACKUP-036: db container does NOT mount docker binary (no docker socket)"
COMPOSE="$WORKTREE/roles/supabase/templates/docker-compose-supabase.yml.j2"
if ! grep -q "/usr/bin/docker:/usr/bin/docker:ro" "$COMPOSE" \
  && ! grep -q "/var/run/docker.sock:/var/run/docker.sock" "$COMPOSE"; then
  ok "db container does not bind-mount docker binary or socket"
else
  fail "db container still has docker socket/binary mount (should be removed)"
fi

# ─── TC-BACKUP-039: db container mounts pgbackrest binary + config (not spool) ──
echo "TC-BACKUP-039: db container mounts pgbackrest binary + config (not spool)"
# The host's pgbackrest binary is no longer bind-mounted straight onto
# /usr/bin/pgbackrest. It cannot be: the binary needs shared libraries the db
# image does not carry, so what goes there is a wrapper that exports
# LD_LIBRARY_PATH and execs the real binary out of /usr/lib/pgbackrest-bin.
# Both halves are asserted — a wrapper without its library directory is exactly
# the state in which archive-push fails with "not found".
if grep -q "pgbackrest-wrapper:/usr/bin/pgbackrest:ro" "$COMPOSE" \
  && grep -q "pgbackrest-bin:/usr/lib/pgbackrest-bin:ro" "$COMPOSE" \
  && grep -q "pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro" "$COMPOSE" \
  && ! grep -q "backup_spool_host_path" "$COMPOSE"; then
  ok "db container mounts pgbackrest wrapper + libs + config, no spool"
else
  fail "db container missing pgbackrest mounts or still has spool mount"
fi

# ─── TC-BACKUP-037: restore.yml pre-restore backup is best-effort ───────────
echo "TC-BACKUP-037: restore.yml pre-restore backup is best-effort"
RESTORE="$WORKTREE/restore.yml"
if grep -q "failed_when: false" "$RESTORE" \
  && grep -q "skip_pre_backup" "$RESTORE"; then
  ok "restore.yml pre-restore backup is best-effort"
else
  fail "restore.yml pre-restore backup is a hard blocker"
fi

# ─── TC-BACKUP-038: restore-verify.yml uses trust auth ─────────────────────
echo "TC-BACKUP-038: restore-verify.yml uses trust auth"
VERIFY="$WORKTREE/restore-verify.yml"
if grep -q "POSTGRES_HOST_AUTH_METHOD=trust" "$VERIFY" \
  && ! grep -q "POSTGRES_PASSWORD=verify" "$VERIFY"; then
  ok "restore-verify.yml uses trust auth"
else
  fail "restore-verify.yml still uses POSTGRES_PASSWORD=verify"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────────"
echo "  PASS: $PASS    FAIL: $FAIL"
echo "──────────────────────────────────────────"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1