# Supabase Self-Host Ops

**The AI-ready Supabase distribution for production self-hosting.** Point your coding
agent at your own server and build — with the developer experience you get from
Supabase Cloud, on a stack that ships with SSO, point-in-time recovery, monitoring
and disk encryption. Runs on any Debian-based distribution, including Ubuntu — plus Arch.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## Why this exists

Building on Supabase Cloud works right up to the bill, the data-residency question,
or the day the database has to live somewhere you control. Self-hosting answers all
three — and throws away everything that made the workflow work in the first place.
The official path, `docker compose up` on the sample stack, leaves you with a Studio
dashboard open to the internet, no endpoint your agent can talk to, no way for a tool
to discover what was even deployed, and nothing to restore from the day the database
breaks. So you hand-feed your agent connection strings, or hand it a `service_role`
key and hope.

This distribution closes that gap. One command deploys the stack, applies hardened
defaults, backs it up continuously, watches it — and exposes it to your coding agent
through a read-only channel carried over SSH, with tools that are not given secret
values to return.

It does that by composing things other people built well — Supabase, Caddy,
pgBackRest, Postgres, LUKS — rather than by inventing any of it. The work here is the
defaults and the wiring. What that does and does not buy you is written down in
[SECURITY.md](SECURITY.md), including the parts that are on you.

