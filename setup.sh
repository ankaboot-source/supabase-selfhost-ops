#!/bin/bash
# =============================================================================
# setup.sh — Deterministic, configuration-based Supabase installer.
# =============================================================================
# Reads config.yml, generates secrets, renders env/supabase.yml, enables the
# selected components in playbook-supabase.yml, then runs the deployment.
#
# Usable by humans and AI agents. The only file you need to edit is config.yml
# (copy it from config.example.yml).
#
# Usage:
#   sudo bash setup.sh              # generate + deploy
#   bash setup.sh --dry-run         # preview without modifying files
#   bash setup.sh --yes             # non-interactive (AI-friendly)
#   bash setup.sh --force           # regenerate secrets even if env is locked
#   bash setup.sh --help
# =============================================================================
# Locking: after the first successful render of env/supabase.yml, a lock file
# (env/.setup.lock) is written. On subsequent runs, the secrets block is
# skipped (preserving the already-rendered secrets) unless --force is passed.
# This prevents overwriting keys that running Supabase services depend on.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
EXAMPLE_CONFIG="${SCRIPT_DIR}/config.example.yml"
ENV_FILE="${SCRIPT_DIR}/env/supabase.yml"
PLAYBOOK_FILE="${SCRIPT_DIR}/playbook-supabase.yml"
GENERATE_KEYS="${SCRIPT_DIR}/generate-keys.sh"
LOCK_FILE="${SCRIPT_DIR}/env/.setup.lock"

DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
FORCE=0

# ─── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log()     { printf "${BLUE}[setup]${NC} %s\n" "$*"; }
ok()      { printf "${GREEN}[ok]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[warn]${NC} %s\n" "$*" >&2; }
die()     { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }
locklog() { printf "${YELLOW}[lock]${NC} %s\n" "$*"; }

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
setup.sh — Deterministic Supabase installer (configuration-based)

Usage:
  sudo bash setup.sh [options]

Options:
  --dry-run        Preview actions without modifying any files
  --yes            Non-interactive (skip confirmation prompts) — for AI/CI
  --force          Regenerate secrets even if env/supabase.yml is already locked
  -v, --verbose    Verbose output
  -h, --help       Show this help and exit

Workflow:
  1. Copy config.example.yml to config.yml
  2. Edit the REQUIRED section in config.yml
  3. Run: sudo bash setup.sh

The script:
  - Validates required fields are filled (not "changeit")
  - Auto-generates cryptographic secrets (unless secrets.generate: false)
  - Renders env/supabase.yml from your config
  - Enables selected components in playbook-supabase.yml
  - Runs the Ansible deployment via install.sh
EOF
}

# ─── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --yes)      ASSUME_YES=1; shift ;;
    --force)    FORCE=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ $VERBOSE -eq 1 ]] && set -x

# ─── Preflight checks ────────────────────────────────────────────────────────
[[ -f "$EXAMPLE_CONFIG" ]] || die "config.example.yml not found in $SCRIPT_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "config.yml not found.

  Copy the example and edit the REQUIRED section:
    cp config.example.yml config.yml
    # edit config.yml, then re-run:
    bash setup.sh"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required (Ansible depends on it). Install with: sudo apt install -y python3"

[[ -f "$ENV_FILE" ]]        || die "env/supabase.yml not found in $SCRIPT_DIR"
[[ -f "$PLAYBOOK_FILE" ]]   || die "playbook-supabase.yml not found in $SCRIPT_DIR"

# ─── YAML parsing via python3 ─────────────────────────────────────────────────
# Reads a value from config.yml. Usage: cfg_get "required.deploy_user"
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
        print("")  # missing -> empty string
        sys.exit(0)
# Print scalar; for bools print true/false; for lists/dicts print yaml
if isinstance(node, bool):
    print("true" if node else "false")
elif isinstance(node, (list, dict)):
    print(yaml.dump(node, default_flow_style=False).strip())
else:
    print(node if node is not None else "")
PYEOF
}

# Reads a boolean value; returns 0 if true, 1 if false/missing.
cfg_bool() {
  local val
  val="$(cfg_get "$1")"
  [[ "$val" == "true" ]]
}

# ─── Validation ───────────────────────────────────────────────────────────────
log "Validating config.yml…"

REQUIRED_FIELDS=(
  "required.deploy_user"
  "required.site_url"
  "required.api_external_url"
  "required.supabase_domain"
  "required.smtp_admin_email"
  "required.smtp_host"
  "required.smtp_user"
  "required.smtp_password"
)

MISSING=()
for field in "${REQUIRED_FIELDS[@]}"; do
  val="$(cfg_get "$field")"
  if [[ -z "$val" || "$val" == "changeit" ]]; then
    MISSING+=("$field")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  die "The following REQUIRED fields in config.yml are still set to 'changeit' or empty:

  $(printf '  - %s\n' "${MISSING[@]}")

Edit config.yml and fill in every field under the REQUIRED section."
fi

