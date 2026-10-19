# Security

## What this project is, security-wise

This project does not invent security. It composes things other people built —
Supabase, Caddy and caddy-security, pgBackRest, Postgres, Docker, UFW, fail2ban,
LUKS — and wires them together with defaults meant to be safe on a server facing
the internet.

So the honest claim is narrow: **the value here is the defaults and the wiring, not
a guarantee.** If Supabase, Caddy or Postgres has a vulnerability, this project has
it too. What we can be held to is that a default deployment does not do something
obviously careless, and that the configuration we generate is sound.

No formal security audit has been performed on this project.

## Known limitations

These are design trade-offs, not bugs. They are listed here so nobody has to
discover them the hard way.

- **Components ship disabled.** A `setup.sh` run with the default `config.yml`
  deploys Supabase with no reverse proxy and no dashboard authentication. Enabling
  `caddy`, `ufw`, `fail2ban` and `backup` is on you, and the installer warns about
  it rather than deciding for you.
- **The default backup repository is local.** `repo_type: rustfs` writes backups to
  the same machine as the database. If the server dies, so do the backups. External
  S3 is one config block away, and the installer prints a loud warning until you
  switch.
- **Secrets sit in plaintext on the server.** `env/supabase.yml` holds generated
  keys, and backup credentials default to a plaintext `.env`. `creds_source: vault`
  moves the latter into Ansible Vault. File permissions are the only thing
  protecting the former.
- **Agent access is read-only, not harmless.** Read-only is enforced by the
  database — the MCP connects as a dedicated `agent_reader` role with SELECT-only
  grants and every query runs in `SET TRANSACTION READ ONLY` — and no MCP tool
  returns secret values. But read access to a database is still access to the data
  in it. Grant it to agents you would grant a read replica to.
- **Migration is one-shot.** `migrate.sh` is read-only against the source and
  refuses a non-empty target, but it has no resumability. A failure means starting
  over.
- **TLS depends on your DNS.** Automatic certificates require the domains to
  actually point at the server before you deploy.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting on this repository (Security →
Report a vulnerability), which keeps the discussion private until there is a fix.
If you would rather use email, write to **ops@ankaboot.io**.

Useful things to include: what you did, what happened, which components were
enabled in `config.yml`, and roughly which version or commit you deployed.

### What to expect

This is maintained by a small team alongside other work. We will acknowledge a
report within a few working days and tell you honestly whether we can fix it
quickly, slowly, or not at all. There is no bug bounty, and we would rather say
that plainly than imply a process we do not run.

If you want credit in the fix, say so and you will get it.

## Going further than the defaults

The defaults here are meant to be sane for a server on the internet. They are not
a security programme, and some situations need one — a regulated workload, a data
residency requirement you have to evidence, a threat model that goes beyond
"don't leave the dashboard open", or simply someone accountable for the thing at
3am.

- **`agent_reader` — DB-enforced read-only for AI agents.** The custom
  `supabase-agent` connects to Postgres as a dedicated read-only role (SELECT-only
  grants across every schema, never the `postgres` superuser), and every query
  runs in `SET TRANSACTION READ ONLY` — so the database rejects writes independent
  of server code. New tables are auto-covered via `ALTER DEFAULT PRIVILEGES`;
  custom schemas are a documented one-liner. This is the read-only surface you'd
  expose to an agent, distinct from Studio's writable `/mcp`.

For an easy, config-driven first step beyond these defaults, enable the
[`hardening` role](docs/advanced-docs.md#security-hardening) — Disable root SSH
login, cap auth tries, harden the kernel/network and filesystem — all opt-in,
off-by-default, and safe for the running Supabase stack.

If that is where you are, **ops@ankaboot.io**. We deploy and operate this stack in
production and can help with hardening reviews, key management, backup and restore
drills, and running it for you. Paid work, stated plainly so nobody mistakes this
file for a sales page.

## Which project to report to

If the problem is in an upstream component rather than in how we configure it,
reporting it upstream reaches the people who can actually fix it:

| Where the bug lives | Report to |
|---|---|
| Supabase services, Studio, GoTrue, PostgREST, Realtime, Storage | [supabase/supabase](https://github.com/supabase/supabase/security) |
| Caddy or the caddy-security module | [caddyserver/caddy](https://github.com/caddyserver/caddy/security) |
| pgBackRest | [pgbackrest/pgbackrest](https://github.com/pgbackrest/pgbackrest) |
| PostgreSQL | [postgresql.org/support/security](https://www.postgresql.org/support/security/) |
| Docker, UFW, fail2ban, LUKS | Their respective projects |
| **Our roles, templates, defaults, `setup.sh`, `migrate.sh`, agent access** | **Here** |

When in doubt, report it here and we will route it.
