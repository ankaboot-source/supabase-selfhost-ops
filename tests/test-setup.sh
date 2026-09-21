#!/bin/bash
# test-setup.sh — Tests for the deterministic installer (setup.sh)
# Run: bash tests/test-setup.sh
# Shell-level tests that validate setup.sh behavior without running Ansible
# (the deploy step is stubbed out).

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
  # Remove any stale lock file copied from the real env/ (tests manage it explicitly)
  rm -f "$d/env/.setup.lock"
  cat > "$d/install.sh" <<'STUB'
#!/bin/bash
echo "STUBBED_INSTALL_OK"
STUB
  chmod +x "$d/install.sh" "$d/setup.sh" "$d/generate-keys.sh"
  echo "$d"
}

# Run setup in sandbox; sets OUT and RC variables in caller scope.
run_setup_rc() {
  local dir="$1"; shift
  OUT="$( cd "$dir" && bash setup.sh "$@" 2>&1 )" && RC=0 || RC=$?
}

# Fill all required fields in a config.yml with valid test values.
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

# ─── TC-SETUP-001: Missing config.yml ────────────────────────────────────────
echo "TC-SETUP-001: missing config.yml"
d="$(make_sandbox tc001)"
rm -f "$d/config.yml"
run_setup_rc "$d" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "config.yml not found"; then
  ok "exits non-zero with clear message"
else
  fail "expected non-zero exit + 'config.yml not found' (got rc=$RC)"
fi

# ─── TC-SETUP-002: Required fields left as changeit ──────────────────────────
echo "TC-SETUP-002: required fields left as changeit"
d="$(make_sandbox tc002)"
cp "$d/config.example.yml" "$d/config.yml"
run_setup_rc "$d" --yes
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "REQUIRED fields"; then
  ok "exits non-zero listing required fields"
else
  fail "expected non-zero exit listing required fields (got rc=$RC)"
fi

# ─── TC-SETUP-011: config.example.yml is valid YAML ──────────────────────────
echo "TC-SETUP-011: config.example.yml is valid YAML"
if python3 -c "import yaml; d=yaml.safe_load(open('$EXAMPLE')); \
  assert set(['required','secrets','components','advanced']).issubset(d.keys())" 2>/dev/null; then
  ok "valid YAML with expected top-level keys"
else
  fail "config.example.yml is not valid YAML or missing top-level keys"
fi

# ─── TC-SETUP-009: Help output ────────────────────────────────────────────────
echo "TC-SETUP-009: help output"
d="$(make_sandbox tc009)"
run_setup_rc "$d" --help
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -qi "Usage"; then
  ok "prints usage and exits 0"
else
  fail "expected exit 0 with Usage (got rc=$RC)"
fi

# ─── TC-SETUP-008: Dry-run does not modify files ──────────────────────────────
echo "TC-SETUP-008: dry-run does not modify files"
d="$(make_sandbox tc008)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
env_before="$(sha256sum "$d/env/supabase.yml" | cut -d' ' -f1)"
pb_before="$(sha256sum "$d/playbook-supabase.yml" | cut -d' ' -f1)"
run_setup_rc "$d" --dry-run --yes
env_after="$(sha256sum "$d/env/supabase.yml" | cut -d' ' -f1)"
pb_after="$(sha256sum "$d/playbook-supabase.yml" | cut -d' ' -f1)"
if [[ $RC -eq 0 && "$env_before" == "$env_after" && "$pb_before" == "$pb_after" ]]; then
  ok "dry-run leaves files unchanged"
else
  fail "dry-run modified files (rc=$RC, env_changed=$([[ $env_before == $env_after ]] && echo no || echo yes))"
fi

# ─── TC-SETUP-003: Auto-generate secrets ──────────────────────────────────────
echo "TC-SETUP-003: auto-generate secrets"
d="$(make_sandbox tc003)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "STUBBED_INSTALL_OK"; then
  if grep -q "^postgres_db_pwd: changeit" "$d/env/supabase.yml"; then
    fail "postgres_db_pwd still changeit after generation"
  elif grep -q "^sb_jwt_secret: changeit" "$d/env/supabase.yml"; then
    fail "sb_jwt_secret still changeit after generation"
  else
    ok "secrets auto-generated and written"
  fi
else
  fail "setup.sh failed during secret generation (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-SETUP-007: Required fields written to env/supabase.yml ────────────────
echo "TC-SETUP-007: required fields written to env/supabase.yml"
if [[ -n "${d:-}" ]] && grep -q "^deploy_user: ubuntu" "$d/env/supabase.yml" \
  && grep -q "^site_url: https://myapp.com" "$d/env/supabase.yml" \
  && grep -q "^api_external_url: https://sb.myapp.com" "$d/env/supabase.yml" \
  && grep -q "^smtp_host: mail.myapp.com" "$d/env/supabase.yml"; then
  ok "required fields present in env/supabase.yml"