# Warn on enabled components with placeholder advanced config.
warn_component_placeholders() {
  local warnings=0
  if cfg_bool "components.backup"; then
    repo_type="$(cfg_get "advanced.backup.repo_type")"
    [[ -z "$repo_type" ]] && repo_type="minio"
    # Warn on local repo (no off-box protection)
    if [[ "$repo_type" == "minio" || "$repo_type" == "posix" ]]; then
      warn "components.backup: repo_type is '$repo_type' (local) — no off-box protection."
      warn "  If the server dies, the backups die with it. Use s3 for real protection."
      warnings=$((warnings + 1))
    fi
    # Warn on .env creds (plaintext)
    creds_source="$(cfg_get "advanced.backup.creds_source")"
    [[ -z "$creds_source" ]] && creds_source="env"
    if [[ "$creds_source" == "env" ]]; then
      warn "components.backup: creds_source is 'env' — credentials in plaintext .env."
      warn "  Use creds_source: vault for production."
      warnings=$((warnings + 1))
    fi
    # Warn on s3 repo with placeholder creds. Also reject an endpoint that
    # carries a URL path — pgBackRest's repo1-s3-endpoint is scheme://host[:port]
    # ONLY, it ignores any path (e.g. Supabase Cloud's .../storage/v1/s3), so
    # requests go to the wrong URL and fail with 404.
    if [[ "$repo_type" == "s3" ]]; then
      s3_endpoint="$(cfg_get "advanced.backup.s3_endpoint")"
      if [[ -n "$s3_endpoint" && "$s3_endpoint" != "changeit" ]]; then
        s3_path="$(python3 - "$s3_endpoint" <<'PY'
import sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
if u.netloc:
    print(u.path)
PY
)"
        if [[ "$s3_path" != "" && "$s3_path" != "/" ]]; then
          die "advanced.backup.s3_endpoint must be a host URL with NO path.

  Got:  $s3_endpoint
  Path: $s3_path

pgBackRest's repo1-s3-endpoint accepts only scheme://host[:port] — it cannot
use a URL with a path. Such an endpoint (e.g. Supabase Cloud Storage's
https://<project>.supabase.co/storage/v1/s3) is INCOMPATIBLE; pgBackRest drops
the path and every request 404s. Use e.g. https://s3.eu-west-1.amazonaws.com"
        fi
      fi
      for f in s3_endpoint s3_bucket s3_access_key s3_secret_key; do
        v="$(cfg_get "advanced.backup.$f")"
        if [[ -z "$v" || "$v" == "changeit" ]]; then
          warn "components.backup is enabled with s3 repo but advanced.backup.$f is '$v'."
          warnings=$((warnings + 1))
        fi
      done
    fi
  fi
  if cfg_bool "components.caddy"; then
    for f in sso_client_id sso_client_secret; do
      v="$(cfg_get "advanced.caddy.$f")"
      if [[ -z "$v" || "$v" == "changeit" ]]; then
        warn "components.caddy is enabled but advanced.caddy.$f is '$v'."
        warnings=$((warnings + 1))
      fi
    done
  fi
  if cfg_bool "components.luks"; then
    v="$(cfg_get "advanced.luks.device")"
    if [[ -z "$v" || "$v" == "changeit" ]]; then
      warn "components.luks is enabled but advanced.luks.device is '$v'."
      warnings=$((warnings + 1))
    fi
  fi
  return $warnings
}

if ! warn_component_placeholders; then
  warn "Some enabled components have unconfigured advanced fields. Deployment may fail."
  [[ $ASSUME_YES -eq 0 ]] && {
    read -rp "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."
  }
fi

ok "config.yml validated."

# ─── Dry-run summary ──────────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY RUN — no files will be modified."
  log "Would render: $ENV_FILE"
  log "Would update: $PLAYBOOK_FILE"
  log "Components to enable:"
  for c in caddy monitor fail2ban backup ufw luks hardening; do
    if cfg_bool "components.$c"; then
      printf "  + %s\n" "$c"
    fi
  done
  log "Dashboard log drain (required.enable_logging): $(cfg_get "required.enable_logging")"
  log "Would run: bash install.sh"
  ok "Dry run complete. Re-run without --dry-run to deploy."
  exit 0
fi

# ─── Confirmation ─────────────────────────────────────────────────────────────
if [[ $ASSUME_YES -eq 0 ]]; then
  printf "About to render env/supabase.yml, update the playbook, and deploy.\n"
  read -rp "Proceed? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

