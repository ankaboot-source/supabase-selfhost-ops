# Monitor Role
## What This Role Does

- Deploys **Grafana**, **Prometheus**, and **Loki** using Docker
- Configures Grafana datasources:
  - Prometheus (metrics)
  - Loki (logs)
- Installs and configures:
  - Node Exporter
  - cAdvisor
  - Postgres Exporter
  - Promtail
- Automatically provisions and includes several useful dashboards

## Alerting

Grafana-provisioned email alerts can be enabled via `advanced.monitor` in
`config.yml` (`alerts_enabled: true`). When enabled, the role renders provisioning
files under `grafana/provisioning/alerting/` that ship:
- **Container-down alerts** — one rule per entry in `alert_containers` (default
  `supabase-envoy` API gateway + `supabase-db`), using cAdvisor's
  `container_last_seen`. Use `supabase-kong` instead of `supabase-envoy` when
  running the Kong fallback override.
- **Disk usage alert** — node-exporter `node_filesystem_*` above
  `alert_disk_threshold` (default 85%).
- **Host memory alert** — node-exporter `node_memory_*` above
  `alert_memory_threshold` (default 80%).
- **Email contact point + notification policy** — recipients from
  `alert_emails`, sent via the Grafana SMTP block (fed by `setup.sh` from
  `advanced.monitor.smtp_*`, falling back to `required.smtp_*`).

These rules are general — no host/job/instance hardcoding — so they work for any
deploy without editing. They reference the pinned Prometheus datasource UID
(`PBFA97CFB590B2093`).

## Authentication & Access

Grafana is **secured by default** using **GitHub OAuth**.

#### GitHub OAuth (Default)

Required variables:
- GitHub Client ID
- GitHub Client Secret
- Allowed GitHub organizations

Reference:  
https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/github/

#### Anonymous Access (Optional)

- Enabling it will allow everyone to access the dashboard 
- Role (Admin / Viewer) is configurable



## Configuration

All settings are configured via [env/supabase.yml](https://github.com/ankaboot-source/ansible-supabase/blob/main/env/supabase.yml#L9), update them accordingly.
