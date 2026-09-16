# Ansible-Supabase — AI Context

## Purpose
Deterministic, configuration-based Ansible deployer for self-hosted Supabase with optional components (Caddy SSO, monitoring, fail2ban, backups, UFW, LUKS).

## Workflow
```
config.yml  ──>  setup.sh  ──>  env/supabase.yml  ──>  ansible-playbook
                                        │
                              playbook-supabase.yml
                              (regenerated from component toggles)
```

The user edits **only** `config.yml` (copy of `config.example.yml`). `setup.sh` validates, renders env vars into `env/supabase.yml`, regenerates `playbook-supabase.yml`, then runs `install.sh` (which bootstraps Ansible and executes the playbook).

## Key Files
| File | Purpose |
|------|---------|
| `config.example.yml` | User-facing template — add new config fields here |
| `config.yml` | Actual config (gitignored) — single source of truth |
| `setup.sh` | Orchestrator: validates, renders secrets, writes env vars |
| `env/supabase.yml` | Ansible vars file — rendered by `setup.sh`, consumed by playbook |
| `playbook-supabase.yml` | Generated playbook — roles enabled/disabled by component toggles |
| `install.sh` | Ansible runner (pip install + ansible-playbook) |

## Roles (`roles/`)
Each role follows Ansible convention:
- `tasks/main.yml` — idempotent deployment logic
- `defaults/main.yml` — default variables
- `templates/` — Jinja2 templates

### Role: docker
Installs Docker Engine (official APT repo), `docker-compose-plugin`, and adds `deploy_user` to the `docker` group. Always runs first as a prerequisite.

### Role: supabase
Clones the official Supabase repo, renders the Docker Compose stack, configures the API gateway (**Envoy** by default, `api-gw`/`supabase-envoy`; a Kong fallback override `docker-compose.kong.yml` is also rendered but not active by default), sets up SSL certs (from Caddy or self-signed), and starts all Supabase services (Postgres, GoTrue, PostgREST, Realtime, Storage, Edge Functions, Studio, etc.). Templates: `docker-compose-supabase.yml.j2`, `docker-compose-kong.yml.j2` (Kong fallback override), `docker-compose-logs.yml.j2` (Logflare + Vector log-drain override, see below), `vector-logs.yml.j2` (<supabase_path>/volumes/logs/vector.yml — Vector pipeline that routes container logs to Logflare, container names templated with the `deploy_env` suffix), `kong-supabase.yml.j2` (Kong declarative config, used by the fallback), the four Envoy configs (`envoy.yaml.j2`, `cds.yaml.j2`, `lds.template.yaml.j2`, `docker-entrypoint.sh.j2`), `env-supabase.j2`, `start-supabase.sh.j2`.

The **log drain** (Studio dashboard logging) is a separate compose override: `docker-compose-logs.yml` (analytics/Logflare + vector). It ships in the repo always, but `start-supabase.sh` only boots it when `log_drain_enabled: true` (rendered by setup.sh from `required.enable_logging`, default `true` — set it `false` to disable log drain). The file is always rendered so `down` tears down orphaned analytics/vector when the drain is disabled.

### Role: caddy
Reverse proxy + automatic TLS + SSO. Four provider templates in `templates/`:
- `Caddyfile-github.j2` — uses `github_allow_list` (match sub)
- `Caddyfile-gitlab.j2` — uses `gitlab_allow_list` (match email)
- `Caddyfile-generic.j2` — uses `generic_allow_list` (match email)
- `Caddyfile-discord.j2` — no allow list; uses role-based auth via `admin_role_id` + `discord_guild_id`

Template selection: `{ src: "Caddyfile-{{ SSO_PROVIDER }}", dest: "/etc/caddy/Caddyfile" }`. Also creates the systemd unit and reloads/restarts caddy on config changes.

### Role: monitor
Deploys Grafana + Prometheus + Loki + cAdvisor + Node Exporter + Postgres Exporter + Promtail via Docker Compose. Ten templates including datasources, dashboards (pre-built server-stats dashboard), and config files. Supports anonymous access or basic auth with customizable passwords.

### Role: fail2ban
Installs fail2ban with a Postgres-specific jail that watches `/var/log/postgresql/postgresql.log` for failed auth attempts and bans offending IPs for 24 hours. Three templates: jail, action, and filter configs.

### Role: backup
Deploys pgBackRest running inside the Supabase `db` container (not a separate container), with continuous WAL archiving via native pgBackRest async mode, scheduled full + differential backups, point-in-time recovery (`restore.yml`), non-destructive restore verification (`restore-verify.yml`), on-demand backup (`backup.yml`), daily repo-integrity verification, Supabase Storage volume backup, pgsodium root-key backup, and Prometheus metrics + Grafana dashboard + alerting. Repo types: `minio` (local, default), `s3` (external), `posix` (local fs). Encryption is forced ON for external S3 repos. WAL archiving uses pgBackRest's native `archive-async` mode: the pgbackrest binary (Alpine) + shared libs are extracted from a Docker image to the host, a wrapper script sets `LD_LIBRARY_PATH` only for pgbackrest (not for PG itself), and `archive_command` runs `pgbackrest archive-push %p` directly. pgBackRest manages its own spool, queueing, and retry logic. All pgbackrest CLI commands (stanza-create, backup, verify, expire) execute via `docker exec supabase-db`. Templates: `pgbackrest.conf.j2`, `docker-compose-backup.yml.j2`, `backup-env.j2`, six `backup-scripts/*.j2`, `grafana/backup.json.j2`, `prometheus-backup-alerts.yml.j2`.

### Role: ufw
Configures UFW firewall — always allows SSH (port 22), then applies allow/deny rules from config (supports per-rule IP/CIDR restrictions). One template: `reset_ufw.sh.j2`.

### Role: luks
Encrypts a secondary block device with LUKS2 (AES-XTS-512), creates an `ext4` filesystem, mounts it, and configures automatic unlock at boot via crypttab/fstab. Includes a safeguard against encrypting the root device. No templates; one handler for `update-initramfs`.

## Operating on a Deployed Instance (Self-Hosted)

Most agents default to treating Supabase like the SaaS cloud product. This repo deploys a **self-hosted** stack on a VPS via Ansible, and the runtime shape is different. Read this section before running any command against a deployed instance.