# ─── Secret generation ───────────────────────────────────────────────────────
gen_hex() { openssl rand -hex "$1"; }
gen_b64() { openssl rand -base64 "$1"; }
b64url()  { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
gen_jwt() {
  local jwt_secret="$1" payload="$2"
  local header='{"alg":"HS256","typ":"JWT"}'
  local hdr pld sig
  hdr=$(printf '%s' "$header" | b64url)
  pld=$(printf '%s' "$payload" | b64url)
  sig=$(printf '%s' "$hdr.$pld" | openssl dgst -binary -sha256 -hmac "$jwt_secret" | b64url)
  echo "$hdr.$pld.$sig"
}

# sed helper: replace a `key: value` line in env/supabase.yml (anchored at line start).
set_env_var() {
  local key="$1" val="$2"
  # cfg_get yields an empty string for a key that is absent from config.yml,
  # and writing that would replace the shipped default in env/supabase.yml with
  # nothing. env/supabase.yml is passed as extra-vars, which outrank role
  # defaults, so the blank wins everywhere — which is how backup_creds_source,
  # defaulted to "env" in both env/supabase.yml and roles/backup/defaults,
  # still reached the backup role empty and tripped its assertion. 33 of the
  # calls here read optional advanced.* keys, so this was latent in all of
  # them. Absent means "keep the default": skip rather than blank.
  # Callers that need to clear a value pass an explicit one.
  if [[ -z "$val" ]]; then
    return 0
  fi
  # Escape forward slashes and ampersands for sed replacement.
  local escaped
  escaped="$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')"
  # Substitution only replaces a line that is already there. A key this script
  # writes but env/supabase.yml does not carry matched nothing and was dropped
  # in silence — no error, no warning, the setting simply had no effect.
  # caddy_tls_internal was exactly that: config.yml asked for tls_internal,
  # setup.sh dutifully "wrote" it, and Caddy still went to Let's Encrypt for
  # .invalid hostnames. Append when the key is new.
  if grep -qE "^${key}:" "$ENV_FILE"; then
    sed -i "s|^${key}:.*|${key}: ${escaped}|" "$ENV_FILE"
  else
    printf '%s: %s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

log "Rendering env/supabase.yml…"

# Required fields
set_env_var "deploy_user"        "$(cfg_get "required.deploy_user")"
set_env_var "site_url"           "$(cfg_get "required.site_url")"
set_env_var "api_external_url"   "$(cfg_get "required.api_external_url")"
set_env_var "smtp_admin_email"   "$(cfg_get "required.smtp_admin_email")"
set_env_var "smtp_host"          "$(cfg_get "required.smtp_host")"
set_env_var "smtp_user"          "$(cfg_get "required.smtp_user")"
set_env_var "smtp_password"      "$(cfg_get "required.smtp_password")"

# Supabase dashboard log drain (Logflare + Vector). Defaults to true when the
# field is missing so upgraded configs keep logging.
log_drain="$(cfg_get "required.enable_logging")"
[[ -z "$log_drain" ]] && log_drain="true"
set_env_var "log_drain_enabled" "$log_drain"

# Supabase services — toggle each on/off before deploying. Defaults to true when
# the field is missing so upgraded configs keep every service. db and kong are
# always required and have no toggle (they are not read nor listed here).
for svc in auth rest realtime storage imgproxy functions studio meta supavisor; do
  val="$(cfg_get "required.services.${svc}")"
  [[ -z "$val" ]] && val="true"
  set_env_var "${svc}_enabled" "$val"
done

# docker_users is a list; the template has `- changeit` under it. Replace the
# first list item line (do NOT touch the `docker_users:` key — it must stay a list).
sed -i "s|^  - changeit.*|  - $(cfg_get "required.deploy_user")|" "$ENV_FILE"

# supabase dashboard domain (inside projects.supabase.domain)
python3 - "$ENV_FILE" "$(cfg_get "required.supabase_domain")" <<'PYEOF'
import sys, re
path, domain = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
# Replace the domain line under the supabase project block.
content = re.sub(
    r'(\nprojects:\n  supabase:.*?\n    domain:\s*)"[^"]*"',
    r'\1"%s"' % domain,
    content,
    count=1,
    flags=re.DOTALL,
)
with open(path, 'w') as f:
    f.write(content)
PYEOF

# deploy_env (optional)
deploy_env="$(cfg_get "advanced.deploy_env")"
if [[ -n "$deploy_env" && "$deploy_env" != "changeit" ]]; then
  set_env_var "deploy_env" "$deploy_env"
fi

# ─── Lock detection ──────────────────────────────────────────────────────────
# A lock file (env/.setup.lock) marks that env/supabase.yml has already been
# rendered with secrets. On a second run we MUST NOT regenerate or clobber
# those secrets — running Supabase services depend on them. --force overrides.
ENV_LOCKED=0
if [[ -f "$LOCK_FILE" ]]; then
  ENV_LOCKED=1
  if [[ $FORCE -eq 1 ]]; then
    locklog "Lock file found but --force given; secrets will be regenerated."
  else
    locklog "env/supabase.yml is already rendered (lock: $LOCK_FILE)."
    locklog "Secrets will be preserved. Run with --force to regenerate them."
  fi
fi

# Secrets
if [[ $ENV_LOCKED -eq 1 && $FORCE -eq 0 ]]; then
  # Locked and not forced: skip the entire secrets block so the existing
  # values in env/supabase.yml are left untouched. This covers BOTH failure
  # modes from issue #127:
  #   1. secrets.generate: true  → would overwrite existing keys with fresh
  #      ones, breaking running services.
  #   2. secrets.generate: false → would write `changeit` placeholders back
  #      over the previously-generated secrets, clobbering them.
  log "Skipping secret generation (env is locked)."
elif cfg_bool "secrets.generate"; then
  log "Auto-generating cryptographic secrets…"
  jwt_secret="$(gen_b64 30)"
  iat="$(date +%s)"
  exp=$((iat + 157680000)) # 5 years
  anon_key="$(gen_jwt "$jwt_secret" "{\"role\":\"anon\",\"iss\":\"supabase\",\"iat\":$iat,\"exp\":$exp}")"
  service_role_key="$(gen_jwt "$jwt_secret" "{\"role\":\"service_role\",\"iss\":\"supabase\",\"iat\":$iat,\"exp\":$exp}")"

  set_env_var "postgres_db_pwd"              "$(gen_hex 16)"
  set_env_var "sb_jwt_secret"                "$jwt_secret"
  set_env_var "sb_anon_key"                  "$anon_key"
  set_env_var "sb_service_role_key"          "$service_role_key"
  set_env_var "secret_key_base"              "$(gen_b64 48)"
  set_env_var "vault_enc_key"                "$(gen_hex 16)"
  set_env_var "pg_meta_crypto_key"           "$(gen_b64 24)"
  set_env_var "logflare_public_access_token" "$(gen_b64 24)"
  set_env_var "logflare_private_access_token" "$(gen_b64 24)"
  set_env_var "s3_protocol_access_key_id"    "$(gen_hex 16)"
  set_env_var "s3_protocol_access_key_secret" "$(gen_hex 32)"
  # Signs the SSO session tokens Caddy issues in front of Studio. It was the
  # one secret nobody generated: env/supabase.yml shipped a real, working key,
  # committed and identical on every install, so anyone reading this repository
  # could mint a valid session and walk past the SSO gate.
  set_env_var "jwt_shared_key"               "$(gen_b64 32)"
  ok "Secrets generated and written to env/supabase.yml."
else
  log "Using user-provided secrets from config.yml…"
  set_env_var "postgres_db_pwd"              "$(cfg_get "secrets.postgres_db_pwd")"
  set_env_var "sb_jwt_secret"                "$(cfg_get "secrets.sb_jwt_secret")"
  set_env_var "sb_anon_key"                  "$(cfg_get "secrets.sb_anon_key")"
  set_env_var "sb_service_role_key"           "$(cfg_get "secrets.sb_service_role_key")"
  set_env_var "secret_key_base"              "$(cfg_get "secrets.secret_key_base")"
  set_env_var "vault_enc_key"                "$(cfg_get "secrets.vault_enc_key")"
  set_env_var "pg_meta_crypto_key"           "$(cfg_get "secrets.pg_meta_crypto_key")"
  set_env_var "logflare_public_access_token" "$(cfg_get "secrets.logflare_public_access_token")"
  set_env_var "logflare_private_access_token" "$(cfg_get "secrets.logflare_private_access_token")"
  set_env_var "s3_protocol_access_key_id"    "$(cfg_get "secrets.s3_protocol_access_key_id")"
  set_env_var "s3_protocol_access_key_secret" "$(cfg_get "secrets.s3_protocol_access_key_secret")"
  ok "User-provided secrets written to env/supabase.yml."
fi

# ─── Advanced component config → env/supabase.yml ─────────────────────────────
if cfg_bool "components.caddy"; then
  # roles/caddy renders templates/Caddyfile-<SSO_PROVIDER>.j2 and those
  # filenames are lowercase, while config.example.yml documents "Generic" with
  # a capital G. Both spellings used to break, in opposite ways: "Generic"
  # matched the credential case below but resolved to a template that does not
  # exist, and "generic" found the template but fell through the case, leaving
  # the OIDC client id/secret at their placeholders. Normalise once, up front.
  sso_provider="$(cfg_get "advanced.caddy.sso_provider" | tr '[:upper:]' '[:lower:]')"
  set_env_var "SSO_PROVIDER"        "$sso_provider"
  set_env_var "root_domain"          "$(cfg_get "advanced.caddy.root_domain")"
  set_env_var "base_auth_domain"     "$(cfg_get "advanced.caddy.base_auth_domain")"
  # Certificates from Caddy's local CA rather than ACME. Off unless asked for;
  # CI needs it because Let's Encrypt cannot validate a name that is
  # deliberately unresolvable.
  if cfg_bool "advanced.caddy.tls_internal"; then
    set_env_var "caddy_tls_internal" "true"
  fi
  # Caddy source-IP allow list (inside projects.supabase.allowed_ips).
  # env/supabase.yml ships two placeholder addresses and nothing ever replaced
  # them, so the template's catch-all "respond 403" meant every deploy driven
  # from config.yml answered Forbidden to everyone but two example IPs. Absent
  # or empty now means no IP restriction at all.
  python3 - "$ENV_FILE" "$CONFIG_FILE" <<'PYEOF'
import sys, re, yaml
env_path, cfg_path = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = yaml.safe_load(f) or {}
ips = (((cfg.get('advanced') or {}).get('caddy') or {}).get('allowed_ips')) or []
with open(env_path) as f:
    content = f.read()
block = ("    allowed_ips:\n" + "".join("      - %s\n" % ip for ip in ips)
         if ips else "    allowed_ips: []\n")
content = re.sub(
    # DOTALL is needed for the non-greedy hop down to allowed_ips, so the list
    # items must use [^\n]* — a plain .* would match newlines too and swallow
    # the rest of the file, monitor block included.
    r'\n(projects:\n  supabase:.*?\n)    allowed_ips:\n(?:      - [^\n]*\n)+',
    lambda m: "\n" + m.group(1) + block,
    content,
    count=1,
    flags=re.DOTALL,
)
with open(env_path, 'w') as f:
    f.write(content)
PYEOF

  # SSO credentials are provider-specific; map common fields.
  case "$sso_provider" in
    github)
      set_env_var "github_oauth_client_id"     "$(cfg_get "advanced.caddy.sso_client_id")"
      set_env_var "github_oauth_client_secret" "$(cfg_get "advanced.caddy.sso_client_secret")"
      allow_list="$(cfg_get "advanced.caddy.sso_allow_list")"
      [[ -n "$allow_list" ]] && set_env_var "github_allow_list" "$allow_list"
      ;;
    gitlab)
      set_env_var "gitlab_oauth_client_id"     "$(cfg_get "advanced.caddy.sso_client_id")"
      set_env_var "gitlab_oauth_client_secret" "$(cfg_get "advanced.caddy.sso_client_secret")"
      allow_list="$(cfg_get "advanced.caddy.sso_allow_list")"
      [[ -n "$allow_list" ]] && set_env_var "gitlab_allow_list" "$allow_list"
      ;;
    discord)
      set_env_var "discord_oauth_client_id"    "$(cfg_get "advanced.caddy.sso_client_id")"
      set_env_var "discord_oauth_client_secret" "$(cfg_get "advanced.caddy.sso_client_secret")"
      # no allow list — Discord uses role-based auth (admin_role_id + discord_guild_id)
      ;;
    generic)
      set_env_var "oidc_client_id"             "$(cfg_get "advanced.caddy.sso_client_id")"
      set_env_var "oidc_client_secret"         "$(cfg_get "advanced.caddy.sso_client_secret")"
      allow_list="$(cfg_get "advanced.caddy.sso_allow_list")"
      [[ -n "$allow_list" ]] && set_env_var "generic_allow_list" "$allow_list"
      ;;
  esac
