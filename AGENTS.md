# AGENTS.md — server-config

## Project Overview

Ansible-based server configuration for a personal VPS (Ubuntu 24) hosting a Docker Compose stack with:

- **Traefik** (reverse proxy + Let's Encrypt, Prometheus metrics on port 8082)
- **Authelia** (SSO/OIDC provider)
- **PostgreSQL** (shared database)
- **Vikunja** (task management, OIDC via Authelia)
- **Navidrome** (music streaming, forward auth via Authelia)
- **Syncthing** (Obsidian vault synchronization, forward auth via Authelia)
- **OpenClaw** (AI orchestration/intelligence layer, forward auth via Authelia)
- **Signal** (Messaging API via signal-cli-rest-api, internal service only, no public access)
- **Grafana + Loki + Promtail** (monitoring/logging stack with pre-provisioned datasources and dashboards)
- **Prometheus** (metrics scraping for Syncthing, Traefik, and cAdvisor)
- **cAdvisor** (Docker container metrics exporter)

## Architecture

- Single VPS (`palma`, 185.196.20.127)
- SSH on port 22 (default), key-based auth only
- All services behind Traefik with subdomains under `les12.fr`
- Authelia provides both forward auth (Navidrome, Syncthing, OpenClaw) and OIDC (Vikunja, Grafana)
- Docker Compose stack managed via systemd unit (`stack.service`)
- Obsidian vaults stored at `/opt/services/shared/obsidian/vaults` for Syncthing synchronization
- **Monitoring stack**: Prometheus scrapes 3 targets (Syncthing:8384, cAdvisor:8080, Traefik:8082) → Grafana with 3 pre-provisioned dashboards (Syncthing, Docker Containers, Traefik)

### Docker Networks

| Network     | Purpose                           | Services                                                                           |
| ----------- | --------------------------------- | ---------------------------------------------------------------------------------- |
| `web`       | Traefik-facing, public access     | Traefik, Authelia, Vikunja, Navidrome, Grafana, Syncthing, OpenClaw                |
| `internal`  | Backend DB/internal communication | Postgres, Authelia, Vikunja, Loki, Promtail, Grafana                               |
| `knowledge` | Service-to-service (API calls)    | Traefik, Vikunja, Syncthing, OpenClaw, Signal, Prometheus, cAdvisor, Loki, Grafana |

## Playbook Structure

### `init.yml` — Bootstrap (run once as root)

- Creates admin user with sudo + SSH key
- Hardens SSH (no root login, no password auth)
- Installs UFW + fail2ban
- Run via: `sh init.sh`

### `site.yml` — Full configuration (run as admin)

- **Roles (in order):**
  1. `common` — apt update/upgrade, base packages
  2. `security` — SSH hardening, UFW, fail2ban, sysctl, unattended-upgrades
  3. `docker` — Docker engine + compose plugin
  4. `openclaw_build` — Git clone OpenClaw source + Docker image build (`theo/openclaw:stable`)
  5. `deploy_stack` — Full Docker Compose stack deployment
  6. `backup` — Backup cron job + initial backup
  7. `openclaw_integration` — Service-to-service integration config (endpoints, API keys, Grafana webhooks, Prometheus alerting rules)
- Run via: `sh run.sh`

## Key Variables

### `ansible/group_vars/vps.yml`

- Domain, subdomains, admin user, SSH settings
- Docker images, paths, OIDC client IDs
- Brevo SMTP config for Authelia email
- `ssh_port: 22`, `ssh_uses_socket_activation: true`
- `backup_dir: /var/backups/server-config`, `backup_retention_days: 30`

### `ansible/group_vars/vps.vault.yml` (encrypted)

- All database passwords, secrets, API keys
- Authelia JWT/session/storage secrets
- OIDC client secrets (plaintext + hashed)
- SMTP credentials
- `grafana_admin_password`, `grafana_oidc_client_secret`
- `vikunja_api_token` — API token for OpenClaw integration
- Initial SSH password for bootstrap

## deploy_stack Role Details

### Tasks (`tasks/main.yml`)

1. Create directory structure for all services (including Syncthing, OpenClaw, obsidian vaults, Prometheus, Grafana dashboards)
2. Generate Authelia OIDC private key (RSA 4096, persisted)
3. Hash OIDC client secret for Vikunja (pbkdf2-sha512, persisted)
4. Hash OIDC client secret for Grafana (pbkdf2-sha512, persisted)
5. Render all config templates (docker-compose.yml, traefik, authelia, vikunja, etc.)
6. Validate Authelia config with `docker run authelia config validate`
7. Render Grafana datasource provisioning (Loki + Prometheus)
8. Render Grafana dashboard provisioning config + copy Syncthing, Docker Containers, and Traefik dashboards
9. Fix volume permissions for UIDs 1000 (Vikunja, Navidrome, Syncthing, OpenClaw) and 10001 (Loki)
10. Install systemd unit + start stack
11. Create Navidrome user `theo` in SQLite DB via `docker compose exec navidrome sqlite3 ... INSERT OR IGNORE INTO user` (required for external auth via Authelia — fresh DB has no users and auto-creation doesn't work)

### Templates

- `docker-compose.yml.j2` — All services with networks (`web`, `internal`, `knowledge`), volumes, secrets, Traefik labels
- `traefik.yml.j2` — Static config (entrypoints, providers, Let's Encrypt)
- `middlewares.yml.j2` — Authelia forward auth + BasicAuth + HTTPS redirect + header stripping
- `authelia-configuration.yml.j2` — Full Authelia config with OIDC clients
- `authelia-users_database.yml.j2` — Single admin user with argon2id password hash
- `vikunja-config.yml.j2` — OIDC auth via Authelia
- `01-create-dbs.sql.j2` — Postgres init script (authelia + vikunja DBs)
- `stack.env.j2` — Shared env vars (DB passwords, SMTP, OIDC secret, Vikunja API token)
- `stack.service.j2` — Systemd unit for the stack
- `syncthing-config.xml.j2` — Initial Syncthing config (insecureSkipHostcheck, GUI on 0.0.0.0:8384, debugging enabled for Prometheus metrics, obsidian vaults folder)
- `loki-config.yml.j2` — Loki 3.4.x compatible config (TSDB schema v13)
- `promtail-config.yml.j2` — System logs + Docker container logs
- `prometheus.yml.j2` — Prometheus scrape config (Syncthing:8384, cAdvisor:8080, Traefik:8082)
- `grafana-datasources.yml.j2` — Loki datasource auto-provisioning
- `grafana.ini.j2` — Grafana OIDC config via Authelia
- `syncthing-dashboard.json` — Pre-provisioned Grafana dashboard for Syncthing metrics
- `docker-containers-dashboard.json` — Pre-provisioned Grafana dashboard for Docker container metrics (cAdvisor)
- `traefik-dashboard.json` — Pre-provisioned Grafana dashboard for Traefik reverse proxy metrics

## backup Role Details

### Tasks (`tasks/main.yml`)

1. Create backup directory structure
2. Render backup shell script
3. Install cron job (daily at 04:00)
4. Run initial backup (tagged `initial-backup`)

### Backup Script (`backup.sh.j2`)

- **PostgreSQL**: `pg_dumpall` via `docker compose exec`, gzipped
- **Obsidian vaults**: tar.gz archive
- **Docker volumes**: pgdata, navidrome_data, loki_data, grafana_data, prometheus_data, signal_data
- **Stack config**: tar.gz (excluding large data dirs already backed up as volumes)
- **Retention**: backups older than `backup_retention_days` (default: 30) pruned
- Output directory: `/var/backups/server-config/`

## Known Issues & Resolutions

| Issue                                                                                             | Cause                                                                                                                                                                                                                                                                                                                                                                                                    | Fix                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SSH connection lost during init                                                                   | SSH socket restart                                                                                                                                                                                                                                                                                                                                                                                       | Removed port change (stays on 22)                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Navidrome permission denied                                                                       | Volume owned by root                                                                                                                                                                                                                                                                                                                                                                                     | `chown -R 1000:1000`                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Vikunja permission denied                                                                         | Bind mount dir owned by root                                                                                                                                                                                                                                                                                                                                                                             | `chown -R 1000:1000`                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Loki permission denied                                                                            | Volume owned by root, UID 10001                                                                                                                                                                                                                                                                                                                                                                          | `chown -R 10001:10001`                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Loki config parse errors                                                                          | Removed fields in Loki 3.x                                                                                                                                                                                                                                                                                                                                                                               | Rewrote config for v13 schema                                                                                                                                                                                                                                                                                                                                                                                                                             |
| apt lock contention on first run                                                                  | unattended-upgrades at boot                                                                                                                                                                                                                                                                                                                                                                              | Added `retries: 5` / `delay: 10`                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Permission fix ineffective                                                                        | Ran before volumes existed                                                                                                                                                                                                                                                                                                                                                                               | Moved after `Start stack service`                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Grafana OIDC token exchange failed                                                                | Auth method mismatch                                                                                                                                                                                                                                                                                                                                                                                     | Added `token_endpoint_auth_method: client_secret_post`                                                                                                                                                                                                                                                                                                                                                                                                    |
| Grafana double auth (forward auth + OIDC)                                                         | Redundant Traefik middleware on Grafana router                                                                                                                                                                                                                                                                                                                                                           | Removed `traefik.http.routers.grafana.middlewares=authelia@file` (OIDC alone is sufficient)                                                                                                                                                                                                                                                                                                                                                               |
| Navidrome trusted sources too broad                                                               | `172.0.0.0/8` included non-Docker ranges                                                                                                                                                                                                                                                                                                                                                                 | Changed to `172.16.0.0/12` (RFC 1918 Docker range)                                                                                                                                                                                                                                                                                                                                                                                                        |
| Grafana OIDC token exchange fails (env vars ignored)                                              | Grafana doesn't load `client_secret` from env vars properly, falls back to `none` auth method                                                                                                                                                                                                                                                                                                            | Created `grafana.ini.j2` with explicit OIDC config + mounted to `/etc/grafana/grafana.ini`; removed OIDC env vars from docker-compose                                                                                                                                                                                                                                                                                                                     |
| Navidrome SSL cert not issued on fresh install                                                    | DNS for `music.les12.fr` may not point to server yet, or cert issuance delayed                                                                                                                                                                                                                                                                                                                           | Ensure DNS A record points to VPS IP; Traefik retries automatically with backoff                                                                                                                                                                                                                                                                                                                                                                          |
| Traefik forward auth DoS warning                                                                  | `maxResponseBodySize` not configured on Authelia forward auth middleware                                                                                                                                                                                                                                                                                                                                 | Added `maxResponseBodySize: 1048576` to middleware config                                                                                                                                                                                                                                                                                                                                                                                                 |
| Navidrome unprotected via HTTP                                                                    | HTTP router `navidrome-web` had no Authelia middleware, users could bypass auth if HTTPS cert failed                                                                                                                                                                                                                                                                                                     | Added `authelia@file` to HTTP router middlewares chain                                                                                                                                                                                                                                                                                                                                                                                                    |
| Navidrome Subsonic clients auth failure                                                           | Missing dedicated Subsonic router with BasicAuth middleware                                                                                                                                                                                                                                                                                                                                              | Added `navidrome-subsonic` router with `authelia-basicauth@docker` middleware and `drop-untrusted-auth-headers@docker`                                                                                                                                                                                                                                                                                                                                    |
| Navidrome redirects to its own login screen after ~5s                                             | `drop-untrusted-auth-headers@docker` middleware on the main Navidrome router may interfere with `authResponseHeaders` from `authelia@file` middleware (potential Traefik provider priority issue between `@docker` and `@file` middlewares)                                                                                                                                                              | Removed `drop-untrusted-auth-headers@docker` from `navidrome` main router; kept it on `navidrome-subsonic` and `navidrome-web` routers only                                                                                                                                                                                                                                                                                                               |
| Navidrome Subsonic API inaccessible from mobile clients                                           | `navidrome-subsonic` router used Authelia BasicAuth, but mobile Subsonic clients (Symfonium, Amperfy, play:Sub) don't support Authelia auth flows — they need to auth directly against Navidrome's Subsonic API                                                                                                                                                                                          | Replaced `navidrome-subsonic` router (Authelia BasicAuth) with `navidrome-api` router: no Authelia middleware, `PathPrefix(/rest/)` rule, `priority=100`. Main `navidrome` router keeps Authelia with `priority=10`. Mobile clients auth via Navidrome Subsonic password/token directly.                                                                                                                                                                  |
| Navidrome "Authenticated username not found in DB" after middleware fix                           | Fresh Navidrome database with no users; auto-creation via external auth not working (possible bug in Navidrome 0.61.2 or silent failure)                                                                                                                                                                                                                                                                 | Created user `theo` directly in SQLite via `sqlite3 /data/navidrome.db "INSERT INTO user (id, user_name, name, email, password, is_admin, created_at, updated_at) VALUES ('theo', 'theo', 'theo', 'theo@les12.fr', '', 1, datetime('now'), datetime('now'));"` after restarting container                                                                                                                                                                 |
| Navidrome header spoofing risk                                                                    | `Remote-User` headers not stripped at entrypoint                                                                                                                                                                                                                                                                                                                                                         | Added `drop-untrusted-auth-headers` middleware to all Navidrome routers, defined on Authelia service labels                                                                                                                                                                                                                                                                                                                                               |
| Navidrome Traefik IP not trusted                                                                  | `ND_EXTAUTH_TRUSTEDSOURCES` set to `172.16.0.0/12` but Traefik gets dynamic IP                                                                                                                                                                                                                                                                                                                           | Changed to `0.0.0.0/0` as recommended by Navidrome docs (Traefik IP is dynamic)                                                                                                                                                                                                                                                                                                                                                                           |
| Navidrome IPv6 localhost not trusted                                                              | `ND_EXTAUTH_TRUSTEDSOURCES` set to `0.0.0.0/0` but container health checks use IPv6 `::1`                                                                                                                                                                                                                                                                                                                | Added `::/0` to cover IPv6 loopback (`0.0.0.0/0,::/0`)                                                                                                                                                                                                                                                                                                                                                                                                    |
| Grafana dashboard provisioning fails                                                              | Missing volume mount for dashboards directory                                                                                                                                                                                                                                                                                                                                                            | Added `{{ stack_dir }}/grafana/dashboards:/etc/grafana/dashboards:ro` to Grafana volumes in docker-compose.yml.j2                                                                                                                                                                                                                                                                                                                                         |
| Loki alerting rules not loaded                                                                    | Loki container had no volume mount for rules directory (`/loki/rules`). Rules placed at `{{ stack_dir }}/loki/rules/` on host were invisible inside the container.                                                                                                                                                                                                                                        | Added `{{ stack_dir }}/loki/rules:/loki/rules:ro` volume mount to Loki service in docker-compose.yml.j2                                                                                                                                                                                                                                                                                                                                                    |
| Prometheus alerting rules not loaded                                                              | Prometheus container had no volume mount for rules directory (`/etc/prometheus/rules`). Rules placed at `{{ stack_dir }}/prometheus/rules/` on host were invisible inside the container.                                                                                                                                                                                                                | Added `{{ stack_dir }}/prometheus/rules:/etc/prometheus/rules:ro` volume mount to Prometheus service in docker-compose.yml.j2                                                                                                                                                                                                                                                                                                                             |
| Grafana doesn't pick up new provisioning after grafana_security role                              | Grafana provisioning configs are only read at startup. The `grafana_security` role copies files to provisioning directory but doesn't trigger a Grafana restart.                                                                                                                                                                                                                                        | Added `notify: Restart stack` to the dashboard provisioning config task in `grafana_security/tasks/main.yml`                                                                                                                                                                                                                                                                                                                                              |
| Grafana Loki datasource UID mismatch after re-deployment                                          | Grafana provisioning does not update existing datasources. If Loki datasource was created with auto-generated UID, subsequent provisioning with `uid: loki` is ignored.                                                                                                                                                                                                                                  | Manual fix: Delete old Loki datasource via Grafana API, then restart Grafana to trigger reprovisioning with correct UID. See "Loki Datasource UID Fix" section below.                                                                                                                                                                                                                                                                                    |
| Syncthing dashboard "title cannot be empty"                                                       | Dashboard JSON wrapped in `{"dashboard": {...}}` format (HTTP API format), but file provisioning expects raw dashboard object                                                                                                                                                                                                                                                                            | Removed wrapper in `syncthing-dashboard.json`, kept only the dashboard object directly                                                                                                                                                                                                                                                                                                                                                                    |
| Grafana OIDC `client_secret_basic` rejected                                                       | Grafana defaults to `client_secret_post` but Authelia defaulted to `client_secret_basic`                                                                                                                                                                                                                                                                                                                 | Added `token_endpoint_auth_method: client_secret_post` to Grafana OIDC client in `authelia-configuration.yml.j2`                                                                                                                                                                                                                                                                                                                                          |
| Navidrome middleware `@docker` not found                                                          | Traefik could not resolve `authelia@docker` because Authelia is on `web` network but middleware labels are on Authelia container                                                                                                                                                                                                                                                                         | Changed `authelia@docker` → `authelia@file` and `authelia-basicauth@docker` → `authelia-basicauth@file` for all Navidrome routers                                                                                                                                                                                                                                                                                                                         |
| Navidrome Subsonic rule `\&\&` parsing error                                                      | Heredoc escaping in bash caused `&&` to become `\&\&`                                                                                                                                                                                                                                                                                                                                                    | Used `sed` to fix escaped backslashes, recreated Navidrome container                                                                                                                                                                                                                                                                                                                                                                                      |
| Traefik metrics unreachable from Prometheus                                                       | Traefik was only on `web` network, Prometheus on `knowledge` network                                                                                                                                                                                                                                                                                                                                     | Added `knowledge` network to Traefik service in docker-compose.yml                                                                                                                                                                                                                                                                                                                                                                                        |
| cAdvisor requires privileged mode                                                                 | Needs host-level access for container metrics                                                                                                                                                                                                                                                                                                                                                            | Added `privileged: true`, `/dev/kmsg` device, and host filesystem mounts                                                                                                                                                                                                                                                                                                                                                                                  |
| Grafana dashboard JSON transfer failed                                                            | Heredoc in bash failed with JSON special characters                                                                                                                                                                                                                                                                                                                                                      | Used `scp` to transfer JSON files directly instead of heredoc                                                                                                                                                                                                                                                                                                                                                                                             |
| Grafana dashboards show no data (Syncthing, Docker Containers, Traefik)                           | 3 issues: (1) Prometheus datasource provisioned without explicit `uid`, so auto-generated UID unknown to dashboards; (2) Syncthing dashboard used string `"Prometheus"` instead of object `{"type": "prometheus", "uid": "..."}`; (3) Docker Containers & Traefik dashboards used `DS_PROMETHEUS` template variable with `current: {}` (unpopulated) which doesn't auto-resolve during file provisioning | Added `uid: prometheus` to Prometheus datasource provisioning in `main.yml`; changed Syncthing dashboard datasource references to `{"type": "prometheus", "uid": "prometheus"}`; removed `DS_PROMETHEUS` template variable from Docker Containers & Traefik dashboards                                                                                                                                                                                    |
| OpenClaw inaccessible (claw.les12.fr)                                                             | OpenClaw container starts but embedded agent fails with "No API key found for provider" — no AI provider API keys configured in the container's environment                                                                                                                                                                                                                                              | Added `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `DEEPSEEK_API_KEY` env vars to `docker-compose.yml.j2` and `stack.env.j2`; added `openai_api_key`, `anthropic_api_key`, and `deepseek_api_key` to vault + group_vars; mounted `{{ stack_dir }}/openclaw/config:/home/node/.openclaw` to persist OpenClaw config/auth profiles across restarts                                                                                                            |
| OpenClaw embedded agent still fails after env vars added (no onboarding)                          | OpenClaw Docker image requires `auth-profiles.json` and `openclaw.json` to be pre-configured; env vars alone aren't enough because the gateway doesn't run `onboard` automatically                                                                                                                                                                                                                       | Created `openclaw-auth-profiles.json.j2` template (renders to `agents/main/agent/auth-profiles.json` with API keys for openai, anthropic, deepseek); created `openclaw.json.j2` template (gateway config with model defaults, gateway auth token, agent settings); added `openclaw_gateway_token` to vault for gateway auth; added template rendering tasks to `deploy_stack`                                                                             |
| OpenClaw session file corruption (`session file changed while embedded prompt lock was released`) | Bind mount at `/home/node/.openclaw` exposes raw ext4 FS semantics where `rename()` changes inode numbers. OpenClaw's session management compares `stat().ino` between lock acquisitions, detects the inode change, and throws. Docker named volumes use overlay2 which provides stable inode numbers across renames within the same layer.                                                              | Replaced bind mount with Docker named volume `openclaw_state` for `/home/node/.openclaw` (runtime state). Config files now mounted as read-only bind mount at `/home/node/.openclaw-config:ro`. Init script copies configs into named volume on container start when checksum changes.                                                                                                                                                                    |
| Traefik fails to start: "lookup tcp/8082\\\": unknown port"                                       | Escaped quotes `\"` in Jinja2 template produced literal `\"` characters in rendered `address` fields, causing Traefik to parse `":8082"` as invalid port                                                                                                                                                                                                                                                 | Removed `\` escaping from `address` fields in `traefik.yml.j2` — all entrypoints now use plain `":port"` format                                                                                                                                                                                                                                                                                                                                           |
| Syncthing XML parse error on startup (`invalid character entity &S`)                              | Syncthing generated its own API key with XML-unsafe characters (`&`, `%`, `$`) when rewriting its config.xml on first run. The placeholder `SYNCTHING_API_KEY` was already replaced by Syncthing, so the `openclaw_integration` task couldn't find it to inject a safe key.                                                                                                                              | (1) Template `syncthing-config.xml.j2` now uses `{{ syncthing_api_key }}` (generated alphanumeric key) instead of placeholder `SYNCTHING_API_KEY`. (2) Key is generated and persisted in `deploy_stack` before template rendering. (3) `openclaw_integration/syncthing.yml` regex changed from literal `SYNCTHING_API_KEY` to `[^<]+` to match any existing key value. (4) Key generation uses `special=false` for alphanumeric-only output safe for XML. |
| Vikunja CalDAV returns HTML instead of CalDAV XML                                                 | Traefik routing for `/dav/*` was missing — requests hit the main Vikunja router (OIDC-protected) and returned the SPA frontend instead of CalDAV responses                                                                                                                                                                                                                                               | Added `vikunja-dav` Traefik router with `PathPrefix(/dav/)`, priority=100, no Authelia middleware. CalDAV clients (DAVx⁵, Tasks.org, OpenTasks) auth directly against Vikunja using username + password or CalDAV token. CalDAV is enabled by default in Vikunja (`service.enablecaldav: true`).                                                                                                                                                          |
| Vikunja CalDAV auth fails (401) for OIDC users                                                    | User `theo` is created via OIDC (Authelia) and cannot use local password auth — Vikunja rejects local login for OIDC-managed accounts with "This account is managed by a third-party authentication provider"                                                                                                                                                                                            | Created dedicated local user `caldav` via `vikunja user create --username caldav --password ...` in `deploy_stack` role. Traefik routing for `/dav/*` bypasses Authelia. The `caldav` user must be shared to relevant projects to see tasks. Password stored in vault as `vikunja_caldav_password`.                                                                                                                                                       |

## Service URLs

| Service   | URL                      | Auth Method             |
| --------- | ------------------------ | ----------------------- |
| Authelia  | https://auth.les12.fr    | Direct login            |
| Traefik   | https://traefik.les12.fr | Forward auth (Authelia) |
| Vikunja   | https://tasks.les12.fr   | OIDC (Authelia)         |
| Navidrome | https://music.les12.fr   | Forward auth (Authelia) |
| Syncthing | https://sync.les12.fr    | Forward auth (Authelia) |
| OpenClaw  | https://claw.les12.fr    | Forward auth (Authelia) |
| Grafana   | https://grafana.les12.fr | OIDC (Authelia)         |

## Deployment Workflow

1. Fresh Ubuntu 24 install → note IP
2. Update `ansible/inventory.ini` if IP changed
3. `sh init.sh` — bootstrap as root (asks for vault password + root SSH password)
4. `sh run.sh` — full config as admin
5. (Optional) `sh run-initial-backup.sh` — run initial backup after deployment
6. Verify: `sudo docker ps`, test all URLs
7. Verify backups: `ls /var/backups/server-config/`

## Important Notes

- **Vault must be encrypted before committing**: `ansible-vault encrypt ansible/group_vars/vps.vault.yml`
- SSH stays on port 22 (socket activation)
- Grafana uses `client_secret_post` for OIDC token exchange (not the default `client_secret_basic`)
- Permission fixes run twice: once before stack start (for bind mounts), once after (for Docker volumes)
- **3 Docker networks**: `web` (Traefik-facing), `internal` (DB/internal), `knowledge` (service-to-service API calls)
- **OpenClaw** accesses Vikunja via `knowledge` network at `http://vikunja:3456` using `VIKUNJA_API_TOKEN`
- **Syncthing** exposes Prometheus metrics at port 8384 (debugging mode enabled), scraped by Prometheus on `knowledge` network
- **Backups** run daily at 04:00 via cron, stored in `/var/backups/server-config/` with 30-day retention
- **Backup skip tag**: Use `--skip-tags initial-backup` to avoid running the initial backup on every playbook run

## openclaw_integration Role Details

### Purpose

Second-phase integration that connects all services to OpenClaw for runtime service-to-service communication. Runs after `deploy_stack` (all services are up).

### Tasks

#### Prometheus (`tasks/prometheus.yml`)

- Creates Prometheus alerting rules directory and renders `prometheus-alerts.yml.j2` (ServiceDown, HighDiskUsage, HighMemoryUsage, ContainerRestarting alerts)
- Adds `rule_files` directive to `prometheus.yml` if not present
- Reloads Prometheus config via `/-/reload` API if changed
- Records endpoint at `{{ stack_dir }}/openclaw/config/prometheus-endpoint.json`

#### Loki (`tasks/loki.yml`)

- Adds `knowledge` network to Loki in docker-compose.yml for service-to-service access
- Records endpoint at `{{ stack_dir }}/openclaw/config/loki-endpoint.json` (no auth, no tenant ID)

#### Grafana (`tasks/grafana.yml`)

- Creates Grafana contact points provisioning directory
- Renders `grafana-contact-point.yaml.j2` — webhook Contact Point pointing to `http://openclaw:8080/webhook/grafana`
- Renders `grafana-notification-policy.yaml.j2` — Notification Policy routing all alerts through the OpenClaw Contact Point
- Adds `knowledge` network to Grafana in docker-compose.yml so it can reach OpenClaw
- Records endpoint at `{{ stack_dir }}/openclaw/config/grafana-endpoint.json`

#### Syncthing (`tasks/syncthing.yml`)

- Generates a random 40-char API key via `community.general.random_string`
- Persists key to `{{ stack_dir }}/syncthing/config/syncthing-api-key.txt`
- Updates Syncthing `config.xml` replacing the placeholder `SYNCTHING_API_KEY` with the real key
- Records endpoint + API key at `{{ stack_dir }}/openclaw/config/syncthing-endpoint.json`

#### Vikunja (`tasks/vikunja.yml`)

- Verifies Vikunja API is reachable via `/api/v1/info`
- Validates `vikunja_api_token` by calling `/api/v1/user` with Bearer auth
- Records endpoint + API token at `{{ stack_dir }}/openclaw/config/vikunja-endpoint.json`

#### Navidrome (`tasks/navidrome.yml`)

- Records endpoint at `{{ stack_dir }}/openclaw/config/navidrome-endpoint.json` (Subsonic-compatible API)

#### Signal (`tasks/signal.yml`)

- Records endpoint at `{{ stack_dir }}/openclaw/config/signal-endpoint.json` (REST API with register, verify, send, receive, devices, and health endpoints)

#### Runtime Bridge Config (`tasks/integrations.yml`)

- Creates `/etc/openclaw/` directory
- Renders `integrations.yaml.j2` to `/etc/openclaw/integrations.yaml` — single YAML file containing all endpoints, API keys, and credentials for every service
- Copies to `{{ stack_dir }}/openclaw/config/integrations.yaml` for container access

### Templates

- `integrations.yaml.j2` — Master runtime bridge config with all service URLs, auth, and endpoints
- `grafana-contact-point.yaml.j2` — Grafana webhook Contact Point for OpenClaw
- `grafana-notification-policy.yaml.j2` — Grafana Notification Policy routing alerts to OpenClaw
- `prometheus-alerts.yml.j2` — Prometheus alerting rules (ServiceDown, HighDiskUsage, etc.)

## Cybersecurity & Observability Stack

### Architecture Overview

The cybersecurity stack adds 6 new Ansible roles to the existing infrastructure, transforming the VPS from basic monitoring to a comprehensive security observability platform.

```
┌─────────────────────────────────────────────────────────────────┐
│                      TRAEFIK (Reverse Proxy)                     │
│  rate-limit | security-headers | circuit-breaker | authelia     │
└───────┬─────────┬──────────┬──────────┬──────────┬──────────────┘
        │         │          │          │          │
   ┌────▼────┐ ┌──▼───┐ ┌───▼────┐ ┌───▼───┐ ┌───▼────┐ ┌───▼───┐
   │ Vikunja │ │Grafana│ │Navidr. │ │Syncth.│ │OpenClaw│ │Authel.│
   └────────┘ └──┬───┘ └────────┘ └───────┘ └───┬────┘ └───────┘
                  │                              │
    ┌─────────────┼──────────────────────────────┼──────────────┐
    │            knowledge network               │              │
    │  ┌──────────▼──────────┐   ┌──────────────▼──────┐       │
    │  │    Prometheus       │   │       Loki          │       │
    │  │  - node_exporter    │   │  - System logs      │       │
    │  │  - cAdvisor         │   │  - Docker logs      │       │
    │  │  - Syncthing        │   │  - Wazuh alerts     │       │
    │  │  - Traefik          │   │  - Lynis audits     │       │
    │  │  - Alerting rules   │   │  - UFW/fail2ban     │       │
    │  └──────────┬──────────┘   └──────────┬──────────┘       │
    │             │                         │                  │
    │             └─────────┬───────────────┘                  │
    │                       │                                  │
    │              ┌────────▼────────┐                         │
    │              │    Grafana      │                         │
    │              │  Security Dashboards                      │
    │              │  (7 provisioned)│                         │
    │              └─────────────────┘                         │
    │                                                          │
    │  ┌──────────────┐  ┌──────────────────┐                 │
    │  │ Wazuh Manager│  │  Lynis (host)    │                 │
    │  │  - FIM       │  │  - Daily audit   │                 │
    │  │  - Rootcheck │  │  - Loki push     │                 │
    │  │  - Syslog    │  │  - Trend tracking│                 │
    │  └──────┬───────┘  └────────┬─────────┘                 │
    │         │                   │                            │
    │         └───────────────────┼────────────────────────────┘
    │                             │
    │                    ┌────────▼────────┐
    │                    │   Promtail      │
    │                    │  (log shipper)  │
    │                    └─────────────────┘
    └──────────────────────────────────────────────────────────┘
```

### Architecture Decisions & Tradeoffs

#### 1. Wazuh: Lightweight (Manager Only) vs Full Stack

| Decision                                             | Chosen | Alternative                                                                                 |
| ---------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------- |
| **Full Wazuh stack** (Manager + Indexer + Dashboard) | ❌     | Would require ~6GB RAM. Indexer (Elasticsearch) alone needs 4GB. Overkill for single VPS.   |
| **Manager only + Loki + Grafana**                    | ✅     | ~1GB RAM. Alerts stored in Loki, visualized in Grafana. Simpler, lighter, no Elasticsearch. |

**Tradeoff**: Lose Wazuh's built-in dashboards and Kibana-based exploration. Gain simpler maintenance and unified visualization in Grafana.

#### 2. Lynis vs OpenSCAP vs Wazuh FIM

| Tool          | Role                                | Resource Usage         | Schedule      |
| ------------- | ----------------------------------- | ---------------------- | ------------- |
| **Lynis**     | Host-level compliance audit         | Low (~50MB RAM)        | Daily (03:00) |
| **Wazuh FIM** | Real-time file integrity monitoring | Medium (~100MB RAM)    | Continuous    |
| **OpenSCAP**  | Full compliance scanning            | High (~200MB RAM + DB) | Not deployed  |

**Decision**: Lynis for scheduled audits + Wazuh FIM for continuous monitoring. OpenSCAP is too heavy for a personal VPS.

#### 3. Prometheus node_exporter vs cAdvisor

- **node_exporter**: Host-level metrics (CPU, RAM, disk, network, processes) — essential for security
- **cAdvisor**: Container-level metrics (per-container CPU, memory, network, disk I/O) — already deployed
- **Both**: Needed. They expose different metric sets.

#### 4. auditd: Optional

auditd generates significant log volume (~100MB/day on an active system). For a personal VPS, Lynis + Wazuh + Prometheus provide sufficient security coverage without auditd overhead. Enable only if detailed audit trails are needed for compliance.

### Role Descriptions

#### `security_audit` — Lynis Automated Auditing

- **Purpose**: Automated daily security audits with Loki integration
- **Installation**: `apt install lynis` (official Ubuntu repos)
- **Schedule**: systemd timer, daily at 03:00
- **Output**: JSON report → Loki push → Grafana dashboard
- **Key files**:
  - `templates/run-lynis-audit.sh.j2` — Audit script (runs Lynis, parses JSON, pushes to Loki)
  - `templates/custom-profile.prf.j2` — Custom Lynis profile (skips irrelevant tests for Docker VPS)
  - `templates/lynis-audit.service.j2` — Systemd service unit
  - `templates/lynis-audit.timer.j2` — Systemd timer (daily 03:00)
- **Tags**: `security_audit`, `lynis`, `initial-audit`
- **Variables**: `lynis_report_dir`, `lynis_retention_days`, `run_initial_audit`

#### `wazuh` — Lightweight Wazuh Deployment

- **Purpose**: Security monitoring with FIM, rootkit detection, and log analysis
- **Deployment**: Docker container (manager only) + optional host agent
- **Architecture**: Single container, no indexer, no dashboard
- **Integration**: Alerts → syslog → Promtail → Loki → Grafana
- **Key files**:
  - `templates/ossec.conf.j2` — Wazuh manager config (FIM, rootcheck, syslog output)
  - `templates/agent-ossec.conf.j2` — Wazuh agent config (host-level monitoring)
  - `templates/docker-compose-wazuh.yml.j2` — Docker Compose for Wazuh manager
  - `handlers/main.yml` — Restart Wazuh agent handler
- **Tags**: `wazuh`, `wazuh_agent`
- **Variables**: `wazuh_agent_enabled`, `wazuh_vulnerability_detector`, `wazuh_manager_memory_limit`

#### `loki_security` — Enhanced Log Pipeline

- **Purpose**: Enhanced Promtail/Loki config for security log ingestion
- **Key improvements over existing config**:
  - Structured pipeline stages for auth.log, syslog, kern.log
  - Dedicated scrape jobs for UFW logs, fail2ban logs, Traefik access logs
  - JSON parsing for Wazuh alerts
  - Loki alerting rules for security events (SSH brute force, Wazuh alerts, firewall blocks)
  - Proper labels: `host`, `service`, `severity`, `container`, `security_source`
- **Key files**:
  - `templates/promtail-security-config.yml.j2` — Enhanced Promtail config (8 scrape jobs)
  - `templates/loki-security-config.yml.j2` — Enhanced Loki config (retention, limits, ruler)
  - `templates/loki-alerting-rules.yml.j2` — Loki alerting rules for security events
- **Tags**: `loki_security`, `monitoring`
- **Note**: Replaces the existing `promtail-config.yml.j2` and `loki-config.yml.j2` from deploy_stack

#### `prometheus_security` — Enhanced Metrics

- **Purpose**: Add node_exporter, security alerting rules, recording rules
- **New targets**: node_exporter (host metrics on port 9100)
- **Key files**:
  - `templates/prometheus-security.yml.j2` — Enhanced Prometheus config with node_exporter
  - `templates/prometheus-security-alerts.yml.j2` — Security alerting rules (disk, memory, CPU, network, containers)
  - `templates/prometheus-security-recording.yml.j2` — Recording rules for dashboard performance
  - `templates/docker-compose-node-exporter.yml.j2` — node_exporter Docker Compose
- **Tags**: `prometheus_security`, `monitoring`, `node_exporter`
- **Alerts**: HighDiskUsage, CriticalDiskUsage, HighMemoryUsage, HighCPUUsage, NodeDown, UnexpectedReboot, TimeSkew, HighNetworkTraffic, ContainerRestarting, ContainerHighMemory, ServiceDown, PrometheusTargetMissing

#### `grafana_security` — Security Dashboards

- **Purpose**: Provision 7 security-focused Grafana dashboards
- **Folder**: "Security" in Grafana
- **Dashboards**:

| Dashboard                | UID                        | Data Source       | Focus                         |
| ------------------------ | -------------------------- | ----------------- | ----------------------------- |
| VPS Security Overview    | `vps-security-overview`    | Prometheus + Loki | Single pane of glass          |
| SSH Attack Monitor       | `ssh-attack-monitor`       | Loki              | Brute-force tracking          |
| Wazuh Security Alerts    | `wazuh-alerts`             | Loki              | Wazuh alert trends            |
| Lynis Audit Trends       | `lynis-audit-trends`       | Loki              | Hardening score over time     |
| Authentication Failures  | `auth-failures`            | Loki              | Auth failures across services |
| Container Security       | `container-security`       | Prometheus + Loki | Docker security events        |
| Traefik Access Anomalies | `traefik-access-anomalies` | Loki              | HTTP anomaly detection        |

- **Tags**: `grafana_security`, `monitoring`
- **Files**: `files/dashboards/*.json` (7 dashboard JSON files)

#### `secure_networking` — Network & Docker Security

- **Purpose**: Enhanced firewall, Docker daemon security, Traefik security middlewares
- **Key files**:
  - `templates/docker-daemon.json.j2` — Docker daemon security config (userland-proxy: false, iptables: true, live-restore: true)
  - `templates/ufw-rules.sh.j2` — Enhanced UFW rules (rate limiting, Docker network awareness)
  - `templates/traefik-security-middlewares.yml.j2` — Traefik security middlewares (rate-limit, security-headers, circuit-breaker, IP whitelist)
  - `templates/auditd-rules.j2` — Auditd rules (optional, disabled by default)
- **Tags**: `secure_networking`, `security`, `ufw`, `traefik`
- **Middlewares**: `rate-limit` (100 req/min), `rate-limit-strict` (10 req/min), `security-headers` (HSTS, CSP, XSS), `internal-whitelist`, `circuit-breaker`, `security-chain`, `auth-security-chain`

### Deployment Order

The roles are deployed in this order in `site.yml`:

1. **secure_networking** — Docker security config + UFW rules + Traefik middlewares (before any containers are deployed)
2. **loki_security** — Enhanced Promtail/Loki config (overwrites existing configs from deploy_stack)
3. **prometheus_security** — node_exporter + enhanced Prometheus config
4. **grafana_security** — Security dashboards (adds to existing Grafana provisioning)
5. **security_audit** — Lynis installation and initial audit
6. **wazuh** — Wazuh manager container + optional agent (last, because it depends on Loki for log storage)

### Selective Execution

Run specific security roles independently:

```bash
# Run only Lynis audit
sh run.sh --tags lynis

# Run only Wazuh deployment
sh run.sh --tags wazuh

# Run only security monitoring (skip app stack)
sh run.sh --tags monitoring

# Run everything except Wazuh
sh run.sh --skip-tags wazuh

# Run initial Lynis audit only
sh run.sh --tags initial-audit

# Full security stack only
sh run.sh --tags security_audit,wazuh,loki_security,prometheus_security,grafana_security,secure_networking
```

### Resource Usage Estimates

| Component                | RAM          | CPU          | Disk                   | Notes                       |
| ------------------------ | ------------ | ------------ | ---------------------- | --------------------------- |
| Wazuh Manager            | 512MB-1GB    | 0.5-1.0 core | 2-5GB                  | Depends on log volume       |
| Wazuh Agent              | ~100MB       | Minimal      | ~100MB                 | Optional                    |
| Prometheus node_exporter | ~50MB        | Minimal      | ~100MB                 | Very lightweight            |
| Lynis (during audit)     | ~50MB        | Burst 30s    | ~10MB/report           | Runs once daily             |
| Promtail                 | ~30MB        | Minimal      | ~50MB (positions)      | Always running              |
| Enhanced Loki            | ~200MB       | Minimal      | Configurable retention | Increased from basic config |
| **Total additional**     | **~1-1.5GB** | **~1 core**  | **~3-6GB**             |                             |

**Comparison with full Wazuh stack**: Full Wazuh (Manager + Indexer + Dashboard) would require ~6GB RAM minimum. Our lightweight approach saves ~4-5GB RAM by replacing Elasticsearch with Loki and Kibana with Grafana.

### Security Labels in Loki

All security logs are labeled with `security_source` for easy querying:

| security_source | Source                     | Example Query                  |
| --------------- | -------------------------- | ------------------------------ |
| `system`        | auth.log, syslog, kern.log | `{security_source="system"}`   |
| `docker`        | Docker container logs      | `{security_source="docker"}`   |
| `wazuh`         | Wazuh alerts               | `{security_source="wazuh"}`    |
| `lynis`         | Lynis audit results        | `{security_source="lynis"}`    |
| `firewall`      | UFW logs                   | `{security_source="firewall"}` |
| `fail2ban`      | fail2ban logs              | `{security_source="fail2ban"}` |
| `traefik`       | Traefik access logs        | `{security_source="traefik"}`  |

### Alerting Architecture

Two-layer alerting:

1. **Prometheus alerts** (metric-based): High CPU, disk full, service down, container restarts
   - Rules in: `prometheus-security-alerts.yml.j2`
   - Evaluated: Every 15s
   - Sent to: Alertmanager (if configured)

2. **Loki alerts** (log-based): SSH brute force, Wazuh alerts, firewall blocks, auth failures
   - Rules in: `loki-alerting-rules.yml.j2`
   - Evaluated: Every 1m
   - Sent to: Prometheus Alertmanager

### Vault Requirements

Add these secrets to `ansible/group_vars/vps.vault.yml`:

```yaml
# Wazuh
wazuh_api_password: "your-wazuh-api-password" # For Wazuh API access

# Wazuh agent registration (if agent enabled)
wazuh_agent_registration_password: "your-registration-password"
```

### Known Issues & Resolutions (Security Stack)

| Issue                                                         | Cause                                                                       | Fix                                                                                   |
| ------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Wazuh manager fails to start                                  | Port 514 already in use (systemd-resolved)                                  | Disable systemd-resolved or change syslog port to 1514                                |
| Lynis audit fails on first run                                | `jq` not installed                                                          | Ensure `jq` is in `common` role's package list                                        |
| Promtail can't read /var/log/auth.log                         | Permission denied (Promtail runs as Docker user)                            | Add `--user=root` to Promtail container or use `cap_add: DAC_READ_SEARCH`             |
| Loki ruler can't find alerting rules                          | Rules directory not mounted in Loki container                               | Ensure `{{ stack_dir }}/loki/rules:/loki/rules` volume mount in docker-compose.yml.j2 |
| Grafana dashboards show "Datasource not found"                | Dashboard JSON references datasource UID that doesn't match provisioned UID | Verify datasource UIDs in provisioning configs (loki, prometheus)                     |
| node_exporter can't read host metrics                         | PID namespace isolation                                                     | Ensure `pid_mode: host` in docker-compose-node-exporter.yml.j2                        |
| Wazuh agent can't connect to manager                          | Docker network isolation                                                    | Ensure host port 1514 is mapped in docker-compose-wazuh.yml.j2                        |
| Traefik rate-limit middleware causes 429 for legitimate users | Rate limit too low                                                          | Increase `average` from 100 to 200 or whitelist known IPs                             |

### Loki Datasource UID Fix

When deploying the security stack for the first time, Grafana may have auto-generated a Loki datasource with a random UID (e.g., `P8E80F9AEF21F6940`) instead of the provisioned `loki` UID. This causes all security dashboards to show "No data" because they reference `uid: loki`.

**Problem**: Grafana provisioning does NOT update existing datasources. If a datasource with the same name ("Loki") already exists, the provisioning config is ignored.

**Fix** (run on VPS):

```bash
# 1. Find the Loki datasource UID
LOKI_UID=$(sudo docker exec stack-grafana-1 curl -s http://admin:admin123@localhost:3000/api/datasources/name/Loki | jq -r '.uid')
echo "Old Loki UID: $LOKI_UID"

# 2. Delete the old Loki datasource
sudo docker exec stack-grafana-1 curl -s -X DELETE "http://admin:admin123@localhost:3000/api/datasources/uid/$LOKI_UID"

# 3. Restart Grafana to reprovision with correct UID
sudo docker restart stack-grafana-1

# 4. Verify the new datasource
sudo docker exec stack-grafana-1 curl -s http://admin:admin123@localhost:3000/api/datasources/name/Loki | jq '.uid'
# Should output: "loki"
```

### Future Enhancements

1. **Alertmanager**: Deploy Prometheus Alertmanager for email/webhook notifications
2. **Wazuh Vulnerability Detector**: Enable `wazuh_vulnerability_detector: true` for CVE scanning
3. **Crowdsec**: Alternative to fail2ban with community blocklists (lighter, more effective)
4. **Docker Bench Security**: Automated Docker CIS benchmark scanning (can be added as a periodic task)
5. **Wazuh Indexer**: If log volume grows significantly, add Wazuh indexer for long-term storage
6. **Grafana OnCall**: For alert notification routing (if multiple admins)