### Context & Stack Architecture
- **Topology**: PostgreSQL and all Supabase services (GoTrue, PostgREST, Realtime, Storage, Edge Functions, Studio, **Envoy** (`api-gw`/`supabase-envoy`), Supavisor) run in Docker Compose on a single host. Caddy runs as a **native systemd service** (apt package, not a container) and acts as the reverse proxy + automatic TLS + OAuth2 SSO gateway (GitHub/GitLab/Generic/Discord). Envoy is the default API gateway (upstream since self-hosted v0.8.0); a Kong fallback override (`docker-compose.kong.yml`) is rendered but not booted by default.
- **Monitoring**: Observability is a separate Docker Compose stack — Prometheus, Loki, Grafana, cAdvisor, Node Exporter, Postgres Exporter, Promtail. Logflare/Analytics is opt-in via `required.enable_logging` (default `true`); when disabled, the gateway routes for `/analytics/v1/*` stay commented out and the Studio UI logs pane is empty.
- **Database**: PostgreSQL is bound to `127.0.0.1:5432` only — it is **never exposed to the public internet**. The Supavisor pooler is bound to `127.0.0.1:6543`. Both are reachable from the host loopback, not from outside.

### Where Things Live on the Host
| Path | Contents |
|------|----------|
| `/home/<deploy_user>/supabase/` | Cloned upstream Supabase repo (chowned to `deploy_user`) |
| `/home/<deploy_user>/supabase/docker/` | Rendered `docker-compose-supabase.yml`, `.env`, `start-supabase.sh`, Envoy configs (`volumes/api/envoy/`), Kong fallback (`docker-compose.kong.yml` + `volumes/api/kong.yml`) — this is the stack working directory (`supabase_path` var, default `supabase/docker`) |
| `/home/<deploy_user>/supabase/docker/volumes/functions/` | Edge Function source — each function is a subfolder (`<name>/index.ts`) mounted into the edge-runtime container (`/home/deno/functions`) and Studio (`/app/edge-functions`) |
| `/opt/postgres-certs/` | Postgres SSL certs (mounted read-only into the db container) |
| `/var/log/postgresql/` | Postgres logs (host-mounted into the db container — never inside the data dir) |
| `/etc/caddy/Caddyfile` | Caddy config (rendered from the SSO provider template) |
| `config.yml` (repo root, gitignored) | The single source of truth for the deploy — user edits only this |
| `env/supabase.yml` (repo root) | Rendered Ansible vars — consumed by the playbook, regenerated by `setup.sh` |

> **There is no `/etc/supabase/instance.json` manifest in this repo.** Do not invent one. The source of truth for connection parameters is `env/supabase.yml` (on the control machine) and the rendered `.env` at `/home/<deploy_user>/supabase/docker/.env` (on the deployed host). Read those before guessing ports, passwords, or container names.

### ⛔ Hard Rules (Never Violate)
1. **Read the rendered config first.** Always read `env/supabase.yml` (locally) or `/home/<deploy_user>/supabase/docker/.env` (on the host) BEFORE running commands. Never guess ports, keys, or container names — the `deploy_env` suffix can change container names (e.g. `supabase-db-prod`).
2. **No direct external DB access.** Never attempt a raw `psql` connection from your local machine — Postgres is bound to `127.0.0.1` and the firewall (UFW) blocks external DB access. DB tasks and migrations MUST run on the host via `docker exec supabase-db ...`, the Supabase CLI, or MCP over an SSH tunnel.
3. **Port routing**:
   - **Migrations / direct DDL**: Use the direct Postgres port `5432` (via `docker exec supabase-db psql ...` or the loopback-bound listener). Never run migrations through the pooler.
   - **App queries / TS typegen**: Use the Supavisor pooler port `6543` (transaction mode).
4. **Logs & monitoring**: The Studio UI logs pane works only when the log drain is enabled (`required.enable_logging: true` default). Otherwise use `docker logs --tail 100 <container>` or Grafana/Loki/Promtail.
5. **Caddy is a systemd service, not a container.** Inspect Caddy/SSO logs with `journalctl -u caddy -n 100 --no-pager`, not `docker logs caddy`. Restart with `systemctl restart caddy`, not `docker restart caddy`.

### 🚀 Standard Operating Recipes

**Run a migration**:
1. Read DB parameters from `env/supabase.yml` / the rendered `.env` (`POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_PORT=5432`).
2. Verify the latest backup succeeded (the `backup` role runs a cron S3 dump).
3. Apply the migration on the host, pointing at the **direct** port:
   ```bash
   docker exec -i supabase-db psql -U postgres -d <POSTGRES_DB> < migration.sql
   ```
   Or via Supabase CLI / MCP configured against `postgresql://postgres:<pwd>@127.0.0.1:5432/<db>`.

**Regenerate TypeScript types**:
```bash
supabase gen types typescript --db-url "postgresql://postgres:<pwd>@127.0.0.1:5432/<db>" > types/supabase.ts
```
Use the direct port (`5432`), not the pooler.

**Deploy / update an Edge Function**:
1. Copy the function folder onto the host under the functions volume (each function is a directory containing `index.ts`):
   ```bash
   scp -r ./my-function user@host:/home/<deploy_user>/supabase/docker/volumes/functions/
   ```
2. Restart the functions service so the edge-runtime picks up the new/changed code:
   ```bash
   cd /home/<deploy_user>/supabase/docker && docker compose restart functions
   ```
3. Verify: `curl https://<domain>/functions/v1/<name>` (gateway routes `/functions/v1/*` to the edge-runtime).
- `supabase functions deploy` targets Supabase **Cloud** projects and does **not** deploy to a self-hosted instance — self-hosted deployment is filesystem-based (copy into `volumes/functions` + restart). Function env vars/secrets live in the compose `environment:` block (or a `.env.functions` override); changing them requires recreating the container, not just restarting.

**Inspect logs & services**:
1. Resolve container names: `cd /home/<deploy_user>/supabase/docker && docker compose ps` (e.g. `supabase-db`, `supabase-envoy`, `supabase-rest`, `supabase-auth`, `supabase-studio`, `supabase-pooler`, `grafana`, `promtail`).
2. Fetch recent logs: `docker logs --tail 100 <container_name>`.
3. For HTTP 401/403 on Studio/Grafana (SSO issues): `journalctl -u caddy -n 100 --no-pager` — Caddy is a systemd unit, not a container.

**Restart services safely**:
- Never blind-`docker restart` the whole stack. Target a specific service:
  ```bash
  cd /home/<deploy_user>/supabase/docker
  docker compose restart rest        # PostgREST (schema cache reload)
  docker compose restart api-gw      # Envoy gateway (Kong fallback: `restart kong`)
  docker compose restart auth        # GoTrue
  ```