fi

if cfg_bool "components.monitor"; then
  set_env_var "GRAFANA_SERVER_ROOT_URL" "$(cfg_get "advanced.monitor.grafana_root_url")"
  set_env_var "GRAFANA_ALERT_HOST"      "$(cfg_get "advanced.monitor.grafana_alert_host")"

  # monitor domain (inside projects.monitor.domain)
  python3 - "$ENV_FILE" "$(cfg_get "advanced.monitor.domain")" <<'PYEOF'
import sys, re
path, domain = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(
    r'(\nprojects:.*?\n  monitor:.*?\n    domain:\s*)"[^"]*"',
    r'\1"%s"' % domain,
    content,
    count=1,
    flags=re.DOTALL,
)
with open(path, 'w') as f:
    f.write(content)
PYEOF

  if cfg_bool "advanced.monitor.anonymous_enabled"; then
    set_env_var "GRAFANA_AUTH_ANONYMOUS_ENABLED" "true"
  else
    set_env_var "GRAFANA_AUTH_ANONYMOUS_ENABLED" "false"
    set_env_var "GRAFANA_AUTH_BASIC_ENABLED" "true"
    set_env_var "GRAFANA_ADMIN_PASSWORD" "$(cfg_get "advanced.monitor.admin_password")"
  fi

  # ── Alerts (container down / disk / memory) + alert-email SMTP ──
  if cfg_bool "advanced.monitor.alerts_enabled"; then
    set_env_var "grafana_alerts_enabled" "true"
    set_env_var "grafana_alert_email"            "$(cfg_get "advanced.monitor.alert_emails")"
    set_env_var "grafana_alert_disk_threshold"   "$(cfg_get "advanced.monitor.alert_disk_threshold")"
    set_env_var "grafana_alert_memory_threshold" "$(cfg_get "advanced.monitor.alert_memory_threshold")"

    # grafana_alert_containers is a LIST — set_env_var would corrupt it (it
    # seds a `key: value` line). Replace the list items via Python instead.
    python3 - "$ENV_FILE" "$CONFIG_FILE" <<'PYEOF'