else
  fail "required fields not found in env/supabase.yml"
fi

# ─── TC-SETUP-005: Enable a component (caddy) ─────────────────────────────────
echo "TC-SETUP-005: enable caddy component"
d="$(make_sandbox tc005)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
sed -i 's|caddy: false|caddy: true|' "$d/config.yml"
sed -i 's|sso_client_id: changeit|sso_client_id: myid|' "$d/config.yml"
sed -i 's|sso_client_secret: changeit|sso_client_secret: mysecret|' "$d/config.yml"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]]; then
  if grep -Eq '^[[:space:]]*-[[:space:]]+caddy\b' "$d/playbook-supabase.yml" \
    && ! grep -Eq '^[[:space:]]*#[[:space:]]*-[[:space:]]*caddy\b' "$d/playbook-supabase.yml"; then
    ok "caddy role uncommented in playbook"
  else
    fail "caddy role not enabled in playbook"
    grep -n caddy "$d/playbook-supabase.yml"
  fi
else
  fail "setup.sh failed with caddy enabled (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-SETUP-006: Components match the config.example.yml defaults ─────────
echo "TC-SETUP-006: components match the config.example.yml defaults"
d="$(make_sandbox tc006)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]]; then
  # config.example.yml ships with caddy/monitor/fail2ban on by default and
  # the rest off (PR #158) — the playbook must mirror exactly that set.
  if ! grep -Eq '^[[:space:]]*-[[:space:]]+caddy\b' "$d/playbook-supabase.yml" \
    || ! grep -Eq '^[[:space:]]*-[[:space:]]+monitor\b' "$d/playbook-supabase.yml" \
    || ! grep -Eq '^[[:space:]]*-[[:space:]]+fail2ban\b' "$d/playbook-supabase.yml"; then
    fail "default-enabled components (caddy/monitor/fail2ban) missing from playbook"
    cat "$d/playbook-supabase.yml"
  elif grep -Eq '^[[:space:]]*-[[:space:]]+(backup|ufw|hardening)\b' "$d/playbook-supabase.yml" \
    || grep -Eq '^[[:space:]]*-[[:space:]]*role:[[:space:]]+luks\b' "$d/playbook-supabase.yml"; then
    fail "default-disabled components (backup/ufw/luks/hardening) were enabled"
    cat "$d/playbook-supabase.yml"
  else
    ok "playbook mirrors the config.example.yml component defaults"
  fi
else
  fail "setup.sh failed with default config (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-SETUP-012: Non-interactive execution ──────────────────────────────────
echo "TC-SETUP-012: non-interactive (--yes) execution"
d="$(make_sandbox tc012)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
OUT="$( cd "$d" && bash setup.sh --yes </dev/null 2>&1 )" && RC=0 || RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "STUBBED_INSTALL_OK"; then
  ok "completes non-interactively with --yes"
else
  fail "blocked or failed with --yes (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-SETUP-013: Idempotent re-run ───────────────────────────────────────────
echo "TC-SETUP-013: idempotent re-run"
d="$(make_sandbox tc013)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes
RC1=$RC
run_setup_rc "$d" --yes
if [[ $RC1 -eq 0 && $RC -eq 0 ]] && echo "$OUT" | grep -q "STUBBED_INSTALL_OK"; then
  ok "second run completes successfully"
else
  fail "second run failed (rc1=$RC1 rc2=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-SETUP-014: env/supabase.yml remains valid YAML after render ───────────
echo "TC-SETUP-014: env/supabase.yml is valid YAML after setup"
d="$(make_sandbox tc014)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]] && python3 -c "import yaml,sys; d=yaml.safe_load(open('$d/env/supabase.yml')); \
   assert isinstance(d.get('docker_users'), list), 'docker_users must be a list'; \
   assert d.get('deploy_user') == 'ubuntu', 'deploy_user mismatch'" 2>/dev/null; then
  ok "env/supabase.yml is valid YAML with correct types"
else
  fail "env/supabase.yml is invalid YAML or has wrong types (rc=$RC)"
  python3 -c "import yaml; yaml.safe_load(open('$d/env/supabase.yml'))" 2>&1 | tail -5
fi