- To pick up `.env` / compose changes, `docker compose up -d` alone is **not** reliable — run `start-supabase.sh` (which does `down && up`), or `docker compose down && docker compose up -d` manually.

### 🧰 Troubleshooting Matrix

| Symptom | Common Cause | Fix |
| :--- | :--- | :--- |
| `Connection refused` / `Timeout` to `5432` from outside the host | DB is bound to `127.0.0.1` + UFW blocks external DB | SSH-tunnel into the host, then use `docker exec supabase-db` or loopback `127.0.0.1:5432` |
| `401 Unauthorized` on Studio/Grafana | Caddy SSO session expired or OAuth callback URL misconfigured | `journalctl -u caddy -n 100 --no-pager`; verify `API_EXTERNAL_URL` / `SITE_URL` in the rendered `.env` |
| PostgREST doesn't see new tables | PostgREST schema cache out of sync | `docker compose restart rest` (container `supabase-rest`) |
| Migration hangs or fails | Migration ran through the Supavisor pooler (`6543`) | Re-run pointing strictly at the **direct** port `5432` (`docker exec supabase-db psql ...`) |
| Empty logs in Studio UI | Log drain disabled (`required.enable_logging: false`) or analytics still starting | Verify `log_drain_enabled` in env/supabase.yml; else use `docker logs --tail 100 <container>` or Grafana/Loki |
| `403 {"message":"IP address not allowed: ..."}` on `/mcp` | Docker NATs host-originated traffic to the bridge gateway IP; the `ip-restriction` allow list must include the pinned subnet gateway (`172.28.0.1`) | See **MCP / Docker networking** pitfalls below; update `mcp_allowed_ips` to match the pinned subnet gateway |
| Kong fails to start after a route/plugin edit | A malformed plugin (e.g. `ip-restriction` with a YAML flow-list bug) breaks the startup healthcheck | Test on a staging route first; keep risky config commented until the runtime rejection is understood (see Kong pitfall below) |
| Edge Function returns `404` or serves stale code | Function folder not in `volumes/functions/` (`<name>/index.ts`), or edge-runtime not restarted after the copy | Copy the folder to `<supabase_path>/volumes/functions/` and `docker compose restart functions` |
| `supabase functions deploy` fails against the self-hosted host | The CLI deploys to Supabase **Cloud**, not self-hosted instances | Deploy by copying the function into `volumes/functions/` and restarting the `functions` service |

## Known Pitfalls & Lessons Learned

These are problems encountered while building this repo, and how they were fixed. Do not repeat them.

### Ansible / Jinja2
- **`environment` clashes with Ansible's reserved keyword** — using it as a variable name silently broke the container-name suffix rendering. Use `deploy_env`. Check against the literal placeholder (`!= 'changeit'`), not truthiness — the placeholder is non-empty.
- **`{% if %}` blocks leave stray whitespace/newlines in templated compose files** under trim_blocks. Use inline expressions instead: `{{ '-' + deploy_env if deploy_env != 'changeit' else '' }}`.
- **`{% for %}` block loops collapse onto one line under trim_blocks** and break YAML-only consumers. The Kong fallback's `ip-restriction` allow list must stay an inline expression (`allow: {{ mcp_allowed_ips }}` renders a YAML flow list). The Envoy `lds.template.yaml.j2` `/mcp` RBAC renders each `direct_remote_ip` principal via a `{% for ip in mcp_allowed_ips %}` loop with the tags at column 0 (each principal + `{{ ip }}` on its own line) — this survives all `trim_blocks`/`lstrip_blocks` combos, unlike the old collapsed-loop form. `verify-secure-mcp.py` renders under all `trim_blocks`/`lstrip_blocks` combos to catch this class.
- **`docker compose up -d` does not reliably pick up config/env changes.** `start-supabase.sh` must run `down && up` for changes to take effect.
- **Toggling the log drain requires tearing down with the override file too.** `docker compose -f docker-compose-supabase.yml down` only removes services defined in that file, so disabling the log drain (`required.enable_logging: false`) while analytics/vector are running would orphan them. `start-supabase.sh` always includes `-f docker-compose-logs.yml` in the `down` command whenever the override file exists (it is always rendered), and adds it to `up` only when `log_drain_enabled` is true.
- **Postgres refuses to init if its log dir is inside the data dir** ("data directory exists but is not empty"). Log to `/var/log/postgresql` (host-mounted into the container), never `/var/lib/postgresql/data/log`.
- **Mounted Postgres dirs and certs must use the image's real UID/GID** (currently 100/101 for the supabase postgres image), not guessed values.
- **After cloning the Supabase repo as root, chown the whole tree to `deploy_user` recursively**, or the stack can't write to it.
- **Kong route/plugin changes can break Kong's startup healthcheck** and take the whole API down (e.g. an `ip-restriction` plugin on `/mcp`). Test on a staging route before rolling out; keep risky config commented until the runtime rejection is understood. The original `/mcp` `ip-restriction` rejection was later root-caused to a Docker NAT source-IP mismatch — see **MCP / Docker networking** below.
- **`foo.bar is defined` raises UndefinedError when `foo` itself is undefined** — guarding a nested attribute with `is defined` is not enough. Use `foo is defined and foo.bar is defined`, or `(foo | default({})).bar | default('')` for a chain.
- **Ansible playbooks are single-document — a second top-level `---` breaks parsing.** Concatenating the bootstrap string + main header in `setup.sh` produced two `---` YAML doc markers; every run died with `but found another document` at line 20. Keep exactly one leading `---` in the assembled file (the generated `playbook-supabase.yml` is regenerated whole by `setup.sh` — fix the generator, then regenerate).
- **`X is undefined` is NOT a distro check when facts aren't gathered.** `when: ansible_os_family is undefined` under `gather_facts: false` is always true, so BOTH bootstrap branches (apt AND pacman) ran on every host and one always failed. Probe the platform inside the `raw` task itself (`[ -x /usr/bin/apt-get ]` vs `[ -x /usr/bin/pacman ]`, `else exit 1`).
- **Never define a variable in terms of itself.** `ansible_python_interpreter: "{{ ansible_playbook_python | default(ansible_python_interpreter | default('python3')) }}"` made the Ansible Templar recurse infinitely (`recursive loop detected … maximum recursion depth exceeded`). Jinja's `default` only short-circuits *undefined* vars; a *defined* var pulls its own self-referential value. Use `{{ ansible_playbook_python | default('python3') }}`.
- **`search('\barch\b')` never matches Arch.** `ID_LIKE` for Arch is `archlinux` — no word boundary after "arch" — so the docker role silently took the debian path on real Arch. Match the substring or read `ID` too, and note `community.general.pacman` needs that collection to be installed by the `install.sh` Ansible bootstrap.