import sys, re, yaml
env_path, cfg_path = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = yaml.safe_load(f) or {}
containers = (((cfg.get('advanced') or {}).get('monitor') or {}).get('alert_containers')) or []
if not containers:
    containers = ['supabase-envoy', 'supabase-db']
items = "\n".join("  - %s" % c for c in containers)
with open(env_path) as f:
    content = f.read()
replaced, n = re.subn(
    r'(grafana_alert_containers:\n)(?:  -.*\n?)*',
    lambda m: m.group(1) + items + "\n",
    content,
    count=1,
)
if n == 0:
    sys.exit("grafana_alert_containers key not found in env/supabase.yml")
with open(env_path, 'w') as f:
    f.write(replaced)
PYEOF

    # Alert-email SMTP: prefer advanced.monitor.smtp_*; fall back to required.smtp_*
    smtp_host="$(cfg_get "advanced.monitor.smtp_host")"
    smtp_user="$(cfg_get "advanced.monitor.smtp_user")"
    smtp_pass="$(cfg_get "advanced.monitor.smtp_password")"
    smtp_sender="$(cfg_get "advanced.monitor.smtp_sender")"
    [[ -z "$smtp_host" || "$smtp_host" == "changeit" ]] && smtp_host="$(cfg_get "required.smtp_host")"
    [[ -z "$smtp_user" || "$smtp_user" == "changeit" ]] && smtp_user="$(cfg_get "required.smtp_user")"
    [[ -z "$smtp_pass" || "$smtp_pass" == "changeit" ]] && smtp_pass="$(cfg_get "required.smtp_password")"
    [[ -z "$smtp_sender" || "$smtp_sender" == "changeit" ]] && smtp_sender="$(cfg_get "required.smtp_admin_email")"
    [[ -n "$smtp_host" ]] && set_env_var "GRAFANA_SMTP_HOST"   "$smtp_host"
    [[ -n "$smtp_user" ]] && set_env_var "GRAFANA_SMTP_USER"   "$smtp_user"
    [[ -n "$smtp_pass" ]] && set_env_var "GRAFANA_SMTP_PASSWORD" "$smtp_pass"
    [[ -n "$smtp_sender" ]] && set_env_var "GRAFANA_SMTP_SENDER" "$smtp_sender"
  fi