# ─── TC-SETUP-015: Enable monitor component with custom domain ─────────────────
echo "TC-SETUP-015: enable monitor component with custom domain"
d="$(make_sandbox tc015)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
sed -i 's|monitor: false|monitor: true|' "$d/config.yml"
sed -i 's|domain: monitor.example.com|domain: monitor.myapp.com|' "$d/config.yml"
sed -i 's|grafana_root_url: https://monitor.example.com|grafana_root_url: https://monitor.myapp.com|' "$d/config.yml"
sed -i 's|grafana_alert_host: monitor.example.com|grafana_alert_host: monitor.myapp.com|' "$d/config.yml"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]]; then
  if grep -q 'domain: "monitor.myapp.com"' "$d/env/supabase.yml" \
    && grep -q 'GRAFANA_ALERT_HOST: monitor.myapp.com' "$d/env/supabase.yml" \
    && grep -q 'GRAFANA_SERVER_ROOT_URL: https://monitor.myapp.com' "$d/env/supabase.yml"; then
    ok "monitor domain and grafana settings written to env/supabase.yml"
  else
    fail "monitor domain or grafana settings not found in env/supabase.yml"
    grep -n -i monitor "$d/env/supabase.yml"
  fi
else
  fail "setup.sh failed with monitor enabled (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-LOCK-001: First run writes lock file ──────────────────────────────────
echo "TC-LOCK-001: first run writes lock file"
d="$(make_sandbox tc_lock_001)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
rm -f "$d/env/.setup.lock"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 && -f "$d/env/.setup.lock" ]] \
  && ! grep -q "^postgres_db_pwd: changeit" "$d/env/supabase.yml"; then
  ok "first run creates lock file and generates secrets"
else
  fail "first run did not create lock file or generate secrets (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-LOCK-002: Second run preserves secrets (no --force) ───────────────────
echo "TC-LOCK-002: second run preserves secrets"
# Reuse tc_lock_001 sandbox (lock file + secrets already in place)
pwd_before="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
jwt_before="$(grep '^sb_jwt_secret:' "$d/env/supabase.yml" | awk '{print $2}')"
run_setup_rc "$d" --yes
pwd_after="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
jwt_after="$(grep '^sb_jwt_secret:' "$d/env/supabase.yml" | awk '{print $2}')"
if [[ $RC -eq 0 && "$pwd_before" == "$pwd_after" && "$jwt_before" == "$jwt_after" ]] \
  && echo "$OUT" | grep -q "\[lock\]"; then
  ok "second run preserves secrets and prints [lock] notice"
else
  fail "second run changed secrets or missing [lock] notice (rc=$RC)"
  echo "  pwd: $pwd_before -> $pwd_after"
  echo "  jwt: $jwt_before -> $jwt_after"
fi

# ─── TC-LOCK-003: --force regenerates secrets ─────────────────────────────────
echo "TC-LOCK-003: --force regenerates secrets"
# Reuse tc_lock_001 sandbox
pwd_before="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
run_setup_rc "$d" --yes --force
pwd_after="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
if [[ $RC -eq 0 && "$pwd_before" != "$pwd_after" ]] \
  && ! grep -q "^postgres_db_pwd: changeit" "$d/env/supabase.yml"; then
  ok "--force regenerates secrets (postgres_db_pwd changed)"
else
  fail "--force did not regenerate secrets (rc=$RC, changed=$([[ $pwd_before == $pwd_after ]] && echo no || echo yes))"
fi

# ─── TC-LOCK-004: Disabling generation does NOT clobber existing secrets ──────
echo "TC-LOCK-004: secrets.generate=false does not clobber locked env"
d="$(make_sandbox tc_lock_004)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes   # first run: generate + lock
pwd_before="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
jwt_before="$(grep '^sb_jwt_secret:' "$d/env/supabase.yml" | awk '{print $2}')"
# Now disable generation (leave secrets.* as changeit in config)
sed -i 's|generate: true|generate: false|' "$d/config.yml"
run_setup_rc "$d" --yes
pwd_after="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
jwt_after="$(grep '^sb_jwt_secret:' "$d/env/supabase.yml" | awk '{print $2}')"
if [[ $RC -eq 0 && "$pwd_before" == "$pwd_after" && "$jwt_before" == "$jwt_after" ]] \
  && echo "$OUT" | grep -q "\[lock\]"; then
  ok "generate=false preserves locked secrets (no clobber)"
else
  fail "generate=false clobbered locked secrets (rc=$RC)"
  echo "  pwd: $pwd_before -> $pwd_after"
  echo "  jwt: $jwt_before -> $jwt_after"
fi

# ─── TC-LOCK-005: --dry-run never writes a lock file ──────────────────────────
echo "TC-LOCK-005: dry-run never writes lock file"
d="$(make_sandbox tc_lock_005)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
rm -f "$d/env/.setup.lock"
run_setup_rc "$d" --dry-run --yes
if [[ $RC -eq 0 && ! -f "$d/env/.setup.lock" ]]; then
  ok "dry-run does not create lock file"