### Postgres SSL / Certificates
- **Never put a config-driven value in `roles/*/defaults/main.yml`** — defaults are for constants only. The Postgres cert used to be generated with a hardcoded `postgres_domain: your-domain.com` placeholder, so every deployed cert had `CN=your-domain.com` and matched nothing. The role now reads `projects.supabase.domain` (the Caddy config domain, e.g. `sb.example.com`) directly, and an `assert` fails fast if it's still a placeholder.
- **A self-signed cert with only a `CN` (no SANs) fails `sslmode=verify-full`.** Generate with `-addext "subjectAltName=DNS:<domain>,DNS:localhost,IP:127.0.0.1[,IP:<server_ip>]"` so hostname verification works whether clients connect by domain, loopback, or the server's public IP.
- **`openssl req` writes the private key world-readable (0644)** and Postgres refuses to start ("private key file has group or world access"). chmod `0600` the key / `0644` the cert and chown both to the postgres image UID/GID (100/101) — done by the `Set ownership and permissions` task.
- **The `creates:` guard meant an existing wrong cert was never regenerated** after a domain change. Check the live cert with `openssl x509 -noout -subject -nameopt RFC2253` and regenerate when it doesn't match the configured domain. Always use `-nameopt RFC2253` — the default subject format differs between OpenSSL 1.1.1 (`/CN=...`) and 3.x (`CN = ...`), which breaks naive `grep` comparisons.
- **Prefer Caddy's real Let's Encrypt cert over self-signed** — look it up at `caddy_cert_base_path/<domain>/` (per-domain directory) and copy it; only fall back to self-signed when it's missing. The lookup only works if `caddy_cert_base_path` matches where Caddy actually stores certs.
- **SSL was dead code until the compose args were uncommented** — the db container had `-c ssl=on` / `ssl_cert_file` / `ssl_key_file` commented out, so Postgres ignored the mounted certs entirely.