fi

if cfg_bool "components.backup"; then
  set_env_var "backup_enabled" "true"
  repo_type="$(cfg_get "advanced.backup.repo_type")"
  [[ -z "$repo_type" ]] && repo_type="minio"
  set_env_var "backup_repo_type" "$repo_type"

  # S3 repo config
  set_env_var "backup_s3_endpoint" "$(cfg_get "advanced.backup.s3_endpoint")"
  set_env_var "backup_s3_region" "$(cfg_get "advanced.backup.s3_region")"
  set_env_var "backup_s3_bucket" "$(cfg_get "advanced.backup.s3_bucket")"
  set_env_var "backup_s3_key" "$(cfg_get "advanced.backup.s3_access_key")"
  set_env_var "backup_s3_key_secret" "$(cfg_get "advanced.backup.s3_secret_key")"
  set_env_var "backup_s3_uri_style" "$(cfg_get "advanced.backup.s3_uri_style")"
  s3_verify="$(cfg_get "advanced.backup.s3_verify_tls")"
  [[ -z "$s3_verify" ]] && s3_verify="true"
  set_env_var "backup_s3_verify_tls" "$s3_verify"

  # MinIO creds (for local repo) — map to backup_s3_key/secret so templates work
  if [[ "$repo_type" == "minio" ]]; then
    minio_user="$(cfg_get "advanced.backup.minio_root_user")"
    minio_pass="$(cfg_get "advanced.backup.minio_root_password")"
    [[ -n "$minio_user" ]] && set_env_var "backup_s3_key" "$minio_user"
    [[ -n "$minio_pass" ]] && set_env_var "backup_s3_key_secret" "$minio_pass"
  else
    set_env_var "minio_root_user" "$(cfg_get "advanced.backup.minio_root_user")"
    set_env_var "minio_root_password" "$(cfg_get "advanced.backup.minio_root_password")"
  fi

  # Encryption — forced ON for external (s3) repo
  encryption="$(cfg_get "advanced.backup.encryption")"
  [[ -z "$encryption" ]] && encryption="false"
  if [[ "$repo_type" == "s3" ]]; then
    encryption="true"
    log "Forcing backup_encryption=true for external s3 repo."
  fi
  set_env_var "backup_encryption" "$encryption"
  if [[ "$encryption" == "true" ]]; then
    # Generate a cipher passphrase only if not already set (avoid clobbering
    # an existing passphrase — that would make existing backups unrecoverable).
    existing_pass="$(grep -E '^backup_cipher_pass:' "$ENV_FILE" 2>/dev/null | sed 's/^backup_cipher_pass: *//' | tr -d '\"' || true)"
    if [[ -z "$existing_pass" || "$existing_pass" == "changeit" ]]; then
      cipher_pass="$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")"
      set_env_var "backup_cipher_pass" "$cipher_pass"
      warn "backup_encryption is ON. Cipher passphrase generated and stored in env/supabase.yml."
      warn "  STORE THIS OFF THE SERVER (password manager). If lost, backups are unrecoverable."
    else
      log "Reusing existing backup_cipher_pass (not regenerating — preserves existing backups)."
    fi
  fi

  # Credentials source
  set_env_var "backup_creds_source" "$(cfg_get "advanced.backup.creds_source")"

  # Retention
  set_env_var "backup_retention_full" "$(cfg_get "advanced.backup.retention_full")"
  set_env_var "backup_retention_diff" "$(cfg_get "advanced.backup.retention_diff")"
  set_env_var "backup_retention_archive" "$(cfg_get "advanced.backup.retention_archive")"

  # Schedules
  set_env_var "backup_cron_full" "$(cfg_get "advanced.backup.cron_full")"
  set_env_var "backup_cron_diff" "$(cfg_get "advanced.backup.cron_diff")"
  set_env_var "backup_cron_verify" "$(cfg_get "advanced.backup.cron_verify")"

  # Restore drill
  set_env_var "backup_restore_drill" "$(cfg_get "advanced.backup.restore_drill")"

  # Storage + pgsodium backup
  set_env_var "backup_storage_enabled" "$(cfg_get "advanced.backup.storage_backup")"
  set_env_var "backup_pgsodium_enabled" "$(cfg_get "advanced.backup.pgsodium_backup")"
fi