else
  fail "dry-run created a lock file (rc=$RC, exists=$([ -f "$d/env/.setup.lock" ] && echo yes || echo no))"
fi

# ─── TC-LOCK-006: --force on first run behaves like normal first run ──────────
echo "TC-LOCK-006: --force on first run"
d="$(make_sandbox tc_lock_006)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
rm -f "$d/env/.setup.lock"
run_setup_rc "$d" --yes --force
if [[ $RC -eq 0 && -f "$d/env/.setup.lock" ]] \
  && ! grep -q "^postgres_db_pwd: changeit" "$d/env/supabase.yml"; then
  ok "--force on first run creates lock + generates secrets"
else
  fail "--force on first run failed (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-LOCK-007: Lock file is valid JSON with expected fields ────────────────
echo "TC-LOCK-007: lock file is valid JSON"
d="$(make_sandbox tc_lock_007)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]] && python3 -c "import json,sys; \
   d=json.load(open('$d/env/.setup.lock')); \
   assert 'rendered_at' in d and 'config_file' in d" 2>/dev/null; then
  ok "lock file is valid JSON with rendered_at + config_file"
else
  fail "lock file is not valid JSON or missing fields (rc=$RC)"
fi

# ─── TC-LOCK-008: generate-keys.sh refuses without --force when locked ────────
echo "TC-LOCK-008: generate-keys.sh refuses when locked"
d="$(make_sandbox tc_lock_008)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes   # create lock + secrets
pwd_before="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
OUT="$( cd "$d" && sh generate-keys.sh 2>&1 )" && RC=$? || RC=$?
pwd_after="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
if [[ $RC -ne 0 && "$pwd_before" == "$pwd_after" ]] && echo "$OUT" | grep -qi "force"; then
  ok "generate-keys.sh refuses when locked and mentions --force"
else
  fail "generate-keys.sh did not refuse when locked (rc=$RC, changed=$([[ $pwd_before == $pwd_after ]] && echo no || echo yes))"
fi

# ─── TC-LOCK-009: generate-keys.sh --force regenerates when locked ────────────
echo "TC-LOCK-009: generate-keys.sh --force regenerates"
# Reuse tc_lock_008 sandbox
pwd_before="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
OUT="$( cd "$d" && sh generate-keys.sh --force 2>&1 )" && RC=0 || RC=$?
pwd_after="$(grep '^postgres_db_pwd:' "$d/env/supabase.yml" | awk '{print $2}')"
if [[ $RC -eq 0 && "$pwd_before" != "$pwd_after" ]]; then
  ok "generate-keys.sh --force regenerates secrets when locked"
else
  fail "generate-keys.sh --force did not regenerate (rc=$RC, changed=$([[ $pwd_before == $pwd_after ]] && echo no || echo yes))"
fi

# ─── TC-LOCK-010: generate-keys.sh runs freely when no lock exists ────────────
echo "TC-LOCK-010: generate-keys.sh runs when no lock"
d="$(make_sandbox tc_lock_010)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
rm -f "$d/env/.setup.lock"
OUT="$( cd "$d" && sh generate-keys.sh 2>&1 )" && RC=0 || RC=$?
if [[ $RC -eq 0 ]] && ! grep -q "^postgres_db_pwd: changeit" "$d/env/supabase.yml"; then
  ok "generate-keys.sh runs without lock and generates secrets"
else
  fail "generate-keys.sh failed without lock (rc=$RC)"
  echo "$OUT" | tail -20
fi

# ─── TC-SETUP-016: log drain enabled by default (required.enable_logging) ─────
echo "TC-SETUP-016: log drain enabled by default"
d="$(make_sandbox tc016)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]] && grep -q "^log_drain_enabled: true" "$d/env/supabase.yml"; then
  ok "default config renders log_drain_enabled: true"
else
  fail "default config did not render log_drain_enabled: true (rc=$RC)"
  grep -n "log_drain_enabled" "$d/env/supabase.yml" || echo "  (key missing)"
fi

# ─── TC-SETUP-017: enable_logging: false disables the log drain ───────────────
echo "TC-SETUP-017: enable_logging: false disables log drain"
d="$(make_sandbox tc017)"
cp "$d/config.example.yml" "$d/config.yml"
fill_required "$d"
sed -i 's|enable_logging: true|enable_logging: false|' "$d/config.yml"
run_setup_rc "$d" --yes
if [[ $RC -eq 0 ]] && grep -q "^log_drain_enabled: false" "$d/env/supabase.yml"; then
  ok "enable_logging: false renders log_drain_enabled: false"
else
  fail "enable_logging: false did not render log_drain_enabled: false (rc=$RC)"
  grep -n "log_drain_enabled" "$d/env/supabase.yml" || echo "  (key missing)"
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]