### setup.sh / config flow
- **`set_env_var` uses `sed` on `key: value` lines — never run it on a list variable**, it corrupts the YAML (e.g. `docker_users`). For lists, replace only the `- item` line and leave the key line untouched.
- **When a rendered value may be empty or a placeholder, guard the write** with `[[ -n "$val" ]]` so template rendering doesn't break.
- **Regenerate the whole playbook from component toggles** — never edit it line-by-line/uncomment fragments.
- **Secret regeneration on a second `setup.sh` run breaks running Supabase services** (issue #127). The first successful render writes `env/.setup.lock`; subsequent runs skip the entire secrets block (whether `secrets.generate: true` or `false`) so the existing keys in `env/supabase.yml` are preserved byte-for-byte. `--force` overrides and regenerates. `--dry-run` never writes the lock. `generate-keys.sh` honors the same lock (`--force` to override). Never `set_env_var` a secrets field without first checking `ENV_LOCKED`/`FORCE`, or you reintroduce the clobber.

### Monitoring
- **Promtail's push URL must have a valid scheme** (`http://loki:3100/...`, not `http//loki:3100`).
- **Promtail can't read Docker container logs without both** the `/var/lib/docker/containers` mount and a `docker: {}` pipeline stage.
- **Bind Grafana/Loki/Prometheus/cAdvisor/node-exporter/Studio to `127.0.0.1` by default** — do not expose monitoring/admin ports on all interfaces.
- **Grafana home dashboards are silently ignored unless wired in**: templates must be named `home.json.j2`, copied to the target path, and enabled via `default_home_dashboard_path` in grafana.ini. Duplicate `home.json` / `home.json.j2` files cause confusion.
- **Grafana dashboard exports use `{{label_name}}` legend syntax that collides with Ansible**: a verbatim dashboard JSON shipped as `server-stats.json.j2` rendered `{{device}}`/`{{name}}`/`{{instance}}` as Ansible vars and failed with `'device' is undefined`. Wrap dashboard JSON in `{% raw %}`...`{% endraw %}` (renders byte-identical; no real Ansible vars in such files).
- **Never hardcode an OAuth provider as `enabled = true`** — gate it behind a toggle so placeholder credentials can't break Grafana startup.

### Caddy / SSO
- **After writing/fmt-ing the Caddyfile, reload/start caddy** (handler + systemd enable) or the new config is never applied.
- **SSO allow lists are provider-specific**: github matches sub, gitlab/generic match email, discord uses role-based auth and has no allow list.
- **Never emit the OIDC global block / auth host inside the `for project, cfg` loop.** All four `Caddyfile-*.j2` templates used to wrap *everything* in the project loop and re-emit, per OIDC-enabled project: (1) the global options block `{ order authenticate before respond; order authorize before basicauth; security { ... } }` and (2) the `https://{{ base_auth_domain }}` auth host. Both are constant — they don't depend on `cfg` at all — so enabling OIDC on more than one project rendered duplicate `order` directives, a second global `{ }` block mid-file, and a duplicated auth host, which Caddy refuses. **Fix:** emit the global `security` block and the auth site exactly once, *before* the loop, guarded by `{% if projects.values() | selectattr('oidc_enabled') | list | length > 0 %}`; only the per-project site block (`https://{{ cfg.domain }} ...`) stays inside the loop. This also keeps the Caddyfile valid when every project has `oidc_enabled: false`. There is a single shared `myportal`/`mypolicy`/`base_auth_domain` for all projects — per-project portals would require a template redesign.

### Auth / Email
- **An empty `ADDITIONAL_REDIRECT_URLS` makes GoTrue fall back to the SITE_URL root** and breaks the magic-link callback. Always template it from config.
- **Don't point `MAILER_TEMPLATES_*` at storage-object URLs** — they return 400 and GoTrue falls back to plaintext. Use a dedicated templates base URL.
- **GoTrue subject placeholders resolve empty** unless titles are injected via user_metadata — use static subjects instead.
- **The magic-link flow uses its own `magic_link` template type**, separate from `confirmation`. It needs dedicated `MAILER_SUBJECTS_MAGIC_LINK` / `MAILER_TEMPLATES_MAGIC_LINK` vars.
- **Keep OTP expiry long enough** (1h) for email flows.
- **Keep mailer templates/subjects brand-agnostic**; brand-specific values are injected via CI/CD overrides.

### Instance manifest + SSH-stdio agent (issue #120 / PR #123)
- **A forced-command key never "refuses" the requested command — it runs the agent and exits 0.** With `command="/usr/local/bin/supabase-agent"` in authorized_keys, `ssh <alias> whoami` ignores the `whoami` request and exits with the agent's code (0 on EOF). Testing "the key can't open a shell" by exit code is wrong, and interactive runs HANG because the forced agent reads the TTY stdin. Assert the *output* instead: response must be MCP JSON whose first byte is `{`. Same for port forwarding: `-L` refusal is not observable via the exit code; probe an actual direct-tcpip channel (connect to the local listen port during a live session and confirm no bytes reach the loopback target). See `scripts/verify-connection.sh` checks 5/6.
- **The end-of-run `debug` recap JSON-escapes the private key.** The recap prints the ed25519 key inside a `msg` array using literal `\n`, so naive copy-paste yields a corrupt single-line file (`Load key ...: error in libcrypto` → `Permission denied (publickey)`). Write the key with REAL line breaks and sanity-check it with `ssh-keygen -y -f <key>` before relying on it. The same JSON array separators can also leak trailing commas into the pasted `~/.ssh/config` (`unsupported option "yes,"`).
- **`install -m 0600 /dev/null <key>` silently leaves an EMPTY key file** if the paste fails — an empty file loads as `error in libcrypto`. Always verify the file is non-empty + parseable (`wc -l`, `ssh-keygen -y`).
- **Don't point users at `--tags instance-manifest-ssh-agent`** — `agent_access` tasks carry no tags, so that tag selector runs nothing. Either add the tags or drop the doc reference.
- **The manifest `supabase.version` is a cosmetic default** (`manifest/defaults/main.yml` pins `sb_db: postgres:17.6.1.136` as a display string). It can drift from the real image tag in the rendered `.env` (`IMAGE_TAG`); treat it as informational, never as the deployed version.

### Supabase template sync
- **Templates drift from upstream self-hosted releases** (e.g. postgres 15→17, analytics/vector moved into a separate `docker-compose.logs.yml` override, SAML routes, new healthchecks). Sync against the latest upstream compose on a regular basis.
- **Vector's router must match the deployed container names.** Upstream `vector.yml` matches `supabase-kong`, `supabase-auth`, etc. Our compose suffixes container names with `deploy_env`, so `vector-logs.yml.j2` templates those `.appname` values with the same `{{ '-' + deploy_env if deploy_env != 'changeit' else '' }}` expression — except `realtime-dev.supabase-realtime`, which never gets the suffix. If container-name generation changes, update the router too or log sources go dark.
- **Never bake project-specific changes into the default templates** (e.g. m3llm shared networks) — apply them via CI/CD overrides instead.

### Backup / pgBackRest
These problems were encountered and fixed while building the backup role (PR #119). Tested on a live self-hosted instance (sb.leadminer.io).

- **`LD_LIBRARY_PATH` in the container env poisons PostgreSQL.** The Supabase postgres image is Debian-based (glibc), but the pgbackrest binary is Alpine-based (musl). The binary needs musl shared libs (`libpq.so.5`, `libxml2.so.2`, `libssl.so.3`, etc.) that live in `pgbackrest-bin/` on the host. Setting `LD_LIBRARY_PATH=/usr/lib/pgbackrest-libs` in the db container's environment made **every** process (including PG backends) load those musl libs instead of the correct glibc ones. This crashed `SELECT FROM pg_settings` — the connection closed unexpectedly, the server entered recovery mode, and stanza-create/backup failed. **Fix:** A wrapper script at `/usr/bin/pgbackrest` sets `LD_LIBRARY_PATH` only for itself via `export` + `exec`, scoping the env var to the pgbackrest process only. The wrapper is bind-mounted into the container; the real binary + libs are at `/usr/lib/pgbackrest-bin/`.

- **Alpine binary can't run in a Debian container without its own libs.** The `woblerr/pgbackrest` image is Alpine. Simply mounting the binary without its shared libraries (`ld-musl-x86_64.so.1`, `libc.musl-x86_64.so.1`, `libpq.so.5`, `libxml2.so.2`, `libssl.so.3`, `libcrypto.so.3`, `liblz4.so.1`, `liblzma.so.5`, `libzstd.so.1`, `libz.so.1`, `libbz2.so.1`, `libssh2.so.1`) produces "not found" errors. **Fix:** The "Prepare backup paths" task creates a temporary container from the pgbackrest image, `docker cp`s the binary + all shared libs to `pgbackrest-bin/` on the host, then removes the temp container. The binary is owned by root with mode 755.

- **`pg1-user=postgres` lacks superuser.** The Supabase postgres image doesn't grant superuser to the `postgres` role. `pg_backup_start()` and `pg_backup_stop()` require superuser, so `pgbackrest backup` failed with "permission denied for function pg_backup_start". **Fix:** Changed to `pg1-user=supabase_admin` in `pgbackrest.conf.j2`. Only `supabase_admin` is superuser in the Supabase postgres image.

- **Lock directory permissions.** Manual `pgbackrest` calls as root (UID 0) created lock files under `/var/lib/pgbackrest/lock/` owned by root. When PostgreSQL then ran `archive_command` (as the postgres user, UID 100), pgbackrest couldn't acquire the lock ("Permission denied"). The lock dir was also owned by root, preventing postgres from creating new lock files. **Fix:** The "Prepare backup paths" task creates the lock dir and chowns it + all pgbackrest volumes to 100:101 (postgres:postgres in the container). The backup role also chowns these directories.

- **Missing archive spool directory.** `archive-async=y` in pgbackrest.conf causes `archive-push` to write WAL segments to a spool dir at `/var/spool/pgbackrest/archive/` before async upload. Without this directory, `archive-push` hangs or fails. **Fix:** Added `pgbackrest-spool` volume mount in the db service, and the "Prepare backup paths" task creates and chowns it to 100:101.

- **`pgbackrest.conf` unreadable by postgres.** The backup role rendered `pgbackrest.conf` owned by `deploy_user` (UID 1000) with mode `0640`. PostgreSQL runs `archive_command` as the postgres user (UID 100), which couldn't read the config. **Fix:** Changed ownership to 100:101 with mode `0644`.

- **`docker compose up -d` doesn't always pick up bind mount changes.** After modifying `docker-compose-supabase.yml` on disk, `docker compose up -d` reused the old container config instead of recreating it. **Fix:** `start-supabase.sh` runs `down && up` (not just `up -d`), which forces a full recreate with the updated mounts.

- **Docker creates source dirs when bind-mount sources don't exist.** If `pgbackrest.conf` or `pgbackrest-bin/` don't exist on the host when `docker compose up` runs, Docker creates them as directories. This shadows the bind mount source and breaks the mount. **Fix:** The "Prepare backup paths" task checks for and removes Docker-created dirs before creating the real files/dirs.

- **Separate pgbackrest container is unnecessary.** The original architecture ran pgbackrest in a sibling container sharing the db's PGDATA volume. This added complexity (network, health checks, volume sharing) and still required `docker exec supabase-db` for `archive_command`. Running pgbackrest directly inside `supabase-db` via `docker exec` is simpler, eliminates the extra container, and avoids volume-sharing edge cases. The backup compose now only contains minio + exporter.

- **MinIO must be up BEFORE the db's first boot.** Postgres boots with `archive_mode=on`, but MinIO (started by the backup role, which runs *after* the supabase role) was not yet available on a fresh deploy. The initdb temp server then couldn't shut down cleanly, leaving an unclean data dir and a ~6-minute crash-recovery loop on every boot — and `stanza-create` failed with `056` because it ran against a DB still in recovery. **Fix:** the supabase role renders the backup compose and starts MinIO (`docker compose up -d minio`) *before* the `Start Supabase` task, gated on `backup_enabled` **and** `backup_repo_type == 'minio'`. Never revert this ordering, and never widen the gate back to `backup_enabled` alone: the DB-boot-depends-on-local-MinIO invariant only exists for the `minio` repo. s3/posix repos have no local object store to bring up before Supabase (see **Weaknesses** below for the tradeoff).

- **MinIO tasks must only run for the `minio` repo, and the backup compose must only be brought up when it actually has services.** With `backup_repo_type: s3` (or `posix`) + `backup_monitoring_enabled: false`, the rendered `docker-compose-backup.yml.j2` has an empty `services:` mapping — running `docker compose up -d minio` (supabase role) or `docker compose up -d` (backup role) then fails with `services must be a mapping`. **Fix:** the supabase role's `Render backup compose for MinIO`/`Start MinIO` tasks are gated on `backup_repo_type == 'minio'`, and the backup role's `Bring up backup stack` is gated on `backup_repo_type == 'minio' or backup_monitoring_enabled`. When the repo isn't minio, no local object store is started before Supabase — archiving goes straight to the external s3/posix endpoint.

- **Single-file bind mounts pin the inode at container start; Ansible `template`'s atomic rename silently strands them.** The db container mounts `/home/<user>/backup/pgbackrest.conf → /etc/pgbackrest/pgbackrest.conf`. Docker binds single files to the inode that exists when the container starts; the backup role re-renders the config *after* `start-supabase.sh` created the container, so the container keeps reading the old inode. This stayed invisible while every render produced identical (minio) content — switching `backup_repo_type` to `s3` changed the content and the container kept archiving to `http://minio:9000` (`049 unable to get address for 'minio'`). **Fix:** (1) the supabase role renders `pgbackrest.conf` *before* `Start Supabase`, so the freshly recreated container binds the correct config inode at boot (boot-time `archive_command` reads it) — never rely on the backup role alone, or fresh installs boot with the empty placeholder; (2) the backup role renders it with `unsafe_writes: yes` (in-place write, same inode) so a running container always reads the current config if a later render ever differs. Only single-file bind mounts are affected; directories are safe (files inside are looked up by name).

- **`.State.Running == true` is NOT "DB is ready".** The old `Wait for supabase-db container` task checked only `docker inspect .State.Running`, which is true even while postgres is in crash-recovery (or during the long initdb/recovery window). pgbackrest commands then hit `056 unable to find primary cluster`. **Fix:** the backup role now polls `pg_isready` *and* `pg_is_in_recovery() == false` before running any pgbackrest command. Use this pattern for any task that execs pgbackrest into the db.

- **`stanza-create` races the MinIO bucket.** `minio-init` is a one-shot container (`restart: on-failure`) that creates the bucket and exits 0. If `stanza-create` runs before it finishes, pgbackrest fails with `039 NoSuchBucket` (or `103` after the repo exists but no stanza/info file). **Fix:** wait for `supabase-minio-init`'s `.State.ExitCode == 0` before `stanza-create`. Exited-0 is the canonical "bucket exists" signal; the container is *supposed* to stop after success, so check with `docker inspect` (it won't show in `docker ps`).

- **A stale repo must be RESET via MinIO recreation, never wiped under the running container.** When `stanza-create` fails with `028`/`103` after a data reset (fresh PGDATA on a repo bound to the old system-id), the role resets MinIO to a clean slate. **Fix:** the reset task must stop MinIO, `mv` the data dir aside (preserving it), `docker compose rm -f` the consumed `minio`/`minio-init` containers (so the one-shot re-runs `mc mb`), then `docker compose up -d minio minio-init` and wait for `supabase-minio-init` exit 0 before retrying the stanza. Doing `rm -rf volumes/minio/*` under the *running* MinIO destroys the bucket metadata (`.minio.sys/buckets/…`) and leaves you with `039 NoSuchBucket` on the retry — the bucket never comes back. Re-running the reset on an existing run is a no-op because the containers are already absent/recreated.

- **A broken/hung pgbackrest archive can wedge the whole stack.** The `archive_command` runs `pgbackrest --stanza=main archive-push %p` inside the db. If the binary, shared libs, config, or spool permissions are broken, the WAL archiver fails fast and retries (non-fatal at runtime) — but at *initdb time* a failing archive prevents the temp server from shutting down cleanly, which is the crash-recovery loop described above. When changing anything pgbackrest touches (binary, libs, wrapper, conf, spool/lock perms), always re-verify with a full clean deploy, not just `docker exec pgbackrest --version`.

- **Sustained backup failures are loud but non-fatal at runtime.** If MinIO/S3 goes down after boot, `archive_command` errors appear in the log and `pg_stat_archiver.failed_count` climbs, but postgres keeps serving — the WAL segments queue locally. This is the intended availability behavior; the risk is unbounded `pg_wal` growth until archiving resumes (monitor it). Do not "fix" a runtime archive failure by making `archive_command` always succeed — that silently drops WAL and breaks PITR.

- **S3 `repo1-s3-endpoint` is scheme://host[:port] ONLY — never include a URL path.** pgBackRest silently ignores any path in the endpoint, so an endpoint like `https://<project>.supabase.co/storage/v1/s3` (Supabase Cloud Storage) sends every request to the wrong URL and fails with `404`/`039`. Supabase Cloud Storage's S3 endpoint is **incompatible** even though it's a valid S3 URL. `setup.sh` now rejects path-bearing `s3_endpoint` values with a clear error. Also avoid bucket-qualified hostnames (e.g. `https://<bucket>.<region>.digitaloceanspaces.com`): with S3 path-style requests the bucket gets doubled (`NoSuchKey`). Use the plain provider endpoint (`https://s3.eu-west-1.amazonaws.com`, `https://fra1.digitaloceanspaces.com`). Found while testing DigitalOcean Spaces (stanza-create had failed with `045`/`039`/`404`).

### Weaknesses & Best Options (backup architecture)
Discussion captured from PR #119 review. **Current verdict: the present design (bind-mounted Alpine pgbackrest + libs + `LD_LIBRARY_PATH` wrapper inside `supabase-db`) is the accepted option** despite its known weaknesses, because it keeps the db image a pure upstream pull (no custom-image maintenance) while avoiding the security holes of docker-socket access.

Known weaknesses (accepted for now):
- **DB boot depends on backup infra.** Postgres won't start cleanly without MinIO reachable on a fresh boot (see the ordering pitfall above). If a backup step fails at deploy time, the whole stack fails to come up. This is a deliberate durability-first choice; runtime failures remain non-fatal.
- **musl-in-glibc fragility.** Shipping an Alpine (musl) binary + bundled musl libs into a Debian (glibc) image is held together by the `LD_LIBRARY_PATH` wrapper. Every lib addition or pgbackrest version bump risks re-poisoning PG or breaking the lib bundle (see the pitfalls above).
- **Host-owned bind mounts.** pgbackrest.conf, lock, log, and spool dirs must have exact UID/GID (100:101) and perms or archiving breaks.

Options considered and rejected/benchmarked:
- **Docker socket / DinD inside the db container:** rejected — grants the container root-equivalent host access. The binary hydration happens in an Ansible task on the host, never from inside the container.
- **Option A — custom `FROM supabase/postgres` image with pgbackrest compiled/installed (glibc):** cleanest long-term (removes wrapper + lib bundle + most permission bugs) but rejected for now — forces the repo to track every `supabase/postgres` release and rebuild, which conflicts with the "stay current with upstream supabase-db" requirement.
- **Option B — Debian-flavored pgbackrest binary, same mount model:** reduces fragility vs Alpine but still requires maintaining a compatible binary source.
- **Option C — host-side WAL shipper (separate process):** fully decouples DB from backup infra but adds a second moving part and duplicate-WAL logic.

Revisit decoupling only if deploy-time backup failures start blocking real deployments; for now keep the "MinIO up before Supabase" gate.

### MCP / Docker networking
- **Gateway source-NATs every host-originated connection, so `127.0.0.1`/`::1` can never match** — Docker source-NATs localhost, SSH tunnels, etc. to the Docker bridge gateway IP before it reaches the gateway, so Envoy/Kong sees the gateway, not the loopback address (see commit `b44b6a6`, which reverted the original MCP feature `0fe79d3`). In the Envoy `lds.template.yaml.j2` the `/mcp` allow list uses `direct_remote_ip` principals; in the Kong fallback it is an `ip-restriction` plugin — both must list the pinned gateway.
- **Pin the compose network subnet so the gateway is deterministic** — `docker-compose-supabase.yml.j2` declares `networks.default.ipam.config.subnet: 172.28.0.0/16`, making the gateway always `172.28.0.1`. `mcp_allowed_ips` must stay in sync with this gateway (default `[172.28.0.1]`). Without the pin, `docker compose down && up` re-issues whatever subnet is free, silently re-breaking the allow list.
- **The compose template now ships a top-level `networks:` block** — anything that blind-appends a second `networks:` key (e.g. the m3llm CI/CD `deploy-supabase-stack.yml`, which adds `shared-net`) produces a YAML duplicate-key error and breaks the deploy. Merge into the existing block instead (`grep -q '^networks:'` + `sed -i '/^networks:/a\...'`), never append a second block.
- **`verify-secure-mcp.py` only renders the template — it never runs the gateway.** A syntactically valid but wrong allow list (e.g. `127.0.0.1`) ships green. When touching MCP, cross-check `mcp_allowed_ips` against the pinned subnet gateway.

### Security-by-default
- **The MCP endpoint must never be publicly reachable**; prefer SSH-tunnel access over opening gateway routes.
- **Docs/README must default to the full secure-featured setup**, never the unprotected minimal one.

## Config Flow for New Variables
When adding a new variable that users should configure in `config.yml`:
1. Add the field to `config.example.yml` with a comment explaining usage
2. Add a `cfg_get` / `set_env_var` pair in `setup.sh` to read from `config.yml` and write to `env/supabase.yml`
3. If the variable is already a placeholder in `env/supabase.yml`, the `set_env_var` call (which uses `sed`) will replace it
4. If a new Ansible template variable is needed, add it as a placeholder to `env/supabase.yml`

See the **Ansible / Jinja2** and **setup.sh / config flow** pitfall subsections above — especially: never `set_env_var` a list, guard writes that can be empty, and avoid Ansible reserved words as variable names.

## Config Reading/Writing in setup.sh
- `cfg_get "path.to.key"` — reads from `config.yml` via embedded Python YAML parser
- `cfg_bool "path.to.key"` — returns 0 if `true`, 1 otherwise
- `set_env_var "key" "value"` — writes `key: value` to `env/supabase.yml` via `sed -i`

## Migration Script (`migrate.sh`)

Migrates a Supabase Cloud project into a self-hosted instance. Lives at `migrate.sh` with config at `env/migrate.yml` (copy of `env/migrate.example.yml`).

### Architecture
The phases run sequentially (non-resumable; a failure means starting over):
1. **DB dump+restore** — probes all schemas from source, dumps them in a single `pg_dump`, restores in a single `pg_restore`. Also captures user-schema FKs that reference Supabase-managed schemas and re-creates them **after** all data phases.
2. **Auth users** — data-only dump of `auth.users` + `auth.identities` (preserves UUIDs)
3. **Storage buckets** — data-only restore of `storage.buckets` (must precede the object copy)
4. **Storage objects** — **source S3 read via `rclone`, written to the target via its Storage REST API** (`POST /storage/v1/object/<bucket>/<path>` with the service-role JWT). The self-hosted S3 protocol is unreliable, so it is NOT used for the copy.
5. **Vault secrets** — re-encrypted on the target via `vault.create_secret`
6. **Edge functions** — code downloaded read-only from Cloud, deployed into `volumes/functions/`; secret NAMES staged in `.env.functions`
7. **Manual steps report** — prints checklist for post-migration tasks

### Key Difficulty: Cross-Schema Dependencies (Triggers)
**Problem:** The original per-schema loop (`for schema in ...; do pg_dump --schema=$s; pg_restore; done`) dumped/restored schemas one at a time. Triggers on `public` tables referencing `auth.*` functions failed because `auth` wasn't restored yet when `public` ran. The `--exit-on-error` flag caused those trigger failures to abort the schema restore, so triggers were silently lost.

**Fix:** Replace per-schema loop with a single `pg_dump` (all `--schema=` flags) followed by a single `pg_restore`. pg_dump resolves inter-schema dependency ordering internally, so triggers are created in the correct order. Removed `--exit-on-error` (harmless "already exists" DDL errors) and `--clean --if-exists` (target is fresh, cascade-drop not needed).

### Key Difficulty: Schema Discovery
**Problem:** The original script hardcoded a schema list (`SCHEMAS=(public auth storage ...)`). This missed custom schemas like `private`, `supabase_migrations`, and required manual updates when new schemas were added.

**Fix:** Probe `information_schema.schemata` dynamically, excluding only Postgres built-in schemas (`pg_catalog`, `information_schema`, `pg_toast`) and temporary schemas (`pg_temp_%`, `pg_toast_temp_%`). All remaining schemas (user + Supabase system) are dumped — Supabase system schema DDL produces harmless "already exists" errors, but their data (auth users, storage metadata, etc.) is migrated.

### Key Difficulty: Temporary Cloud Schemas
**Problem:** Supabase Cloud Postgres creates ephemeral `pg_temp_N` and `pg_toast_temp_N` schemas for connection pooling. These have reserved `pg_` prefix names that fail on restore with "unacceptable schema name".

**Fix:** Added `NOT LIKE 'pg\_temp\_%'` and `NOT LIKE 'pg\_toast\_temp\_%'` to the schema probe query.

### Key Requirement: supabase_admin User
The target `db_url` must use `supabase_admin` (superuser), not `postgres`. Only `supabase_admin` has the privileges to restore DDL in the `auth` and `storage` schemas. The `migrate.example.yml` now documents this requirement and provides the correct connection string format.

### Migration field-testing pitfalls (verified on a live instance)
- **`vault.create_secret(secret, name, description)` takes the SECRET first, then NAME.** Passing `(name, secret, desc)` silently stores the value in the `name` column and the name in `secret` — the vault then looks "migrated" but every secret name/value is swapped. Check the signature (`pg_proc` arg names `new_secret, new_name, new_description`), don't guess. Validate by reading back `vault.decrypted_secrets` (name must be the key name, decrypted_secret the value).
- **`vault.secrets.description` is NOT NULL on the target.** Passing `NULLIF('%s','')` (→ NULL for empty descriptions) makes `vault.create_secret` fail. The read already COALESCEs to `''`; pass `''::text` (never NULL).
- **Self-hosted storage-api's S3 protocol can reject EVERY valid SigV4 signature** (stub/standalone tenant: `TENANT_ID=stub`, `REGION=stub`, no `storage.tenants` table; returns 403 `SignatureDoesNotMatch` for correct creds, any region, via rclone AND curl `--aws-sigv4`). Do NOT build the object copy on it. Migrate objects via the **Storage REST API** with the service-role JWT — the REST API (JWT-auth) is independent of the S3 protocol and works: `GET /storage/v1/bucket`, `POST /storage/v1/object/<bucket>/<path>` (stream `rclone cat src:key | curl --data-binary @-`), `DELETE` to clean up test objects.
- **rclone `--progress=no` is invalid** (`strconv.ParseBool` fails) and older rclone (e.g. v1.60) **also rejects `--no-progress`** (`unknown flag`). Just omit the flag — progress is already off when stdout is not a TTY.
- **rclone `s3 provider "Supabase"` is not recognized by older rclone** (v1.60) and breaks the copy. Supabase storage is standard S3 — use plain `type = s3` + endpoint + region (works across versions).
- **Supabase CLI 2.x table output parsing.** `supabase functions list` / `secrets list` print an ASCII table with ANSI cursor codes (`\x1b[?25l`/`[?25h`) and MIXED delimiters (`│` box-drawing AND `|` pipe). Splitting on whitespace yields garbage names (`│`, `-----|-----`), which then produces junk `grep: Unmatched [...]` and phantom downloads. Strip ANSI, split on `|`, take SLUG=field 2 (`functions list`: `ID | NAME | SLUG | …`) and NAME=field 0 (`secrets list`: `NAME | DIGEST`), skip header/separator rows, and only keep `[A-Za-z0-9_-]+` tokens in the fallback single-column branch.
- **Cross-schema FKs referencing auth.* are silently dropped by Phase 1 restore.** `auth.users` data arrives in Phase 2, so `ALTER TABLE public.profiles ADD CONSTRAINT … REFERENCES auth.users(id)` fails during Phase 1 (empty table) and the constraint is lost. The fix captures those FK defs from the source before restore and re-`ADD`s them after all data phases. The probe must NOT use `confnamespace` (that's the FK's own schema); get the REFERENCED table's schema via a `pg_namespace`/`pg_class` join on `confrelid` or the query errors with `column "confnamespace" does not exist`.
- **`supabase functions download` extracts with ROOT ownership**, so a deploy_user can't `rm -rf` the temp dir and the `set -e` script aborts right after Phase 6. Guard the temp cleanup (`rm -rf … || true`).
- **`.env.functions` created root-owned by the supabase role** (the `copy` task runs as root), so the phase-7 append as `deploy_user` gets `Permission denied` and kills the run. Fix ownership at the source (role task owner `deploy_user`) AND make the append non-fatal (report note) when not writable.