if cfg_bool "components.luks"; then
  set_env_var "luks_device"     "$(cfg_get "advanced.luks.device")"
  set_env_var "luks_mount_point" "$(cfg_get "advanced.luks.mount_point")"
  # Enable the encryption flag
  python3 - "$ENV_FILE" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
content = re.sub(
    r'(supabase_encryption:\n  enabled:\s*)false',
    r'\1true',
    content,
)
with open(path, 'w') as f:
    f.write(content)
PYEOF
fi

# ─── Security hardening ──────────────────────────────────────────────────────
# Renders the harden_* vars in env/supabase.yml from advanced.hardening. Each
# subset has its own toggle (ssh / sysctl / filesystem); values are mapped from
# the config enums to the yes/no strings the role templates expect. A helper
# maps a config boolean to an SSH yes/no, inverting where the config expresses
# "enabled hardening" as true (e.g. password_auth: true -> PasswordAuthentication no).
hard_fn() { # hard_fn <config-bool> <val-if-true> <val-if-false>
  if cfg_bool "$1"; then echo "$2"; else echo "$3"; fi
}

if cfg_bool "components.hardening"; then
  # --- SSH ---
  if cfg_bool "advanced.hardening.ssh.enabled"; then
    set_env_var "harden_ssh_enabled"             "true"
    set_env_var "harden_ssh_permit_root_login"    "$(hard_fn advanced.hardening.ssh.permit_root_login yes no)"
    set_env_var "harden_ssh_password_auth"        "$(hard_fn advanced.hardening.ssh.password_auth no yes)"
    set_env_var "harden_ssh_pubkey_auth"          "yes"
    set_env_var "harden_ssh_permit_empty_passwords" "no"
    set_env_var "harden_ssh_max_auth_tries"       "$(cfg_get advanced.hardening.ssh.max_auth_tries)"
    set_env_var "harden_ssh_login_grace_time"     "$(cfg_get advanced.hardening.ssh.login_grace_time)"
    set_env_var "harden_ssh_allow_tcp_forwarding" "$(hard_fn advanced.hardening.ssh.allow_tcp_forwarding yes no)"
    set_env_var "harden_ssh_x11_forwarding"       "$(hard_fn advanced.hardening.ssh.x11_forwarding yes no)"
    set_env_var "harden_ssh_allow_agent_forwarding" "$(hard_fn advanced.hardening.ssh.allow_agent_forwarding yes no)"
    set_env_var "harden_ssh_client_alive_interval" "$(cfg_get advanced.hardening.ssh.client_alive_interval)"
    set_env_var "harden_ssh_client_alive_count_max" "$(cfg_get advanced.hardening.ssh.client_alive_count_max)"
    set_env_var "harden_ssh_use_dns"              "$(hard_fn advanced.hardening.ssh.use_dns yes no)"
  fi

  # --- sysctl ---
  if cfg_bool "advanced.hardening.sysctl.enabled"; then
    set_env_var "harden_sysctl_enabled" "true"
    # Build the Docker-safe sysctl key dict from the individual toggles.
    python3 - "$ENV_FILE" "$CONFIG_FILE" <<'PYEOF'
import sys, re, yaml
env_path, cfg_path = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = yaml.safe_load(f) or {}
h = (((cfg.get('advanced') or {}).get('hardening') or {}).get('sysctl')) or {}
def b(k):
    v = h.get(k)
    return '1' if v in (True, 'true', 'True') else '0'
def nb(k):
    # inverted: for "drop/disable" toggles the enabling True maps to sysctl 0.
    v = h.get(k)
    return '0' if v in (True, 'true', 'True') else '1'
s = {
    'net.ipv4.tcp_syncookies': b('tcp_syncookies'),
    'net.ipv4.conf.all.rp_filter': b('rp_filter'),
    'net.ipv4.conf.default.rp_filter': b('rp_filter'),
    'net.ipv4.conf.all.log_martians': b('log_martians'),
    'net.ipv4.conf.default.log_martians': b('log_martians'),
    'net.ipv4.conf.all.accept_source_route': nb('drop_source_route'),
    'net.ipv4.conf.default.accept_source_route': nb('drop_source_route'),
    'net.ipv4.conf.all.accept_redirects': nb('drop_redirects'),
    'net.ipv4.conf.default.accept_redirects': nb('drop_redirects'),
    'net.ipv4.conf.all.send_redirects': nb('drop_redirects'),
    'net.ipv4.conf.default.send_redirects': nb('drop_redirects'),
    'net.ipv4.icmp_echo_ignore_broadcasts': b('ignore_broadcast_pings'),
    'net.ipv4.icmp_ignore_bogus_error_responses': '1',
    'net.ipv4.tcp_rfc1337': b('rfc1337'),
    'kernel.randomize_va_space': '2' if h.get('aslr_full') else '0',
    'kernel.core_uses_pid': b('core_uses_pid'),
    'fs.suid_dumpable': nb('disable_suid_dumps'),
}
with open(env_path) as f:
    content = f.read()
block = "\n".join("  %s: %s" % (k, '"%s"' % v) for k, v in s.items())
content = re.sub(
    r'(harden_sysctl_keys:\n)(?:  [^\n]*\n?)*',
    lambda m: m.group(1) + block + "\n",
    content,
    count=1,
)
with open(env_path, 'w') as f:
    f.write(content)
