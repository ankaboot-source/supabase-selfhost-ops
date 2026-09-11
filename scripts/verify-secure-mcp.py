#!/usr/bin/env python3
"""Render and validate the Kong template for the Secure MCP feature.

Implements the test cases from docs/test-cases/secure-mcp.md:
  TC-MCP-002, TC-MCP-003, TC-MCP-004, TC-MCP-005, TC-MCP-006, TC-MCP-010
"""
import sys
import yaml
from jinja2 import Environment, FileSystemLoader

ROLE_TEMPLATES = "roles/supabase/templates"
KONG_TEMPLATE = "kong-supabase.yml.j2"
ENVOY_LDS_TEMPLATE = "lds.template.yaml.j2"
LOGS_COMPOSE_TEMPLATE = "docker-compose-logs.yml.j2"
VECTOR_TEMPLATE = "vector-logs.yml.j2"
CADDY_TEMPLATES = "roles/caddy/templates"


def render_kong(trim_blocks=False, lstrip_blocks=False, **vars):
    env = Environment(
        loader=FileSystemLoader(ROLE_TEMPLATES),
        keep_trailing_newline=True,
        trim_blocks=trim_blocks,
        lstrip_blocks=lstrip_blocks,
    )
    return env.get_template(KONG_TEMPLATE).render(**vars)


def render_envoy_lds(trim_blocks=False, lstrip_blocks=False, **vars):
    env = Environment(
        loader=FileSystemLoader(ROLE_TEMPLATES),
        keep_trailing_newline=True,
        trim_blocks=trim_blocks,
        lstrip_blocks=lstrip_blocks,
    )
    return env.get_template(ENVOY_LDS_TEMPLATE).render(**vars)


def render_logs(trim_blocks=False, lstrip_blocks=False, **vars):
    env = Environment(
        loader=FileSystemLoader(ROLE_TEMPLATES),
        keep_trailing_newline=True,
        trim_blocks=trim_blocks,
        lstrip_blocks=lstrip_blocks,
    )
    return env.get_template(LOGS_COMPOSE_TEMPLATE).render(**vars)


def render_vector(trim_blocks=False, lstrip_blocks=False, **vars):
    env = Environment(
        loader=FileSystemLoader(ROLE_TEMPLATES),
        keep_trailing_newline=True,
        trim_blocks=trim_blocks,
        lstrip_blocks=lstrip_blocks,
    )
    return env.get_template(VECTOR_TEMPLATE).render(**vars)


def find_service(doc, name):
    for svc in doc.get("_format_version", None) and doc.get("services", []) or doc.get("services", []):
        if svc.get("name") == name:
            return svc
    return None


def get_plugins(svc):
    return svc.get("plugins", []) if svc else []


def assert_true(cond, msg):
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)
    print(f"ok: {msg}")