| What you worry about | Supabase Cloud | `docker compose` self-host | This project |
|---|---|---|---|
| Building with an AI agent | ✅ Hosted MCP | ❌ Hand-fed credentials | ✅ Read-only MCP over SSH, no public port |
| Losing the database | Paid PITR add-on | ❌ Nothing | ✅ pgBackRest: continuous WAL + PITR |
| Dashboard exposed | ✅ Managed auth | ❌ Open to the internet | ✅ OIDC + basic auth + IP allow-list |
| Not seeing the outage | Basic reports | ❌ Nothing | ✅ Grafana + Prometheus + Loki |
| Encryption at rest | ✅ Yes | ❌ No | ✅ LUKS on a dedicated volume |
| Getting out of the Cloud | — | Manual, days of work | ✅ `migrate.sh`, one command |
| Data residency / GDPR | [US infrastructure under Cloud Act even if hosted in the EU](https://www.looming.tech/post/cloud-act-aws-eu-region-gdpr) | ✅ Your server | ✅ Your server, hardened |

Day 1 is the easy part. This project is built for day 2 and every day after: the
deployment is idempotent Ansible, so you re-run it to change configuration, add a
component, or rebuild the box — not a one-shot script you can never run twice.

<!-- Marketing note: a ~40s asciinema recording of `sudo bash setup.sh` belongs here. -->

---

## 📑 Table of Contents

- [🚀 Quick Start](#-quick-start)
- [🎁 What You Get](#-what-you-get)
- [📦 What Gets Deployed](#-what-gets-deployed)
- [🤖 Connect Your AI Agent](#-connect-your-ai-agent)
- [🔒 Optional Hardening](#-optional-hardening)
- [🚚 Migration from Supabase Cloud](#-migration-from-supabase-cloud)
- [🔒 Secure MCP Remote Access](#-secure-mcp-remote-access)
- [🔧 Manual Installation](#-manual-installation)
- [💬 Support](#-support)
- [📄 License](#-license)

---

## 🚀 Quick Start

### Prerequisites

- A **Debian-based server** — Debian, Ubuntu, or a derivative — **or Arch**, with root
  or sudo access. The distro family is detected from `ID_LIKE` in `/etc/os-release`
  rather than from a hardcoded list, so derivatives like Mint and Pop!\_OS come along
  for free. CI deploys the full stack on Ubuntu LTS on every release; the Arch package
  path is supported but not covered by CI.
- A **domain** with three DNS A records pointing to your server:
  - `sb.example.com` — Supabase dashboard + API
  - `auth.example.com` — OAuth2 authentication endpoint
  - `monitor.example.com` — Grafana dashboard
- Ports **80** and **443** reachable for automatic Let's Encrypt TLS
- An **OAuth2 application** (GitHub, GitLab, Discord, or any OIDC provider) to protect
  the dashboard — see [SSO Provider Setup](docs/advanced-docs.md#sso-provider-setup)

### Deploy

```bash
git clone https://github.com/ankaboot-source/supabase-selfhost-ops.git
cd supabase-selfhost-ops
cp config.example.yml config.yml
$EDITOR config.yml          # fill the `required:` block — everything else has defaults
sudo bash setup.sh
```

`setup.sh` validates your config, generates every cryptographic secret, renders the
Ansible variables, enables the components you asked for, and deploys the stack.

### Configuring `config.yml`

Four clearly separated sections. **Only `required:` must be filled in.**

```yaml
# ─── REQUIRED (you must fill these) ───────────────────────────
required:
  deploy_user: your-ssh-username
  site_url: https://app.example.com          # your app's public URL
  api_external_url: https://sb.example.com   # Supabase API endpoint
  supabase_domain: sb.example.com            # dashboard domain
  smtp_admin_email: you@example.com
  smtp_host: mail.example.com
  smtp_user: you@example.com
  smtp_password: <smtp-password>
  enable_logging: true                       # dashboard log drain (Logflare + Vector); set false to disable

# ─── SECRETS (auto-generated by default) ─────────────────────
secrets:
  generate: true          # set false to provide your own keys below

# ─── COMPONENTS (all off by default — enable what you need) ──
components:
  caddy: false            # reverse proxy + TLS + SSO
  monitor: false          # Grafana + Prometheus + Loki
  fail2ban: false         # brute-force protection
  backup: false           # automated backups + PITR (pgBackRest)
  ufw: false              # firewall
  luks: false             # at-rest disk encryption
  hardening: false        # OS hardening — enable ssh/sysctl/filesystem sub-sets too

# ─── ADVANCED (only needed when a component is enabled) ──────
advanced:
  caddy:
    sso_provider: Generic   # github | gitlab | discord | Generic
```

> **⚠️ With every component disabled, your Supabase dashboard is exposed with no
> authentication.** For any production deployment, enable at least `caddy`, `ufw`,
> `fail2ban` and `backup`.

### Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview what would happen without modifying any files |
| `--yes` | Non-interactive (skip confirmation prompts) — ideal for CI/AI agents |
| `--force` | Regenerate secrets even if `env/supabase.yml` is already locked |
| `-v, --verbose` | Verbose output |
| `-h, --help` | Show help |

> **Locking:** after the first successful render, `setup.sh` writes `env/.setup.lock`. Subsequent runs **preserve the existing secrets** in `env/supabase.yml` — they are neither regenerated nor overwritten with placeholders — so already-running Supabase services keep working. Pass `--force` to regenerate secrets on purpose (e.g. after a key rotation). `--dry-run` never writes the lock.

```bash
bash setup.sh --dry-run       # preview, no changes
sudo bash setup.sh --yes      # fully non-interactive
```

Full configuration reference: **[docs/advanced-docs.md](docs/advanced-docs.md)**

---

## 🎁 What You Get

### Your coding agent can build on it

Every deployment writes an **instance manifest** (`/etc/supabase/instance.json`): a
machine-readable contract describing ports, container names, endpoints, and where each
secret lives — never the secret values themselves, with leak assertions that fail the
run if one slips through. That is how a tool discovers what was deployed without being
told.

Agents connect over **SSH stdio** to a restricted key that can run exactly one command:
a read-only MCP server exposing `list_tables`, `describe_table`, SELECT-only `query`,
container status, and the manifest. No public port, no `service_role` key handed over,
and no tool whose output includes secret values. The `supabase-selfhosted info` CLI
shows real values on a terminal and redacts them the moment its output is piped.

**Read-only is enforced by the database,** not just by the MCP server's own SQL
filtering. The agent connects to Postgres as a dedicated **`agent_reader`** role
(never the `postgres` superuser) with SELECT-only grants across every schema, and
every query runs inside `SET TRANSACTION READ ONLY` — so Postgres itself rejects
any write, independent of the server code. New tables created later are auto-covered
via `ALTER DEFAULT PRIVILEGES`. (See [docs/connect-your-agent.md](docs/connect-your-agent.md).)

Read-only is not the same as harmless — read access to a database is still access to
the data in it. Give an agent this the way you would give it a read replica.

How to wire it up: [Connect Your AI Agent](#-connect-your-ai-agent) below. The whole
stack is documented for agents in [`AGENTS.md`](AGENTS.md).

### You don't lose your database

pgBackRest runs inside the `supabase-db` container: continuous WAL archiving,
scheduled full and differential backups, **point-in-time recovery to the second**,
and repository integrity verification. Backups go to an external S3 bucket (forced
encryption), a local MinIO repo, or a POSIX path.

Restoring is a documented runbook, not an improvisation — the
[restore-during-an-incident procedure](docs/advanced-docs.md#restore-during-an-incident--5-min)
takes under 5 minutes, and `restore-verify.yml` lets you prove a backup is
restorable **without ever touching production**.

### Your dashboard is not on the internet

Caddy terminates TLS with automatic Let's Encrypt certificates and puts the Studio
dashboard behind OAuth2 SSO — GitHub, GitLab, Discord, or any OIDC provider such as
Keycloak — plus basic auth and an IP allow-list. API routes bypass SSO and are
handled by Kong. UFW closes every internal port, and fail2ban blocks brute-force
attempts against PostgreSQL.

### You know when it breaks

Grafana, Prometheus, Loki, Node Exporter, cAdvisor and Postgres Exporter, deployed
and wired together with dashboards included. Alerting over SMTP is one config block
away.

### You can leave Supabase Cloud

`migrate.sh` moves an existing Cloud project into your self-hosted stack in one
command: schema, data, auth users with UUIDs preserved, and storage objects — always
read-only against the source. See
[Migration from Supabase Cloud](#-migration-from-supabase-cloud).

### Your data is encrypted at rest

LUKS encrypts a dedicated volume holding the Postgres data directory, with automatic
unlock on boot.

---

## 📦 What Gets Deployed

| Container | Service | Port |
|-----------|---------|------|
| `studio` | Supabase Dashboard | 3001 |
| `kong` | API Gateway | 8000 |
| `auth` | GoTrue (Authentication) | 9999 |
| `rest` | PostgREST (REST API) | 3000 |
| `realtime` | Realtime (WebSockets) | 4000 |
| `storage` | Storage API | 5000 |
| `imgproxy` | Image Transformation | 5001 |
| `meta` | postgres-meta | 8080 |
| `functions` | Edge Functions (Deno) | 9000 |
| `db` | PostgreSQL 17 | 5432 |
| `supavisor` | Connection Pooler | 6543 |
| `analytics` | Logflare — dashboard logging | 4000 (internal) |
| `vector` | Log pipeline (docker → Logflare) | 9001 (internal) |

Plus the security and monitoring stack: **Caddy** (reverse proxy + TLS + SSO), **UFW**
firewall, **Fail2ban**, **Security Hardening** (SSH/sysctl/filesystem), and
**Grafana / Prometheus / Loki**. Logflare + Vector
(the Studio log drain) start when `required.enable_logging: true` (default); set
it to `false` to skip them.

Every deployment also writes:
- **`/etc/supabase/instance.json`** — the instance manifest (JSON contract: ports, container names, endpoints, secret *locations*). No secret values, ever.
- **`/usr/local/bin/supabase-agent`** — an MCP server over SSH stdio for AI agents (read-only tools, no secret values).
- **`/usr/local/bin/supabase-selfhosted`** — a CLI to read the manifest and resolve secrets (TTY-aware redaction).

---

## 🤖 Connect Your AI Agent

Every deployment writes an **instance manifest** to `/etc/supabase/instance.json` — a JSON contract describing the instance (database ports, container names, endpoints, secret *locations* — never secret *values*). It also generates an ed25519 SSH key restricted to running `/usr/local/bin/supabase-agent`, an MCP server over stdio that exposes read-only tools (no secret values ever).

At the end of a fresh deployment, the playbook prints the private key **once**, plus a ready-to-paste `~/.ssh/config` block and an MCP client config snippet. To connect your agent (Claude Code, Codex, opencode, pi — they all take the same `{command, args}` shape), follow the one-page guide:

**[docs/connect-your-agent.md](docs/connect-your-agent.md)**

Then verify the connection with:

```bash
sh scripts/verify-connection.sh ~/.ssh/supabase-agent-<host> supabase-agent
```

The verify script is POSIX-clean and runs on both GNU and BSD userland (Linux + macOS).

This agent is the **DB-enforced read-only** endpoint: it connects as a dedicated
`agent_reader` Postgres role (SELECT-only, never the `postgres` superuser), so the
database itself rejects writes.

### Reading secrets back

`supabase-selfhosted info` reads the manifest and resolves the secret references against the `.env` file. **The default flips on whether stdout is a TTY**: a human at a terminal gets the real values (the "what was my service_role key again" recovery path); a pipe, file, or captured stream gets `••••` plus the reference.

```bash
# On the server, at a terminal — shows real values:
supabase-selfhosted info

# Piped (redacted):
supabase-selfhosted info | cat

# Force reveal (for `| pbcopy`):
supabase-selfhosted info --show-secrets | pbcopy

# Force redaction (for screen sharing):
supabase-selfhosted info --no-secrets

# JSON output (redacted unless --show-secrets):
supabase-selfhosted info --json
```

The MCP agent connects with `no-pty`, so it never sees a value it didn't explicitly ask for — and **no MCP tool returns secret values**.

### v2 (deferred)

This is **v1**: the playbook writes nothing on your machine — it prints a snippet, and the docs explain where to put it. **v2** will automate the client side: generate the key into `~/.ssh`, write the `Host` block behind managed markers, and update agent config files (backed up first). It's the difference between "paste one block" and "nothing to paste", and it isn't worth blocking the server work on.

---

## 🔒 Optional Hardening

Both features below are part of the complete stack but need external resources — a
dedicated disk volume and S3 credentials respectively — so they ship disabled.

### Automated Backups + PITR (pgBackRest)

pgBackRest runs **inside** the `supabase-db` container (the upstream
`supabase/postgres` image is not forked; the binary and libraries are bind-mounted
in). It defaults to a local MinIO repo, which gives you no off-box protection and
prints a loud warning — switch to an external S3 bucket for real protection. When
enabled, the installer brings MinIO up before Supabase so WAL archiving resolves on
the database's first boot.

```yaml
components:
  backup: true
advanced:
  backup:
    repo_type: s3              # minio (local, default) | s3 (external) | posix (local fs)
    s3_endpoint: https://<your-endpoint>   # host-only, no URL path
    s3_region: us-east-1
    s3_bucket: supabase-backups
    s3_access_key: <your-key>
    s3_secret_key: <your-secret>
    # Encryption is forced ON for external S3 repos.
    # Credentials default to a plaintext .env file; set creds_source: vault
    # to load them from Ansible Vault instead.
```

Retention tuning, encryption, credential sourcing and the restore runbook:
[docs/advanced-docs.md](docs/advanced-docs.md#backups-pgbackrest).

### At-rest Disk Encryption (LUKS)

Encrypts a separate data volume for the Postgres data directory, unlocked
automatically on boot.

```yaml
components:
  luks: true
advanced:
  luks:
    device: /dev/disk/by-id/YOUR_VOLUME_NAME
    mount_point: /data
```

Then re-run `sudo bash setup.sh` — it regenerates `playbook-supabase.yml` from the
component toggles, so there is nothing to uncomment by hand.

### Security Hardening

Hardens the host OS (Debian + Ubuntu) with native tools only. Disables root SSH
login and hardening timeouts/auth limits, applies Docker-safe kernel network
hardening (SYN-cookies, reverse-path filtering, ASLR), and filesystem hardening
(`noexec` on the world-writable `/dev/shm`). All off by default: you must enable
the `hardening` component **and** the sub-components (`ssh`, `sysctl`,
`filesystem`) you want — nothing disruptive runs until you opt in.

```yaml
components:
  hardening: true
advanced:
  hardening:
    ssh:
      enabled: true
      permit_root_login: false   # forbid direct root SSH login
    sysctl:
      enabled: true
    filesystem:
      enabled: true
```

See [docs/advanced-docs.md](docs/advanced-docs.md#security-hardening).

---

## 🚚 Migration from Supabase Cloud

Once your self-hosted stack is running, `migrate.sh` moves an existing Supabase Cloud
project into it. It migrates schema, data, auth users, storage bucket definitions +
objects, and vault secrets (re-encrypted for the target), then prints a checklist of
the manual steps that remain. It is **read-only** against the source Cloud project.

### What migrates automatically

- **Database schema + data** — `pg_dump`/`pg_restore` of your user schemas (probe
  auto-discovers them, excluding the Supabase-managed schemas the stack provisions:
  `auth`, `storage`, `realtime`, `graphql`, `vault`, `pgsodium`, etc.). Tables, data,
  SQL functions, triggers, and related definitions within your schemas are migrated —
  including **pg_cron jobs** (`cron.job`) and **database webhook definitions**
  (`supabase_webhooks.hooks`), which are carried over best-effort by the same dump.
- **Auth users** — `auth.users` and `auth.identities` with UUIDs preserved. Password
  hashes migrate, so existing passwords keep working; users must log in again
  (sessions are not migrated).
- **Storage bucket definitions** — `storage.buckets` (public/private, size limits,
  MIME types) restored before the object copy, so buckets exist on the target.
- **Storage objects** — copied with `rclone` from the Cloud S3 endpoint to your
  self-hosted storage, read-only against the source.
- **Vault secrets** — re-created on the target via `vault.create_secret`, re-encrypted
  with the target's own root key. Requires the source connection to be able to decrypt
  (`vault.decrypted_secrets`); if it cannot, the phase is skipped (non-fatal) with a note.

### What stays manual

Auth configuration (OAuth/SMTP secrets, MFA), Edge Functions (the source is **not
downloadable from Cloud** — it must come from your project's `supabase/functions`
checkout), per-bucket RLS policies, and client env-var updates.
The script prints the full checklist when it finishes — the migration is incomplete,
but never *silently* incomplete.

### Usage

```bash
cp env/migrate.example.yml env/migrate.yml
$EDITOR env/migrate.yml       # fill the SOURCE (Cloud) and TARGET (self-hosted) sections

./migrate.sh --config env/migrate.yml --dry-run   # preview the plan, no changes
./migrate.sh --config env/migrate.yml --yes       # run it
```

### Invariants

- **Read-only against the source. Always.** `pg_dump` is inherently read-only,
  `rclone copy` never deletes, and the script refuses to run if
  `source.db_url == target.db_url`.
- **Refuses a non-empty target.** Layer 1 migrates into a fresh instance only.
- **No resumability.** A failure means starting over.
- **Runs with no TTY.** `--yes` gates every prompt; colors auto-disable.

Design and test matrix:
[docs/designs/migration-layer-1.md](docs/designs/migration-layer-1.md) ·
[docs/test-cases/migration-layer-1.md](docs/test-cases/migration-layer-1.md)

---

## 🔒 Secure MCP Remote Access

This repo exposes **two** MCP endpoints, with different security postures:

- **Studio MCP** (`/mcp` behind Kong) — Supabase's **default, self-hosted** MCP
  server. It runs as the `postgres` superuser and has **no read-only mode**; safe
  transport, but a connected agent can write. Access is via SSH tunnel, below.
- **Custom `supabase-agent`** — the **DB-enforced read-only** endpoint. It connects
  as a dedicated `agent_reader` role (SELECT-only, never `postgres`), so the
  database itself rejects writes. Connect it via [Connect Your AI Agent](#-connect-your-ai-agent).

### Studio MCP (`/mcp`)

Exposed through the Kong gateway (routed to Studio's `/api/mcp`). It is **never
publicly reachable** — Kong's `ip-restriction` allow list defaults to the Docker
bridge gateway (`172.28.0.1`; Docker source-NATs host connections to that gateway),
so only host-originated traffic reaches it. Caddy never reverse-proxies `/mcp`, and
the direct `/api/mcp` path stays blocked (403).

Authorized clients connect through an SSH tunnel, reusing existing SSH access on port
22 — no new public ports, no new subdomains:

```bash
ssh -L 8080:localhost:8000 deploy_user@sb.example.com -N
```

Then point your MCP client at `http://localhost:8080/mcp`.

The allow list is configurable via `mcp_allowed_ips` in `env/supabase.yml`. Add a
private VPN subnet (e.g. `10.0.0.0/24`) to allow it in addition, or set
`mcp_allowed_ips: []` to disable `/mcp` entirely.

> **⚠️ Adding a public IP or `0.0.0.0/0` re-exposes the endpoint to the internet.**
> Don't.

Full details:
[docs/advanced-docs.md → Secure MCP Remote Access](docs/advanced-docs.md#secure-mcp-remote-access)

---

## 🔧 Manual Installation

If you prefer to control `env/supabase.yml` and `playbook-supabase.yml` directly — or
you are upgrading from a setup that predates `setup.sh` — the original flow still
works:

```bash
sh generate-keys.sh          # writes all Supabase secrets into env/supabase.yml
$EDITOR env/supabase.yml     # fill every field tagged #REQUIRED
$EDITOR playbook-supabase.yml # uncomment the roles you want
sudo ./install.sh            # add -d for a dry run
```

`env/supabase.yml` ships with secure defaults — basic auth, IP allow-list and SSO on
the dashboard. **Keep them.**

The full variable reference, every SSO provider block, the Caddy `projects`
configuration, Grafana authentication modes and the firewall rules are documented in
**[docs/advanced-docs.md](docs/advanced-docs.md)**.

---

## 💬 Support

Issues and pull requests are welcome, and the bar is low —
[CONTRIBUTING.md](CONTRIBUTING.md) covers how to run the whole test suite without a
server, and how configuration flows from `config.yml` down to the playbook.

Security reports go through [SECURITY.md](SECURITY.md), not public issues. That file
is also the honest account of what this project does and does not protect you from.

This project is built and maintained by [ankaboot](https://ankaboot.io/), who run it
in production. If you want the stack deployed or operated for you — or help migrating
off Supabase Cloud — get in touch at [ankaboot.io](https://ankaboot.io/).

---

## 📄 License

MIT