PYEOF
  fi

  # --- filesystem ---
  if cfg_bool "advanced.hardening.filesystem.enabled"; then
    set_env_var "harden_fs_enabled" "true"
  fi
fi

ok "env/supabase.yml rendered."

# ─── Write lock file ─────────────────────────────────────────────────────────
# Mark env/supabase.yml as rendered so subsequent runs don't clobber secrets.
# The lock is a small JSON record. --force rewrites it; --dry-run never does.
python3 - "$LOCK_FILE" "$CONFIG_FILE" <<'PYEOF'
import sys, json, os, time
lock_path, cfg_path = sys.argv[1], sys.argv[2]
record = {
    "rendered_at": int(time.time()),
    "config_file": cfg_path,
    "note": "env/supabase.yml has been rendered with secrets. Re-run setup.sh with --force to regenerate.",
}
os.makedirs(os.path.dirname(lock_path), exist_ok=True)
with open(lock_path, "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
PYEOF
ok "Lock written: $LOCK_FILE"

# ─── Playbook component toggling ─────────────────────────────────────────────
# Regenerate playbook-supabase.yml deterministically from the component toggles.
# This avoids fragile line-by-line uncommenting and keeps the playbook structure
# valid YAML regardless of which components are enabled.
log "Updating playbook-supabase.yml with selected components…"

python3 - "$PLAYBOOK_FILE" "$CONFIG_FILE" <<'PYEOF'
import sys, yaml
path, cfg_path = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = yaml.safe_load(f)
components = cfg.get("components", {}) or {}

# Build the new playbook. The bootstrap play runs first with gather_facts: false
# to install Python on minimal cloud images / Arch (which ships `python` only),
# then the main play runs the always-on roles (docker, supabase, manifest,
# agent_access) followed by the enabled advanced roles in a fixed canonical
# order. The manifest + agent_access roles are always-on (not component-toggled)
# because the instance manifest is a contract and SSH-stdio agent access is
# part of the default deployment.

bootstrap_play = """---
# Bootstrap Python on minimal targets before anything else.
# Arch ships `python` only; minimal Ubuntu cloud images may ship no python3.
# gather_facts: false + raw bootstrap keeps this distro-independent.
- hosts: localhost
  gather_facts: false
  become: true
  tasks:
    - name: Bootstrap Python (distro-aware)
      ansible.builtin.raw: |
        if [ -x /usr/bin/apt-get ]; then
          apt-get update -qq && apt-get install -y -qq python3 python3-apt
        elif [ -x /usr/bin/pacman ]; then
          pacman -Sy --noconfirm python
        else
          exit 1
        fi
"""

main_play_header = """
- hosts: localhost
  become: true
  roles:
   # ─── Always-on (prerequisites + instance contract) ───
   - docker                    # Docker Engine + Compose v2 (Debian family + Arch)
"""

# LUKS is emitted before supabase, not with the other advanced roles. When
# encryption is on, supabase_data_path *is* luks_mount_point, so running it
# afterwards meant the supabase role created that directory on the root disk,
# Postgres initialised its PGDATA there in the clear, and the encrypted volume
# was then mounted on top — hiding a live database behind an empty filesystem
# and leaving its data unencrypted on the disk underneath. The volume has to
# exist and be mounted before anything writes to it.
early_role_lines = []
if components.get("luks"):
    early_role_lines.append("   - role: luks              # At-rest disk encryption (LUKS)")
    early_role_lines.append("     when: supabase_encryption.enabled")

main_play_body = """   - supabase                  # Full Supabase stack
   - manifest                  # /etc/supabase/instance.json — instance contract
   - agent_access              # SSH-stdio MCP agent + info CLI

   # ─── Advanced Roles ───────────────────────────────
   # Enabled via config.yml (components). See docs/advanced-docs.md.
"""

role_lines = []
if components.get("ufw"):
    role_lines.append("   - ufw                     # Firewall — allow/deny rules per port")
if components.get("caddy"):
    role_lines.append("   - caddy                   # Reverse proxy + automatic TLS + SSO")
if components.get("monitor"):
    role_lines.append("   - monitor                 # Grafana + Prometheus + Loki stack")
if components.get("fail2ban"):
    role_lines.append("   - fail2ban                # Brute-force protection for Postgres")
if components.get("backup"):
    role_lines.append("   - backup                  # Automated backups + PITR (pgBackRest)")
if components.get("hardening"):
    role_lines.append("   - hardening               # OS security hardening (SSH/sysctl/fs)")

content = bootstrap_play + main_play_header
if early_role_lines:
    content += "\n".join(early_role_lines) + "\n"
content += main_play_body
if role_lines:
    content += "\n".join(role_lines) + "\n"
else:
    content += "   # (no advanced components enabled in config.yml)\n"

with open(path, 'w') as f:
    f.write(content)
PYEOF

ok "playbook-supabase.yml updated."

# ─── Deploy ───────────────────────────────────────────────────────────────────
log "Starting deployment via install.sh…"
cd "$SCRIPT_DIR"
bash install.sh
ok "Deployment complete."
