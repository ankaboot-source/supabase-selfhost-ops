# Advanced Deployment Guide

This document covers all optional roles and advanced configuration beyond the minimal Supabase setup. To use any of these features, uncomment the corresponding role in `playbook-supabase.yml` and configure the relevant variables in `env/supabase.yml`.

---

## 📑 Table of Contents

- [Enabling All Roles](#enabling-all-roles)
- [Caddy Reverse Proxy & SSO](#caddy-reverse-proxy--sso)
  - [Prerequisites](#caddy-prerequisites)
  - [SSO Provider Setup](#sso-provider-setup)
  - [Project Configuration](#caddy-project-configuration)
  - [Basic Auth](#basic-auth)
  - [IP Allow Listing](#ip-allow-listing)
- [Monitoring Stack](#monitoring-stack)
  - [Grafana Authentication](#grafana-authentication)
  - [Alerting & SMTP](#alerting--smtp)
- [LUKS Disk Encryption](#luks-disk-encryption)
- [Backups (pgBackRest)](#backups-pgbackrest)
- [Fail2ban](#fail2ban)
- [UFW Firewall](#ufw-firewall)
- [Security Hardening](#security-hardening)
- [Secure MCP Remote Access](#secure-mcp-remote-access)
- [Customizing Supabase](#customizing-supabase)
- [Full Environment Variable Reference](#full-environment-variable-reference)

---

## Enabling All Roles

The playbook ships with only `docker` and `supabase` enabled by default. To activate additional roles, edit `playbook-supabase.yml`:

```yaml
---
- hosts: localhost
  become: true
  roles:
   - docker
   - supabase

   # Uncomment any of the following lines to enable the feature:
   - ufw                     # Firewall — allow/deny rules per port
   - role: luks              # At-rest disk encryption (LUKS)
     when: supabase_encryption.enabled
   - caddy                   # Reverse proxy + automatic TLS + SSO
   - monitor                 # Grafana + Prometheus + Loki stack
   - fail2ban                # Brute-force protection for Postgres
   - backup                  # Automated S3-compatible backups
   - hardening               # OS hardening — SSH / kernel sysctl / filesystem
```

---

## Caddy Reverse Proxy & SSO

Caddy provides automatic TLS via Let's Encrypt, OAuth2 SSO, basic auth, and IP-based access control. It runs as a systemd service and reverse-proxies all incoming requests to the Supabase stack and other services.

### Caddy Prerequisites

- **3 subdomains** pointing to your server:
  - `auth.example.com` — OAuth2 authentication endpoint
  - `sb.example.com` — Supabase dashboard + API
  - `monitor.example.com` — Grafana dashboard (if monitoring is enabled)
- Ports **80** and **443** must be reachable for reverse proxy Let's Encrypt certificate issuance
- A registered OAuth2 application for SSO protection (GitHub, GitLab, or Discord)

### SSO Provider Setup

#### GitHub

1. Go to https://github.com/settings/developers → **OAuth Apps** → **New OAuth App**
2. Redirect URI: `https://<your-supabase-subdomain>/oauth2/github/authorization-code-callback`
3. Homepage URL: `https://<your-supabase-domain>/project/default`

In `env/supabase.yml`:

```yaml
SSO_PROVIDER: github
github_oauth_client_id: <your-client-id>
github_oauth_client_secret: <your-client-secret>
github_allow_list: "github.com/user1 github.com/user2"
```

#### GitLab

1. Go to https://gitlab.com/-/profile/applications → **Add new application**
2. Redirect URI: `https://<your-supabase-subdomain>/oauth2/gitlab/authorization-code-callback`
3. Enable `openid`, `profile`, and `email` scopes

```yaml
SSO_PROVIDER: gitlab
gitlab_domain: gitlab.com
gitlab_oauth_client_id: <your-client-id>
gitlab_oauth_client_secret: <your-client-secret>
gitlab_allow_list: "user1@example.com user2@example.com"
gitlab_group_filters:
  - my-group
  - ^a  # all groups starting with 'a'
```

#### Discord

1. Go to https://discord.com/developers/applications → **New Application**
2. Redirect URI: `https://<your-supabase-subdomain>/oauth2/discord/authorization-code-callback`

```yaml
SSO_PROVIDER: discord
discord_oauth_client_id: <your-client-id>
discord_oauth_client_secret: <your-client-secret>
admin_role_id: <your-admin-user-id>
discord_guild_id: <your-discord-server-id>
```

#### Generic OIDC (any OpenID Connect provider)

```yaml
SSO_PROVIDER: generic
oidc_realm: generic
oidc_driver: generic
oidc_client_id: <your-client-id>
oidc_client_secret: <your-client-secret>
base_auth_url: https://keycloak.example.com
metadata_url: https://keycloak.example.com/.well-known/openid-configuration
app_url: https://myapp.example.com
generic_allow_list: "user1@gmail.com user2@gmail.com"
```

#### Common SSO Variables (all providers)

```yaml
base_auth_domain: auth.example.com    # subdomain for OAuth2 auth endpoint
root_domain: example.com              # root domain for cookies (shared across subdomains)
jwt_shared_key: <openssl rand -base64 32>  # shared JWT signing key
```

### Caddy Project Configuration

Each project in the `projects` dictionary defines a subdomain with its own upstreams, access control, and logging. A project with no SSO and no basic auth:

```yaml
projects:
  my-app:
    log_file: my-app-access
    domain: "app.example.com"
    upstreams:
      - targets: ["localhost:3000"]
        paths: [""]
```

A project with SSO protection:

```yaml
projects:
  supabase:
    log_file: supabase-access
    domain: "sb.example.com"
    oidc_enabled: true
    upstreams:
      # Dashboard (SSO-protected)
      - targets: ["localhost:3001"]
        paths: [""]
        oidc: true
      # API routes (no SSO — Kong handles auth)
      - targets: ["localhost:8000"]
        paths:
          - /rest/v1/*
          - /auth/v1/*
          - /realtime/v1/*
          - /storage/v1/*
          - /functions/v1/*
        oidc: false
```

Multiple projects can be added to the same Caddy instance by adding more entries to the `projects` dictionary.

### Basic Auth

You can protect specific paths with HTTP basic auth:

```yaml
projects:
  supabase:
    domain: "sb.example.com"
    upstreams:
      - targets: ["localhost:3001"]
        paths: [""]
        basicauth:
          - path: /project/default
            username: admin
            # Generate with: caddy hash-password
            password: $2a$10$...
```

### IP Allow Listing

Restrict access to specific IPs or CIDR ranges:

```yaml
projects:
  supabase:
    domain: "sb.example.com"
    allowed_ips:
      - 123.123.123.123
      - 111.111.111.111
    upstreams:
      - targets: ["localhost:3001"]
        paths: [""]
```

When `allowed_ips` is set, all other IPs receive a 403 response.

---

## Monitoring Stack

Uncomment `- monitor` in the playbook to deploy:

| Service | Port | Purpose |
|---------|------|---------|
| Grafana | 3002 | Dashboards & alerting |
| Prometheus | 9090 | Metrics collection (7-day retention) |
| Loki | 3100 | Log aggregation |
| Promtail | — | Log shipping from Docker/journald |
| Node Exporter | 9100 | Host metrics |
| cAdvisor | 7070 | Container metrics |
| Postgres Exporter | — | Database metrics |

### Grafana Authentication

Three modes are available in `env/supabase.yml`:

**Anonymous access** (no login required):

```yaml
GRAFANA_AUTH_ANONYMOUS_ENABLED: true
GRAFANA_AUTH_ANONYMOUS_ORG_ROLE: Admin
```

**Basic auth** (username/password):

```yaml
GRAFANA_AUTH_ANONYMOUS_ENABLED: false
GRAFANA_AUTH_BASIC_ENABLED: true
GRAFANA_ADMIN_USER: admin
GRAFANA_ADMIN_PASSWORD: your_strong_password
```

**GitHub OAuth**:

```yaml
GRAFANA_AUTH_ANONYMOUS_ENABLED: false
GRAFANA_AUTH_BASIC_ENABLED: false
GRAFANA_GITHUB_AUTH_ENABLED: true
GRAFANA_GITHUB_CLIENT_ID: <your-client-id>
GRAFANA_GITHUB_CLIENT_SECRET: <your-client-secret>
GRAFANA_GITHUB_ALLOWED_ORG: ["your-org"]
GRAFANA_GITHUB_ROLE: "'Admin'"
```

### Alerting & SMTP

Configure email alerts in Grafana:

```yaml
GRAFANA_SERVER_ROOT_URL: https://monitor.example.com
GRAFANA_ALERT_HOST: monitor.example.com
GRAFANA_SMTP_PASSWORD: your_password
GRAFANA_SMTP_HOST: mail.example.com
GRAFANA_SMTP_USER: user@example.com
GRAFANA_SMTP_SENDER: user@example.com
```

The monitoring stack listens on `127.0.0.1:3002` (Grafana), `127.0.0.1:9090` (Prometheus), and `127.0.0.1:3100` (Loki). Expose Grafana through the Caddy proxy by adding a `monitor` project entry.

---

## Dashboard Logging (Log Drain)

The Studio dashboard's log pane is powered by **Logflare** (`analytics`) and **Vector** (the log pipeline). Since the upstream self-hosted release, these run from a separate compose override — `docker-compose-logs.yml` — layered on top of `docker-compose-supabase.yml`.

- **Enabled by default** (`required.enable_logging: true`). Set it to `false` in `config.yml` and re-run `setup.sh` to disable — the override is then excluded from `up` and orphaned `analytics`/`vector` containers are torn down on the next start.
- Vector reads the Docker socket (read-only) and routes container logs to Logflare. Neither container publishes a host port; Studio and Vector reach `analytics` over the internal Docker network.
- Both containers have healthchecks and are wired through to the `start-supabase.sh` wait loop, so `docker compose ps` shows the full stack.

```yaml
required:
  enable_logging: true   # set false to disable the Studio log drain
```

You can swap the default images via `sb_logflare_version` / `sb_vector_version` in `roles/supabase/defaults/main.yml`.

---

## LUKS Disk Encryption

Encrypts a separate data volume for Supabase Postgres data at rest with automatic unlock on boot.

```yaml
supabase_encryption:
  enabled: true

luks_device: /dev/disk/by-id/YOUR_VOLUME_NAME
luks_name: encrypted_data
luks_mount_point: /data
luks_filesystem: ext4
luks_key_file: /root/.luks_keyfile
mount_options: "defaults,noatime,nofail"
```

**Safety:** The role refuses to encrypt the root device and skips if the volume is already mounted. When encryption is enabled, Postgres data is stored at `{{ luks_mount_point }}/supabase/data`.

The initramfs is automatically updated to support keyfile-based unlock on boot.

---

## Backups (pgBackRest)

Automated backups + continuous WAL archiving + point-in-time recovery (PITR) via [pgBackRest](https://pgbackrest.org/), running **inside** the `supabase-db` container (no separate pgbackrest container, and the upstream `supabase/postgres` image is not forked).

### How it works

- **pgBackRest** runs inside `supabase-db`. The Alpine pgbackrest binary + its shared libraries are extracted to a host dir at deploy time and bind-mounted read-only; a wrapper script scopes `LD_LIBRARY_PATH` to the pgbackrest process only. All pgbackrest commands (`stanza-create`, `backup`, `verify`, `expire`) execute via `docker exec supabase-db`.
- **Boot ordering (important)**: when `backup` is enabled, the install brings up the **RustFS** container *before* starting Supabase, because Postgres boots with `archive_mode=on` and needs the archive target reachable so initdb shuts down cleanly. RustFS must be up before the db's first boot on a fresh deploy.
- **Continuous WAL archiving**: Postgres `archive_command` runs `pgbackrest archive-push %p` directly in the db container. pgBackRest uses `archive-async=y` with its own internal spool for queueing and retry. `rustfs-init` fixes the volume ownership (RustFS runs as non-root UID 10001), creates the bucket, and exits 0; the playbook waits for it before `stanza-create`.
- **Scheduled backups**: full (weekly) + differential (daily) via cron.
- **PITR**: restore to any point in time covered by the WAL archive.
- **Verification**: daily `pgbackrest verify` (cheap integrity check); optional restore drill (full restore into throwaway volume).
- **Monitoring**: Prometheus metrics + Grafana panel + always-on alerts.

### Repository types

| `backup_repo_type` | What it is | Encryption | Warning |
|---|---|---|---|
| `rustfs` (default) | Local RustFS container on the same host | off | **No off-box protection** — if the server dies, backups die with it. |
| `s3` | External S3-compatible (AWS S3, R2, B2, Wasabi, DigitalOcean Spaces) | **on** (forced) | Off-box protection. |
| `posix` | Local filesystem path | off | Same warning as `rustfs`. |

> **S3 endpoints must be host-only (no URL path).** pgBackRest's `repo1-s3-endpoint`
> accepts only `scheme://host[:port]`. Any path in the endpoint is **silently
> dropped** — e.g. Supabase Cloud Storage's S3 endpoint
> `https://<project>.supabase.co/storage/v1/s3` is **incompatible**: requests go
> to the wrong URL and fail with `404`. `setup.sh` rejects path-bearing endpoints
> before deploying. Use a plain endpoint such as
> `https://s3.eu-west-1.amazonaws.com` (AWS) or `https://<region>.digitaloceanspaces.com`
> (DO Spaces — do **not** use the bucket-qualified `https://<bucket>.<region>.digitaloceanspaces.com` form).

### Minimal config (hobby)

```yaml
components:
  backup: true
advanced:
  backup:
    repo_type: rustfs    # local RustFS (default)
```

### Production hardening (5 var overrides)

```yaml
advanced:
  backup:
    repo_type: s3
    s3_endpoint: https://s3.eu-west-1.amazonaws.com
    s3_bucket: supabase-backups
    s3_access_key: <key>
    s3_secret_key: <secret>
    encryption: true       # forced on for s3
    creds_source: vault   # Ansible Vault
    restore_drill: true   # weekly restore verification
    retention_full: 7
```

### Retention

| Variable | Default | Hardened |
|---|---|---|
| `retention_full` | 3 | 7 |
| `retention_diff` | 3 | 3 |
| `retention_archive` | 3 | 7 |

Effective PITR window ≈ `min(retention_archive, retention_full)` full-backup cycles: ≈3 days default, ≈7 days hardened.

### Encryption

- **Local repo** (`rustfs`/`posix`): encryption is **off** — it's your box, and handing a beginner a key they'll lose is worse.
- **External repo** (`s3`): encryption is **forced on** (`aes-256-cbc`). A passphrase is generated by `setup.sh` and printed. **Store it off the server** (password manager). If lost, the backup repo is unrecoverable.

### Credentials

| `creds_source` | Behavior | Warning |
|---|---|---|
| `env` (default) | S3/RustFS keys in plaintext `.env` file | Warned — use `vault` for production. |
| `vault` | Ansible Vault variables | The hardened path. |

### Restore during an incident (< 5 min)

```bash
# 1. Stop the app (prevent writes during restore)
# 2. Restore to a specific point in time (UTC recommended)
ansible-playbook restore.yml -e "target_time='2026-08-01 12:30:00+00'"
# 3. Type 'yes' to confirm the destructive operation
# 4. Wait for the playbook to complete (it takes a pre-restore backup, stops db, restores, restarts)
# 5. Verify Supabase services are healthy (Auth, Storage, PostgREST)
```

The restore playbook:
1. **Refuses** without `target_time` (no accidental "restore to now").
2. **Requires explicit confirmation** (prints target + current time + overwrite warning).
3. **Takes a fresh full backup** of current state before overwriting (last-chance snapshot).
4. Stops `supabase-db`, runs `pgbackrest --type=time --target=... --target-action=promote --delta restore`, restarts db.
5. Waits for Supabase services to respond healthy.

### Non-destructive verification

```bash
# Restore into a throwaway volume + start read-only Postgres + healthchecks
# Never touches prod. Resource cost: ~1x DB size + memory for 2nd Postgres.
ansible-playbook restore-verify.yml
```

### On-demand backup

```bash
ansible-playbook backup.yml
```

### pgsodium key backup

The `db-config` Docker named volume holds `/etc/postgresql-custom/pgsodium_root.key` (32-byte root key). Without it, every `vault.secret` and pgsodium-encrypted column is unrecoverable. The role backs this up automatically alongside the database. **Store the key off the server** — if lost, encrypted data is gone.

### Storage volume backup

If Storage uses the `file` backend, the role tars `./volumes/storage/` into the backup repo. If Storage is on external S3, the volume backup is skipped (the bytes already live off-box).

> **Note:** Storage and DB backups are not point-in-time consistent. `storage.objects` rows (in PG) and the bytes (in the volume) are backed up at different times — a restore may reference missing files or leave orphans.

### Monitoring

- **Prometheus**: `pgbackrest_exporter` on `127.0.0.1:9854`, scraped by the existing Prometheus.
- **Grafana**: "Backup (pgBackRest)" dashboard with stanza status, backup age, WAL archive lag, backup size.
- **Alerts** (always on, regardless of config):
  - Stanza status > 0 (backup/archive problem)
  - No full backup in > 25 hours (missed/failed scheduled run)
  - WAL archive lag rising (archive_command failing — pg_wal will fill the disk)
  - Last backup errored
  - PGDATA filesystem > 85% full
  - Verify failure
  - Exporter down

### PG major version upgrades

After a PG major upgrade (e.g. 15→17), you must run `pgbackrest stanza-upgrade`. **Pre-upgrade backups are not restorable into the new cluster.** The upgrade playbook (separate issue) must take a fresh full backup and re-baseline the stanza immediately post-upgrade.

---

## Fail2ban

Protects PostgreSQL from brute-force attacks by monitoring authentication failures.

Configured via templates:
- `/etc/fail2ban/jail.d/postgresql.conf` — jail definition
- `/etc/fail2ban/filter.d/postgresql.conf` — log pattern matching
- `/etc/fail2ban/action.d/postgresql.conf` — ban action

By default the role uses the system's `fail2ban` package and restarts the service after configuration.

---

## UFW Firewall

Configures fine-grained allow/deny rules. The script always allows SSH (port 22) and resets all previous rules first.

```yaml
firewall_allow:
  - port: 80
  - port: 443
  - port: 5432
    ip: 111.111.111.111
  - port: 5432
    ip: 123.123.123.123
    cidr: 32

firewall_deny:
  - port: 3000
  - port: 3001
  - port: 8000
  - port: 9100
```

**Rule syntax:**

| Fields | Effect |
|--------|--------|
| `port: 80` | Allow/deny from any IP |
| `port: 5432` + `ip: 1.2.3.4` | Allow/deny from specific IP |
| `port: 5432` + `ip: 1.2.3.0` + `cidr: 24` | Allow/deny from CIDR range |

---

## Security Hardening

Applies best-practice host OS hardening for **Debian and Ubuntu**. Enable it with:

```yaml
components:
  hardening: true
```

Every subset is **off until explicitly enabled** under `advanced.hardening` — turning the component on alone changes nothing. Each item is annotated with what it applies and the threat it mitigates. The role fails fast on any non-Debian-family distro; Debian and Ubuntu use identical settings, so no per-distro config is needed.

### SSH (`advanced.hardening.ssh`)

Written as a drop-in at `/etc/ssh/sshd_config.d/hardening.conf`, which merges with the stock config (never rewrites it). Before the daemon restarts, the role runs `sshd -t` so a malformed value can never lock you out.

| Setting | Effect / mitigates |
|---------|--------------------|
| `permit_root_login: false` | Forbid direct root SSH login — root can't be brute-forced (use your sudo-capable `deploy_user`). |
| `password_auth: false` → **OPT-IN** | Force key-only login. Blocks password brute-force and credential-stuffing. Keep `false` until a key is confirmed. |
| `max_auth_tries` | Cap auth attempts per connection — stops unlimited guessing in one session. |
| `login_grace_time` | Fail the connection if auth takes too long — blocks slow, half-open auth-session exhaustion. |
| `allow_tcp_forwarding: false` → OPT-IN | Block TCP port forwarding — denies pivoting/tunnelling out of a compromised session. **Does not** break the MCP client-side `-L` tunnels. |
| `x11_forwarding: false` → OPT-IN | Block X11 forwarding — display/content hijack and remote GUI keylogging. |
| `allow_agent_forwarding: false` → OPT-IN | Block SSH-agent forwarding — SSH private-key theft via a forwarded agent. |
| `client_alive_interval` / `client_alive_count_max` | Drop dead/abandoned sessions — no zombie connections holding resources. |
| `use_dns: false` | Skip reverse-DNS on connect — prevents reverse-DNS stalls and speeds login. |

### Kernel / network (`advanced.hardening.sysctl`)

Written to `/etc/sysctl.d/99-hardening.conf`. **Only Docker-safe keys are set:** `net.ipv4.ip_forward` and IPv6 forwarding are deliberately never touched (the Supabase stack and its pinned `172.28.0.0/16` subnet depend on them).

| Toggle | sysctl key | Effect / mitigates |
|--------|------------|--------------------|
| `tcp_syncookies` | `net.ipv4.tcp_syncookies = 1` | SYN-flood (connection-exhaustion) DoS mitigation. |
| `rp_filter` | `net.ipv4.conf.*.rp_filter = 1` | Reverse-path filtering — drops IP spoofing. |
| `log_martians` | `net.ipv4.conf.*.log_martians = 1` | Logs bogus source addresses for spoof visibility. |
| `drop_source_route` | `accept_source_route = 0` | Refuses source-routed packets (route-poisoning / MITM). |
| `drop_redirects` | `accept_redirects = 0`, `send_redirects = 0` | Ignores/never emits ICMP redirects (route MITM). |
| `ignore_broadcast_pings` | `icmp_echo_ignore_broadcasts = 1` | Not a smurf-amplification DoS reflector. |
| `rfc1337` | `tcp_rfc1337 = 1` | TIME_WAIT assassination (connection-reset tricks). |
| `aslr_full` | `randomize_va_space = 2` | Full ASLR — RCE exploitation mitigation. |
| `disable_suid_dumps` | `fs.suid_dumpable = 0` | No core dumps from setuid programs (no privileged-memory leaks). |
| `core_uses_pid` | `kernel.core_uses_pid = 1` | Names core dumps by crashing PID. |

### Filesystem (`advanced.hardening.filesystem`)

Currently hardens **`/dev/shm`** only (`noexec,nosuid,nodev` via `/etc/fstab`). This is safe for the stack: Supabase and monitor containers use their **own** in-container `/dev/shm`, never the host mount. `/tmp` and `/var/tmp` are **intentionally excluded** — apt/dpkg and Ansible execute temporary scripts there, and `noexec` on them could break the upgrade/deploy path.

> **Why drop auto-updates?** The inspiro script's `unattended-upgrades` was intentionally left out: it can require a reboot and interfere with the long-running Supabase/monitor services, defeating the "don't disrupt the running stack" goal of this role.

---

## Secure MCP Remote Access

The Supabase MCP (Model Context Protocol) server exposes the Studio API at
`/mcp` through the Kong gateway. By default this endpoint is **restricted to
host-originated traffic** so it is never reachable from the public Internet.
Authorized remote clients connect through an SSH tunnel, which reuses the
existing SSH access (port 22) and requires no new public ports, subdomains, or
services.

> **Studio MCP vs. the hardened agent MCP.** This section covers the *built-in
> Studio* MCP at `/mcp`. It is **not read-only**: the endpoint runs through
> Studio's `postgres` superuser connection, and the self-hosted Studio MCP has
> **no read-only mode** (that's a Cloud/CLI feature only). Restricting it to the
> SSH tunnel (the `ip-restriction` allow list below) only limits *who can reach
> it* — an agent connected to it can **write** (`INSERT`/`UPDATE`/`DELETE`/DDL).
> For a DB-enforced, genuinely read-only agent endpoint, use the `agent_access`
> MCP documented in [docs/connect-your-agent.md](connect-your-agent.md): it
> connects as a dedicated `agent_reader` role whose `SELECT`-only grants and
> read-only transactions are enforced by Postgres itself.

### How it works

```
MCP client (local) ──SSH tunnel (port 22)──> server ──> Kong :8000/mcp ──> Studio :3000/api/mcp
```

- **Kong** applies an `ip-restriction` plugin to `/mcp`. Because Docker
  source-NATs host connections to the bridge gateway, the allow list defaults to
  the compose network gateway `172.28.0.1` (the subnet is pinned to
  `172.28.0.0/16` in `docker-compose-supabase.yml.j2` so the gateway is
  deterministic). This is configurable via `mcp_allowed_ips`.
- **UFW** denies port `8000` (Kong) from external IPs by default.
- **Caddy** never reverse-proxies `/mcp` — there is no public subdomain for it.
- The direct `/api/mcp` path stays fully blocked (`request-termination` 403).

### Connecting an authorized client

From your workstation, open an SSH local port forward to Kong:

```bash
ssh -L 8080:localhost:8000 deploy_user@sb.example.com -N
```

- `-L 8080:localhost:8000` forwards your local port `8080` to the server's
  `localhost:8000` (Kong).
- `-N` keeps the SSH session open without running a remote shell.

Then point your MCP client at:

```
http://localhost:8080/mcp
```

Close the tunnel with `Ctrl-C` (or by exiting the SSH session) when finished.

### Configuration

The allow list is controlled by `mcp_allowed_ips` in `env/supabase.yml`:

```yaml
# Default: Docker bridge gateway (host-originated traffic, incl. SSH tunnels).
# Must match the pinned compose subnet gateway in docker-compose-supabase.yml.j2.
mcp_allowed_ips:
  - 172.28.0.1
```

To allow a private VPN subnet (e.g. WireGuard) in addition:

```yaml
mcp_allowed_ips:
  - 172.28.0.1
  - 10.0.0.0/24
```

Set `mcp_allowed_ips: []` to fully disable `/mcp`.

> **Warning:** Adding a public IP or `0.0.0.0/0` re-exposes the MCP endpoint to
> the Internet and defeats the purpose of this security control. Keep the allow
> list limited to private ranges.

### Why SSH tunneling?

| Approach | Public exposure | Extra services | Auth model |
|----------|----------------|----------------|------------|
| **SSH tunnel (default)** | None | None | SSH keys (existing) |
| VPN (WireGuard/Tailscale) | None | VPN daemon + config | VPN keys |
| Caddy + OAuth2 SSO | Public subdomain | Caddy + OIDC provider | Interactive login |
| Public Kong + IP allow list | Public port | None | IP only (spoofable) |

SSH tunneling is the default because it adds no new attack surface, reuses the
existing SSH trust boundary, and requires no additional infrastructure.

---

## Customizing Supabase

### Disabling Unused Services

To disable a Supabase service (e.g., Edge Functions or imgproxy), comment out its container definition in `roles/supabase/templates/docker-compose-supabase.yml.j2`.

### Overriding Container Versions

Container image tags are defined in `roles/supabase/defaults/main.yml`:

```yaml
sb_studio_version: supabase/studio:2026.06.03-sha-0bca601
sb_kong_version: kong/kong:3.9.1
sb_gotrue_version: supabase/gotrue:v2.189.0
sb_rest_version: postgrest/postgrest:v14.12
sb_realtime_version: supabase/realtime:v2.102.3
sb_storage_version: supabase/storage-api:v1.60.4
sb_imgproxy_version: darthsim/imgproxy:v3.30.1
sb_meta_version: supabase/postgres-meta:v0.96.6
sb_functions_version: supabase/edge-runtime:v1.74.0
sb_db_version: supabase/postgres:17.6.1.136
sb_supavisor_version: supabase/supavisor:2.9.5
```

Override any of these in `env/supabase.yml` to pin different versions.

### Changing Prometheus Retention

Edit `roles/monitor/templates/docker-compose-monitor.yml.j2` and modify the `--storage.tsdb.retention.time` flag (default: `7d`).

---

## Full Environment Variable Reference

All values go in `env/supabase.yml`.

### COMMON

| Variable | Required | Description |
|----------|----------|-------------|
| `deploy_user` | **Yes** | System user (SSH user) for the deployment |
| `deploy_env` | No | Container name suffix (e.g. `prod`, `qa`) |
| `docker_users` | **Yes** | Users with Docker access (same as `deploy_user`) |
| `docker_restart` | No | Whether to restart Docker (default: `yes`) |

### SUPABASE

| Variable | Required | Description |
|----------|----------|-------------|
| `postgres_db_pwd` | **Yes** | PostgreSQL password |
| `sb_jwt_secret` | **Yes** | Legacy symmetric HS256 JWT secret |
| `sb_anon_key` | **Yes** | Legacy anon API key (HS256-signed JWT) |
| `sb_service_role_key` | **Yes** | Legacy service_role API key |
| `sb_publishable_key` | No | Opaque API key for anon role |
| `sb_secret_key` | No | Opaque API key for service_role |
| `sb_jwt_keys` | No | JSON array of signing JWKs |
| `sb_jwt_jwks` | No | JWKS for token verification |
| `secret_key_base` | **Yes** | `openssl rand -base64 48` |
| `vault_enc_key` | **Yes** | `openssl rand -hex 16` |
| `pg_meta_crypto_key` | **Yes** | `openssl rand -base64 24` |
| `logflare_public_access_token` | **Yes** | `openssl rand -base64 24` |
| `logflare_private_access_token` | **Yes** | `openssl rand -base64 24` |
| `s3_protocol_access_key_id` | **Yes** | `openssl rand -hex 16` |
| `s3_protocol_access_key_secret` | **Yes** | `openssl rand -hex 32` |
| `pooler_tenant_id` | No | Unique Supavisor tenant identifier |
| `site_url` | **Yes** | Public-facing site URL |
| `api_external_url` | **Yes** | Public-facing API URL (used by Studio) |
| `enable_email_signup` | No | Allow email signups (default: `true`) |
| `enable_email_autoconfirm` | No | Auto-confirm emails (default: `false`) |
| `smtp_admin_email` | **Yes** | SMTP sender email |
| `smtp_host` | **Yes** | SMTP server host |
| `smtp_port` | No | SMTP port (default: `587`) |
| `smtp_user` | **Yes** | SMTP username |
| `smtp_password` | **Yes** | SMTP password |
| `smtp_sender_name` | No | SMTP sender name |
| `google_enabled` | No | Enable Google social login |
| `google_client_id` | No | Google OAuth client ID |
| `google_secret` | No | Google OAuth client secret |
| `github_enabled` | No | Enable GitHub social login |
| `github_client_id` | No | GitHub OAuth client ID |
| `github_secret` | No | GitHub OAuth client secret |
| `azure_enabled` | No | Enable Azure social login |
| `azure_client_id` | No | Azure OAuth client ID |
| `azure_secret` | No | Azure OAuth client secret |
| `openai_api_key` | No | OpenAI API key |
| `supabase_path` | No | Relative path for Supabase docker dir |
| `kong_conf_path` | No | Relative path for Kong config |
| `log_drain_enabled` | No | Whether the Studio log drain (Logflare + Vector) starts. Set by `setup.sh` from `required.enable_logging` (default: `true`) |
| `mcp_allowed_ips` | No | IPs allowed to reach `/mcp` via Kong (default: `[172.28.0.1]` — the Docker bridge gateway, since Docker source-NATs host connections; set `[]` to disable; see [Secure MCP Remote Access](#secure-mcp-remote-access)) |

### CADDY

| Variable | Required | Description |
|----------|----------|-------------|
| `SSO_PROVIDER` | **Yes\*** | `generic`, `github`, `gitlab`, or `discord` |
| `base_auth_domain` | **Yes\*** | Auth endpoint subdomain |
| `root_domain` | **Yes\*** | Root domain for SSO cookies |
| `jwt_shared_key` | **Yes\*** | `openssl rand -base64 32` |
| `projects` | **Yes** | Dictionary of project → upstream mappings |

\* Required only when the OIDC protection is enabled.

See provider-specific sections above for per-provider variables.

### MONITOR

| Variable | Required | Description |
|----------|----------|-------------|
| `monitor_path` | No | Directory name for monitor files (default: `monitor`) |
| `GRAFANA_SERVER_ROOT_URL` | **Yes** | Public Grafana URL |
| `GRAFANA_ALERT_HOST` | **Yes** | Grafana alert hostname |
| `GRAFANA_AUTH_ANONYMOUS_ENABLED` | No | Enable anonymous access |
| `GRAFANA_AUTH_ANONYMOUS_ORG_ROLE` | No | Anonymous role (`Admin`/`Viewer`) |
| `GRAFANA_AUTH_BASIC_ENABLED` | No | Enable username/password login |
| `GRAFANA_ADMIN_USER` | No | Basic auth admin username |
| `GRAFANA_ADMIN_PASSWORD` | No | Basic auth admin password |
| `GRAFANA_GITHUB_AUTH_ENABLED` | No | Enable GitHub OAuth for Grafana |
| `GRAFANA_GITHUB_CLIENT_ID` | No | GitHub OAuth client ID |
| `GRAFANA_GITHUB_CLIENT_SECRET` | No | GitHub OAuth client secret |
| `GRAFANA_GITHUB_ALLOWED_ORG` | No | Allowed GitHub orgs list |
| `GRAFANA_GITHUB_ROLE` | No | Role mapping for GitHub users |
| `GRAFANA_SMTP_PASSWORD` | No | SMTP password for alert emails |
| `GRAFANA_SMTP_HOST` | No | SMTP server for alerts |
| `GRAFANA_SMTP_USER` | No | SMTP user for alerts |
| `GRAFANA_SMTP_SENDER` | No | SMTP sender for alerts |

### FAIL2BAN

| Variable | Required | Description |
|----------|----------|-------------|
| `fail2ban_packages` | No | List of packages (default: `[fail2ban]`) |
| `fail2ban_service` | No | Service name (default: `fail2ban`) |

### S3 BACKUP

| Variable | Required | Description |
|----------|----------|-------------|
| `exclude_tables` | No | Comma-separated tables to exclude from data dump |
| `backup_cron_hour` | No | Cron hour (default: `2`) |
| `backup_cron_minute` | No | Cron minute (default: `0`) |
| `s3_remote_name` | **Yes** | Rclone remote name (e.g. `r2`, `gcs`) |
| `s3_provider` | **Yes** | S3 provider (e.g. `Cloudflare`, `GCS`) |
| `s3_access_key` | **Yes** | S3 access key |
| `s3_secret_key` | **Yes** | S3 secret key |
| `s3_endpoint` | **Yes** | S3 endpoint URL |
| `s3_bucket_name` | **Yes** | S3 bucket name |

### FIREWALL (UFW)

| Variable | Required | Description |
|----------|----------|-------------|
| `firewall_allow` | No | List of allow rules (port + optional ip/cidr) |
| `firewall_deny` | No | List of deny rules (port + optional ip/cidr) |

### LUKS

| Variable | Required | Description |
|----------|----------|-------------|
| `luks_device` | **Yes\*** | Device path (e.g. `/dev/disk/by-id/...`) |
| `luks_name` | **Yes\*** | LUKS mapping name (default: `encrypted_data`) |
| `luks_mount_point` | **Yes\*** | Mount point (default: `/data`) |
| `luks_filesystem` | **Yes\*** | Filesystem type (default: `ext4`) |
| `luks_key_file` | **Yes\*** | Key file path (default: `/root/.luks_keyfile`) |
| `mount_options` | **Yes\*** | Mount options |
| `supabase_data_path` | **Yes\*** | Postgres data path (auto-set based on encryption) |

\* Required only when encryption is enabled.