def main():
    # Default variables (mirrors roles/supabase/defaults/main.yml)
    defaults = dict(
        sb_studio_version="supabase/studio:latest",
        sb_kong_version="kong/kong:3.9.1",
        sb_gotrue_version="supabase/gotrue:latest",
        sb_rest_version="postgrest/postgrest:latest",
        sb_realtime_version="supabase/realtime:latest",
        sb_storage_version="supabase/storage-api:latest",
        sb_imgproxy_version="darthsim/imgproxy:latest",
        sb_meta_version="supabase/postgres-meta:latest",
        sb_functions_version="supabase/edge-runtime:latest",
        sb_db_version="supabase/postgres:latest",
        sb_supavisor_version="supabase/supavisor:latest",
        sb_logflare_version="supabase/logflare:latest",
        sb_vector_version="timberio/vector:latest",
        caddy_cert_base_path="/tmp",
        postgres_cert_path="/tmp",
        mcp_allowed_ips=["172.28.0.1"],
        deploy_user="deploy",
        deploy_env="prod",
        supabase_path="supabase/docker",
        kong_conf_path="volumes/api",
        postgres_db_pwd="pwd",
        sb_jwt_secret="secret",
        sb_anon_key="anon",
        sb_service_role_key="svc",
        secret_key_base="sk",
        vault_enc_key="vk",
        pg_meta_crypto_key="pg",
        logflare_public_access_token="pub",
        logflare_private_access_token="priv",
        s3_protocol_access_key_id="ak",
        s3_protocol_access_key_secret="sk",
        pooler_tenant_id="pooler",
        site_url="https://app.example.com",
        api_external_url="https://sb.example.com",
        additional_redirect_urls="",
        mailer_templates_base_url="",
        enable_email_signup=True,
        enable_email_autoconfirm=False,
        smtp_admin_email="",
        smtp_host="",
        smtp_port=587,
        smtp_user="",
        smtp_password="",
        smtp_sender_name="",
        google_enabled=False,
        google_client_id="",
        google_secret="",
        github_enabled=False,
        github_client_id="",
        github_secret="",
        azure_enabled=False,
        azure_client_id="",
        azure_secret="",
        openai_api_key="",
        sb_publishable_key="",
        sb_secret_key="",
        sb_jwt_keys="",
        sb_jwt_jwks="",
        supabase_data_path="/var/lib/supabase/data",
    )

    # TC-MCP-005: render with defaults, parse YAML
    # Also render under every trim_blocks/lstrip_blocks combination: block
    # {% for %} tags collapse onto one line when Ansible sets trim_blocks,
    # which broke Kong's parser (allow/deny entries must stay inline or on
    # separate lines).
    for trim, lstrip in [(False, False), (True, False), (False, True), (True, True)]:
        rendered = render_kong(trim_blocks=trim, lstrip_blocks=lstrip, **defaults)
        doc = yaml.safe_load(rendered)
        assert_true(
            isinstance(doc, dict),
            f"rendered kong.yml is a YAML mapping (trim_blocks={trim}, lstrip_blocks={lstrip})",
        )
    rendered = render_kong(**defaults)
    doc = yaml.safe_load(rendered)
    assert_true(isinstance(doc, dict), "rendered kong.yml is a YAML mapping")
    services = doc.get("services", [])
    assert_true(isinstance(services, list) and len(services) > 0, "services list is non-empty")

    # TC-MCP-001: mcp-blocker has request-termination 403
    blocker = next((s for s in services if s.get("name") == "mcp-blocker"), None)
    assert_true(blocker is not None, "mcp-blocker service exists")
    blocker_plugins = get_plugins(blocker)
    rt = next((p for p in blocker_plugins if p.get("name") == "request-termination"), None)
    assert_true(rt is not None, "mcp-blocker has request-termination plugin")
    assert_true(rt.get("config", {}).get("status_code") == 403, "mcp-blocker returns 403")

    # TC-MCP-002: mcp service has ip-restriction with bridge-gateway allow, no request-termination
    mcp = next((s for s in services if s.get("name") == "mcp"), None)
    assert_true(mcp is not None, "mcp service exists")
    mcp_plugins = get_plugins(mcp)
    ipr = next((p for p in mcp_plugins if p.get("name") == "ip-restriction"), None)
    assert_true(ipr is not None, "mcp service has ip-restriction plugin")
    allow = ipr.get("config", {}).get("allow", [])
    assert_true("172.28.0.1" in allow, "default allow list contains the Docker bridge gateway")
    rt_mcp = next((p for p in mcp_plugins if p.get("name") == "request-termination"), None)
    assert_true(rt_mcp is None, "mcp service has NO request-termination plugin")

    # TC-MCP-003 / TC-MCP-006: custom allowed IPs honored
    custom = dict(defaults)
    custom["mcp_allowed_ips"] = ["10.0.0.5", "172.28.0.1", "10.0.0.0/24"]
    rendered_custom = render_kong(**custom)
    doc_custom = yaml.safe_load(rendered_custom)
    services_custom = doc_custom.get("services", [])
    mcp_custom = next((s for s in services_custom if s.get("name") == "mcp"), None)
    ipr_custom = next((p for p in get_plugins(mcp_custom) if p.get("name") == "ip-restriction"), None)
    allow_custom = ipr_custom.get("config", {}).get("allow", [])
    assert_true("10.0.0.5" in allow_custom, "custom allow list includes 10.0.0.5")
    assert_true("10.0.0.0/24" in allow_custom, "custom allow list includes 10.0.0.0/24")
    assert_true("172.28.0.1" in allow_custom, "custom allow list includes 172.28.0.1")

    # Envoy gateway (default). lds.template.yaml.j2 /mcp route must:
    #   - render to valid YAML under every trim_blocks/lstrip_blocks combo
    #   - use an ALLOW RBAC with direct_remote_ip principals matching
    #     mcp_allowed_ips (Docker source-NATs host traffic to the pinned
    #     bridge gateway 172.28.0.1)
    #   - contain NO basic_auth filter (dashboard is Caddy-SSO-fronted)
    for trim, lstrip in [(False, False), (True, False), (False, True), (True, True)]:
        rendered = render_envoy_lds(trim_blocks=trim, lstrip_blocks=lstrip, **defaults)
        doc = yaml.safe_load(rendered)
        assert_true(
            isinstance(doc, dict) and "resources" in doc,
            f"rendered lds.template.yaml is a YAML mapping (trim_blocks={trim}, lstrip_blocks={lstrip})",
        )
    rendered = render_envoy_lds(**defaults)
    doc = yaml.safe_load(rendered)
    assert_true(isinstance(doc, dict), "rendered lds.template.yaml is a YAML mapping")

    # Reject any leftover basic_auth
    assert_true("basic_auth" not in rendered, "lds.template.yaml contains NO basic_auth filter")

    # Walk the virtual host routes to find the /mcp route and its RBAC principals
    def _mcp_principals(listener_doc):
        vhosts = (
            listener_doc["resources"][0]["filter_chains"][0]["filters"][0]
            ["typed_config"]["route_config"]["virtual_hosts"]
        )
        for vh in vhosts:
            for route in vh.get("routes", []):
                match = route.get("match", {})
                if match.get("prefix") == "/mcp":
                    tpc = route.get("typed_per_filter_config", {})
                    rbac = tpc.get("envoy.filters.http.rbac", {}).get("rbac", {})
                    rules = rbac.get("rules", {})
                    policies = rules.get("policies", {})
                    allow_mcp = policies.get("allow_mcp")
                    return rules.get("action"), (allow_mcp or {}).get("principals", [])
        return None, []

    action, principals = _mcp_principals(doc)
    assert_true(action == "ALLOW", "Envoy /mcp RBAC action is ALLOW")
    addrs = [
        p["direct_remote_ip"]["address_prefix"]
        for p in principals
        if "direct_remote_ip" in p
    ]
    assert_true(
        sorted(addrs) == sorted(defaults["mcp_allowed_ips"]),
        f"Envoy /mcp allow principals match mcp_allowed_ips {defaults['mcp_allowed_ips']}",
    )

    # Custom allowed IPs honored by Envoy
    rendered_custom = render_envoy_lds(**custom)
    doc_custom_e = yaml.safe_load(rendered_custom)
    _action, principals_custom = _mcp_principals(doc_custom_e)
    addrs_custom = {
        p["direct_remote_ip"]["address_prefix"]
        for p in principals_custom
        if "direct_remote_ip" in p
    }
    assert_true(
        sorted(addrs_custom) == sorted(custom["mcp_allowed_ips"]),
        "Envoy /mcp allow principals honor custom mcp_allowed_ips",
    )

    # TC-MCP-010: no /mcp path in Caddy example projects
    # Parse env/supabase.yml and inspect the projects' upstream paths.
    with open("env/supabase.yml") as f:
        env_doc = yaml.safe_load(f)
    projects = env_doc.get("projects", {}) or {}
    mcp_in_caddy = False
    for _proj, cfg in projects.items():
        for upstream in (cfg.get("upstreams") or []):
            for path in (upstream.get("paths") or []):
                if "/mcp" in path:
                    mcp_in_caddy = True
    assert_true(not mcp_in_caddy, "env/supabase.yml Caddy projects do not expose /mcp")

    # Log drain (docker-compose-logs.yml.j2) — the override must stay valid YAML
    # under every trim_blocks/lstrip_blocks combination (same class of bug as the
    # Kong {% for %} loop that mangled allow/deny), define the analytics/vector
    # services with the deploy_env-suffixed container names, and flip Studio's
    # ENABLED_FEATURES_LOGS_ALL to true.
    for trim, lstrip in [(False, False), (True, False), (False, True), (True, True)]:
        rendered = render_logs(trim_blocks=trim, lstrip_blocks=lstrip, **defaults)
        doc = yaml.safe_load(rendered)
        assert_true(
            isinstance(doc, dict) and "services" in doc,
            f"docker-compose-logs.yml is a YAML mapping with services (trim_blocks={trim}, lstrip_blocks={lstrip})",
        )
    logs_doc = yaml.safe_load(render_logs(**defaults))
    logs_services = logs_doc.get("services", {})
    assert_true("analytics" in logs_services, "logs override defines analytics service")
    assert_true("vector" in logs_services, "logs override defines vector service")
    assert_true(
        logs_services["analytics"].get("container_name") == "supabase-analytics-prod",
        "analytics container_name carries the deploy_env suffix",
    )
    assert_true(
        logs_services["vector"].get("container_name") == "supabase-vector-prod",
        "vector container_name carries the deploy_env suffix",
    )
    studio_env = logs_services.get("studio", {}).get("environment", {})
    assert_true(
        studio_env.get("ENABLED_FEATURES_LOGS_ALL") == "true",
        "studio override enables ENABLED_FEATURES_LOGS_ALL",
    )

    # Vector pipeline (vector-logs.yml.j2) — must render to valid YAML with the
    # router appnames matching the deploy_env-suffixed container names (except
    # realtime-dev.supabase-realtime, which never gets a suffix).
    vector_doc = yaml.safe_load(render_vector(**defaults))
    transforms = vector_doc.get("transforms", {})
    router = transforms.get("router", {}).get("route", {})
    assert_true(router.get("kong") == '.appname == "supabase-kong-prod" || .appname == "supabase-envoy"', "router kong route uses suffixed container name")
    assert_true(router.get("db") == '.appname == "supabase-db-prod"', "router db route uses suffixed container name")
    assert_true(router.get("realtime") == '.appname == "realtime-dev.supabase-realtime"', "router realtime route is not suffixed")

    print("\nAll Kong template tests passed.")


if __name__ == "__main__":
    main()