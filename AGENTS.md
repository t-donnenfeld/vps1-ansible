# AGENTS.md — server-config

## Project Overview

Ansible-based server configuration for a personal VPS (Ubuntu 24) hosting a Docker Compose stack with:

- **Traefik** (reverse proxy + Let's Encrypt, Prometheus metrics on port 8082)
- **Authelia** (SSO/OIDC provider)
- **PostgreSQL** (shared database)
- **Vikunja** (task management, OIDC via Authelia)
- **Jellyfin** (media streaming, forward auth via Authelia)
- **Nextcloud** (cloud storage & collaboration, OIDC via Authelia) → **Replaced by OpenCloud (ownCloud Infinite Scale)**
- **Syncthing** (Obsidian vault synchronization, forward auth via Authelia)
- **OpenClaw** (AI orchestration/intelligence layer, forward auth via Authelia) — **Installed directly on the host** (not in Docker)
- **Signal** (Messaging API via signal-cli-rest-api, internal service only, no public access)
- **rmfakecloud** (Self-hosted reMarkable cloud sync server, forward auth via Authelia)
- **Pterodactyl** (game server panel + Wings daemon, hosting an ARK: Survival Evolved server)
- **WireGuard** (VPN server, `wg0`, UDP 51820)
- **bgutil-provider** (yt-dlp proof-of-origin token provider, internal only)
- **web-phd** (PhD Research Hub — Next.js journal/calendar + MLflow + Quartz, forward auth via Authelia)

## Architecture

- Single VPS (`palma`, 185.196.20.127)
- SSH on port 22 (default), key-based auth only
- All services behind Traefik with subdomains under `les12.fr`
- Authelia provides both forward auth (Jellyfin, Syncthing, OpenClaw) and OIDC (Vikunja, OpenCloud)
- Docker Compose stack managed via systemd unit (`stack.service`)
- Obsidian vaults stored at `/opt/services/shared/obsidian/vaults` for Syncthing synchronization
- Pterodactyl panel (second Compose project) uses the `stack_web` network via `external: true`
- WireGuard VPN runs on the host (`wg0`), bgutil-provider runs as a standalone container

### Docker Networks

| Network     | Purpose                           | Services                                                                           |
| ----------- | --------------------------------- | ---------------------------------------------------------------------------------- |
| `web`       | Traefik-facing, public access     | Traefik, Authelia, Vikunja, Jellyfin, Syncthing, OpenCloud, rmfakecloud |
| `internal`  | Backend DB/internal communication | Postgres, Authelia, Vikunja, OpenCloud |
| `knowledge` | Service-to-service (API calls)    | Traefik, Vikunja, Syncthing, Signal, OpenCloud |

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
  4. `secure_networking` — Docker daemon security, enhanced UFW rules, Traefik security middlewares (rate limiting, security headers), auditd (optional)
  5. `wireguard` — WireGuard VPN server (`wg0`, UDP 51820)
  6. `openclaw` — Node.js install, npm install OpenClaw, systemd service + Traefik file router + UFW rules
  7. `rmapi` — Download and install rmapi CLI binary, configure RMAPI_HOST env var
  8. `deploy_stack` — Full Docker Compose stack deployment
  9. `backup` — Backup cron job + initial backup
  10. `openclaw_integration` — Service-to-service integration config (endpoints, API keys)
  11. `pterodactyl` — Pterodactyl game panel (panel + wings + MariaDB + Redis)
  12. `bgutil` — yt-dlp proof-of-origin token provider (standalone container)
  13. `web_phd` — PhD Research Hub (Next.js + MLflow + Quartz), cloned from GitHub and deployed behind Authelia
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
- `vikunja_api_token` — API token for OpenClaw integration
- Initial SSH password for bootstrap

## deploy_stack Role Details

### Tasks (`tasks/main.yml`)

1. Create directory structure for all services
2. Generate Authelia OIDC private key (RSA 4096, persisted)
3. Hash OIDC client secret for Vikunja (pbkdf2-sha512, persisted)
4. Render all config templates (docker-compose.yml, traefik, authelia, vikunja, etc.)
5. Validate Authelia config with `docker run authelia config validate`
6. Fix volume permissions for UIDs 1000 (Vikunja, Jellyfin, Syncthing, OpenClaw)
7. Install systemd unit + start stack

### Templates

- `docker-compose.yml.j2` — All services with networks (`web`, `internal`, `knowledge`), volumes, Traefik labels
- `traefik.yml.j2` — Static config (entrypoints, providers, Let's Encrypt)
- `middlewares.yml.j2` — Authelia forward auth + BasicAuth + HTTPS redirect + header stripping
- `authelia-configuration.yml.j2` — Full Authelia config with OIDC clients (Vikunja, Jellyfin, OpenCloud)
- `authelia-users_database.yml.j2` — Single admin user with argon2id password hash
- `vikunja-config.yml.j2` — OIDC auth via Authelia
- `01-create-dbs.sql.j2` — Postgres init script (authelia + vikunja + opencloud DBs)
- `stack.env.j2` — Shared env vars (DB passwords, SMTP, OIDC secret, Vikunja API token)
- `stack.service.j2` — Systemd unit for the stack
- `syncthing-config.xml.j2` — Initial Syncthing config (insecureSkipHostcheck, GUI on 0.0.0.0:8384, obsidian vaults folder)

## backup Role Details

### Tasks (`tasks/main.yml`)

1. Create backup directory structure
2. Render backup shell script
3. Install cron job (daily at 04:00)
4. Run initial backup (tagged `initial-backup`)

### Backup Script (`backup.sh.j2`)

- **PostgreSQL**: `pg_dumpall` via `docker compose exec`, gzipped
- **Obsidian vaults**: tar.gz archive
- **Docker volumes**: pgdata, jellyfin_config, jellyfin_cache, signal_data, opencloud_data, opencloud_config, rmfakecloud_data
- **Stack config**: tar.gz (excluding large data dirs already backed up as volumes)
- **Retention**: backups older than `backup_retention_days` (default: 30) pruned
- Output directory: `/var/backups/server-config/`

## Completed Cleanup Tasks

The following cleanup tasks from the monitoring stack removal have been completed:

1. **Re-integrated `secure_networking` role** into `site.yml` (after `docker`, before `openclaw`)
2. **Deleted orphaned roles** — `openclaw_build` (old Docker build approach) and `syncthing` (standalone role, superseded by `deploy_stack`)
3. **Cleaned up unused variables** in `vps.yml`: removed `subdomain_opencloud` (duplicate of `subdomain_cloud`) and `openclaw_version` (unused — role uses `openclaw_npm_version` instead)
4. **Cleaned up vault**: removed `grafana_oidc_client_id`, `grafana_oidc_client_secret`, `grafana_admin_password`

| Issue                                                                                             | Cause                                                                                                                                                                                                                                                                                                                                                                                                    | Fix                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SSH connection lost during init                                                                   | SSH socket restart                                                                                                                                                                                                                                                                                                                                                                                       | Removed port change (stays on 22)                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Jellyfin permission denied                                                                       | Volume owned by root                                                                                                                                                                                                                                                                                                                                                                                     | `chown -R 1000:1000`                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Vikunja permission denied                                                                         | Bind mount dir owned by root                                                                                                                                                                                                                                                                                                                                                                             | `chown -R 1000:1000`                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| apt lock contention on first run                                                                  | unattended-upgrades at boot                                                                                                                                                                                                                                                                                                                                                                              | Added `retries: 5` / `delay: 10`                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Permission fix ineffective                                                                        | Ran before volumes existed                                                                                                                                                                                                                                                                                                                                                                               | Moved after `Start stack service`                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Traefik forward auth DoS warning                                                                  | `maxResponseBodySize` not configured on Authelia forward auth middleware                                                                                                                                                                                                                                                                                                                                 | Added `maxResponseBodySize: 1048576` to middleware config                                                                                                                                                                                                                                                                                                                                                                                                 |
| Navidrome middleware `@docker` not found                                                          | Traefik could not resolve `authelia@docker` because Authelia is on `web` network but middleware labels are on Authelia container                                                                                                                                                                                                                                                                         | Changed `authelia@docker` → `authelia@file` and `authelia-basicauth@docker` → `authelia-basicauth@file` for all Navidrome routers                                                                                                                                                                                                                                                                                                                         |
| Navidrome Subsonic rule `\&\&` parsing error                                                      | Heredoc escaping in bash caused `&&` to become `\&\&`                                                                                                                                                                                                                                                                                                                                                    | Used `sed` to fix escaped backslashes, recreated Navidrome container                                                                                                                                                                                                                                                                                                                                                                                      |
| Jellyfin initial setup (replaces Navidrome)                                                        | Navidrome was replaced by Jellyfin for media streaming. Jellyfin uses Authelia forward auth.                                                                                                                                                                                                                                                                                                             | Replaced Navidrome service with Jellyfin in docker-compose, updated all configs, removed Navidrome references.                                                                                                                                                                                                                                                                                                       |
| OpenClaw inaccessible (claw.les12.fr)                                                             | OpenClaw container starts but embedded agent fails with "No API key found for provider" — no AI provider API keys configured in the container's environment                                                                                                                                                                                                                                              | Added `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and `DEEPSEEK_API_KEY` env vars to `docker-compose.yml.j2` and `stack.env.j2`; added `openai_api_key`, `anthropic_api_key`, and `deepseek_api_key` to vault + group_vars; mounted `{{ stack_dir }}/openclaw/config:/home/node/.openclaw` to persist OpenClaw config/auth profiles across restarts                                                                                                            |
| OpenClaw embedded agent still fails after env vars added (no onboarding)                          | OpenClaw Docker image requires `auth-profiles.json` and `openclaw.json` to be pre-configured; env vars alone aren't enough because the gateway doesn't run `onboard` automatically                                                                                                                                                                                                                       | Created `openclaw-auth-profiles.json.j2` template (renders to `agents/main/agent/auth-profiles.json` with API keys for openai, anthropic, deepseek); created `openclaw.json.j2` template (gateway config with model defaults, gateway auth token, agent settings); added `openclaw_gateway_token` to vault for gateway auth; added template rendering tasks to `deploy_stack`                                                                             |
| OpenClaw session file corruption (`session file changed while embedded prompt lock was released`) | Bind mount at `/home/node/.openclaw` exposes raw ext4 FS semantics where `rename()` changes inode numbers. OpenClaw's session management compares `stat().ino` between lock acquisitions, detects the inode change, and throws. Docker named volumes use overlay2 which provides stable inode numbers across renames within the same layer. | Replaced bind mount with Docker named volume `openclaw_state` for `/home/node/.openclaw` (runtime state). Config files now mounted as read-only bind mount at `/home/node/.openclaw-config:ro`. Init script copies configs into named volume on container start when checksum changes. |
| OpenClaw health endpoint unreachable after host install (`Connection refused` on `127.0.0.1:8080/health`) | 3 root causes: (1) Systemd service used `OPENCLAW_CONFIG_DIR` env var which is **not recognized** by OpenClaw — the launcher only reads `OPENCLAW_CONFIG_PATH` (file path, not dir). Config file was never found. (2) Gateway `--allow-unconfigured` flag removed in version 2026.6.x — causes `commander` to exit with "unknown flag" error. (3) Config `bind: "lan"` may resolve to a non-loopback interface, making port unreachable on 127.0.0.1. | (1) Changed `OPENCLAW_CONFIG_DIR` → `OPENCLAW_CONFIG_PATH={{ openclaw_install_dir }}/config/openclaw.json` in `openclaw.service.j2`. (2) Removed `--allow-unconfigured` from `ExecStart` — config is externally managed by Ansible, no setup needed. (3) Changed `bind` from `"lan"` to `"127.0.0.1"` in `openclaw.json.j2` for consistent loopback binding. (4) Added debug tasks: binary version check, service status, journalctl logs, `npm list -g openclaw`, and `openclaw gateway --help` capture to diagnose future failures. |
| Traefik fails to start: "lookup tcp/8082\\\": unknown port"                                       | Escaped quotes `\"` in Jinja2 template produced literal `\"` characters in rendered `address` fields, causing Traefik to parse `":8082"` as invalid port                                                                                                                                                                                                                                                 | Removed `\` escaping from `address` fields in `traefik.yml.j2` — all entrypoints now use plain `":port"` format                                                                                                                                                                                                                                                                                                                                           |
| Syncthing XML parse error on startup (`invalid character entity &S`)                              | Syncthing generated its own API key with XML-unsafe characters (`&`, `%`, `$`) when rewriting its config.xml on first run. The placeholder `SYNCTHING_API_KEY` was already replaced by Syncthing, so the `openclaw_integration` task couldn't find it to inject a safe key.                                                                                                                              | (1) Template `syncthing-config.xml.j2` now uses `{{ syncthing_api_key }}` (generated alphanumeric key) instead of placeholder `SYNCTHING_API_KEY`. (2) Key is generated and persisted in `deploy_stack` before template rendering. (3) `openclaw_integration/syncthing.yml` regex changed from literal `SYNCTHING_API_KEY` to `[^<]+` to match any existing key value. (4) Key generation uses `special=false` for alphanumeric-only output safe for XML. |
| Vikunja CalDAV returns HTML instead of CalDAV XML                                                 | Traefik routing for `/dav/*` was missing — requests hit the main Vikunja router (OIDC-protected) and returned the SPA frontend instead of CalDAV responses                                                                                                                                                                                                                                               | Added `vikunja-dav` Traefik router with `PathPrefix(/dav/)`, priority=100, no Authelia middleware. CalDAV clients (DAVx⁵, Tasks.org, OpenTasks) auth directly against Vikunja using username + password or CalDAV token. CalDAV is enabled by default in Vikunja (`service.enablecaldav: true`).                                                                                                                                                          |
| Vikunja CalDAV auth fails (401) for OIDC users                                                    | User `theo` is created via OIDC (Authelia) and cannot use local password auth — Vikunja rejects local login for OIDC-managed accounts with "This account is managed by a third-party authentication provider"                                                                                                                                                                                            | Created dedicated local user `caldav` via `vikunja user create --username caldav --password ...` in `deploy_stack` role. Traefik routing for `/dav/*` bypasses Authelia. The `caldav` user must be shared to relevant projects to see tasks. Password stored in vault as `vikunja_caldav_password`.                                                                                                                                                       |
| Jellyfin SSO-Auth plugin not loading                                                               | Jellyfin 10.10+ requires plugins in **subdirectories** under `/config/plugins/` (e.g., `/config/plugins/SSO Authentication/SSO-Auth.dll`). The `.jellyfin-plugin` sentinel file caches plugin directory scans; also plugins must be in subdirectories, not flat in `/config/plugins/`                                                                                                                     | Created proper plugin directory structure `/config/plugins/SSO Authentication/` with DLLs; removed `.jellyfin-plugin` cache file                                                                                                                                                                                                                                                                                                                           |
| Jellyfin SSO-Auth plugin config not found (404 on redirect)                                        | Plugin reads its configuration from `/config/plugins/configurations/SSO-Auth.xml`, not from `/config/plugins/SSO-Auth.xml`                                                                                                                                                                                                                                                                                | Copied config to `/config/plugins/configurations/SSO-Auth.xml` subdirectory                                                                                                                                                                                                                                                                                                                                                                               |
| Jellyfin OIDC PAR auth fails ("Failed to push authorization parameters")                           | Duende.IdentityModel library (used by SSO-Auth plugin) sends `client_secret_basic` (HTTP Basic Auth) for PAR requests, but Authelia was configured with `token_endpoint_auth_method: client_secret_post`. Also the pbkdf2-sha512 hash in Authelia config didn't match the plaintext secret in the vault.                                                                                                  | Changed `token_endpoint_auth_method` to `client_secret_basic` for Jellyfin OIDC client in Authelia config; regenerated correct pbkdf2-sha512 hash matching the vault secret (`7fK2mN9pQ4rX8vB1wL5zH3jD6gT0yC4aS8eU2oW`)                                                                                                                                                                                                                              |
| Jellyfin SSO-Auth returns 400 "Missing state" on redirect                                          | Expected behavior — requires valid OIDC session state from the initial `/sso/OID/start/authelia` request                                                                                                                                                                                                                                                                                                  | This is normal. Full browser-based OIDC flow works: navigate to Jellyfin → click "Log in with Authelia" → redirect to Authelia → authenticate → redirect back to Jellyfin with session.                                                                                                                                                                                                                                                                 |
| OpenCloud container constantly restarting (`jwt_secret` missing)                                   | OpenCloud (ownCloud Infinite Scale) requires a `jwt_secret` and other mandatory secrets (machine auth API key, transfer secret, service user passwords) to be generated before first startup. These are normally created by `ocis init` but our config didn't run this command.                                                                                                                             | Added `command: ["-c", "ocis init || true; exec ocis server"]` to the opencloud service in docker-compose.yml.j2 (same approach as official ownCloud deployment). Added named volume `opencloud_config:/etc/ocis` to persist the generated `ocis.yaml`. Added `IDM_ADMIN_PASSWORD` env var for first login. Added `opencloud_admin_password` to vault and group_vars. |
| OpenCloud container fails to start (`flag provided but not defined: -c`)                          | `ocis` is a Go binary with no shell. The `command: ["-c", "ocis init ..."]` passes `-c` as an argument to `ocis`, which doesn't recognize it. The container shows help text instead of starting. Also, `ocis init` prompts interactively for insecure mode when `OC_INSECURE: "false"`.                                                                                                                      | Changed to `entrypoint: ["/bin/sh", "-c"]` and `command: ["ocis init --insecure --admin-password ${IDM_ADMIN_PASSWORD} || true; exec ocis server"]`. The `--insecure` flag prevents the interactive prompt. The `--admin-password` flag uses the `IDM_ADMIN_PASSWORD` env var to set the admin password during init. |
| OpenCloud OIDC `invalid_client` error (Client with id 'nextcloud')                               | Stale browser session/OIDC state from when the service was called Nextcloud. The browser cached the OIDC authorization request with the old `nextcloud` client_id, which no longer exists.                                                                              | Clear browser cookies/session for `cloud.les12.fr` and re-authenticate. The Authelia config now has the correct `opencloud` client_id. |
| OpenCloud web UI shows "Missing or invalid config" error (`config.json`)                          | Two root causes: (1) `OC_*` env var prefix was used instead of `OCIS_*` in docker-compose.yml for the opencloud service — ocis v8.x only recognizes `OCIS_*` vars. (2) `OCIS_URL` was missing entirely — the ocis web service uses this to populate the `server` and `themeServer` fields in the dynamically served `/config.json`. Without it, the ownCloud Web SPA receives an empty `server` field and fails Zod schema validation in `announceConfiguration()`. | Changed all `OC_*` env vars to `OCIS_*` equivalents in `docker-compose.yml.j2`: `OC_URL` → `OCIS_URL`, `OC_INSECURE` → `OCIS_INSECURE`, `OC_OIDC_ISSUER` → `OCIS_OIDC_ISSUER`, `OC_EXCLUDE_RUN_SERVICES` → `OCIS_EXCLUDE_RUN_SERVICES`, `OC_LOG_LEVEL` → `OCIS_LOG_LEVEL`, `OC_LOG_PRETTY` → `OCIS_LOG_PRETTY`. Added explicit `OCIS_URL: "https://cloud.les12.fr"` which is the critical missing piece. |
| OpenCloud proxy OIDC requests missing `client_id` (`PROXY_OIDC_CLIENT_ID` silently ignored)       | `PROXY_OIDC_CLIENT_ID` env var is NOT recognized by ocis v8.0.1 binary (confirmed via `strings` analysis of `/usr/bin/ocis`). The proxy OIDC middleware struct does not have a `client_id` field — client_id is only in the Web config. The proxy reads client_id from `OCIS_OIDC_CLIENT_ID` or `WEB_OIDC_CLIENT_ID`. Setting `PROXY_OIDC_CLIENT_ID` had no effect, leaving the proxy's OIDC requests without a client_id. | Removed `PROXY_OIDC_CLIENT_ID` from `docker-compose.yml.j2` (silently ignored). Added `OCIS_OIDC_CLIENT_ID: "{{ opencloud_client_id }}"` which IS recognized by the binary (`OCIS_OIDC_CLIENT_ID;WEB_OIDC_CLIENT_ID`). Kept `PROXY_OIDC_ISSUER` and `PROXY_OIDC_INSECURE` which ARE recognized. |

## Service URLs

| Service   | URL                      | Auth Method                       |
| --------- | ------------------------ | --------------------------------- |
| Authelia  | https://auth.les12.fr    | Direct login                      |
| Traefik   | https://traefik.les12.fr | Forward auth (Authelia)           |
| Vikunja   | https://tasks.les12.fr   | OIDC (Authelia)                   |
| Jellyfin  | https://jelly.les12.fr   | OIDC via SSO-Auth plugin (Authelia) |
| OpenCloud (ownCloud Infinite Scale) | https://cloud.les12.fr | OIDC (Authelia) — Authorization Code + PKCE |
| Syncthing | https://sync.les12.fr    | Forward auth (Authelia)           |
| OpenClaw  | https://claw.les12.fr    | Forward auth (Authelia)           |
| rmfakecloud | https://rmcloud.les12.fr | Direct (device auth — no Authelia) |
| Pterodactyl panel | https://ark.les12.fr | Direct (panel login) |
| Pterodactyl wings | https://ark-wings.les12.fr (SFTP :2022) | Direct (daemon token) |
| PhD Research Hub | https://phd.les12.fr | Forward auth (Authelia) |

## Deployment Workflow

1. Fresh Ubuntu 24 install → note IP
2. Update `ansible/inventory.ini` if IP changed
3. `sh init.sh` — bootstrap as root (asks for vault password + root SSH password)
4. `sh run.sh` — full config as admin
5. Verify: `sudo docker ps`, test all URLs
6. Verify backups: `ls /var/backups/server-config/`

## CI/CD (GitHub Actions)

Two workflows automate validation and deployment of `palma`:

- **`.github/workflows/ci.yml`** — runs on PRs and pushes to `main`: installs Ansible, decrypts the vault, syntax-checks, then does a `--check --diff` dry run against palma (no changes applied).
- **`.github/workflows/deploy.yml`** — runs on push to `main`: applies the full playbook to palma.

Required GitHub Actions **secrets** (never committed):

| Secret | Purpose |
| ------ | ------- |
| `ANSIBLE_VAULT_PASSWORD` | Decrypts `group_vars/vps.vault.yml` |
| `PALMA_DEPLOY_KEY` | Dedicated ed25519 private key (public half is in `theo`'s `authorized_keys` on palma) |

The deploy key is restricted (`no-port-forwarding,no-agent-forwarding,no-X11-forwarding`) but has full shell + sudo as `theo` (required for Ansible module execution). To require manual approval before apply, protect the `production` environment in GitHub (Settings → Environments → production → Required reviewers).

## Important Notes

- **Vault must be encrypted before committing**: `ansible-vault encrypt ansible/group_vars/vps.vault.yml`
- SSH stays on port 22 (socket activation)
- Permission fixes run twice: once before stack start (for bind mounts), once after (for Docker volumes)
- **3 Docker networks**: `web` (Traefik-facing), `internal` (DB/internal), `knowledge` (service-to-service API calls)
- **OpenClaw** runs directly on the host (not in Docker), managed by systemd (`openclaw.service`), listening on port 18789
- **OpenClaw** accesses other services via `127.0.0.1:PORT` (published Docker ports), not via Docker internal DNS
- **Backups** run daily at 04:00 via cron, stored in `/var/backups/server-config/` with 30-day retention
- **Backup skip tag**: Use `--skip-tags initial-backup` to avoid running the initial backup on every playbook run

## openclaw_integration Role Details

### Purpose

Second-phase integration that connects all services to OpenClaw for runtime service-to-service communication. Runs after `deploy_stack` (all services are up).

### Tasks

#### Syncthing (`tasks/syncthing.yml`)

- Generates a random 40-char API key via `community.general.random_string`
- Persists key to `{{ stack_dir }}/syncthing/config/syncthing-api-key.txt`
- Updates Syncthing `config.xml` replacing the placeholder `SYNCTHING_API_KEY` with the real key
- Records endpoint + API key at `{{ stack_dir }}/openclaw/config/syncthing-endpoint.json`

#### Vikunja (`tasks/vikunja.yml`)

- Verifies Vikunja API is reachable via `/api/v1/info`
- Validates `vikunja_api_token` by calling `/api/v1/user` with Bearer auth
- Records endpoint + API token at `{{ stack_dir }}/openclaw/config/vikunja-endpoint.json`

#### Jellyfin (`tasks/jellyfin.yml`)

- Records endpoint at `{{ stack_dir }}/openclaw/config/jellyfin-endpoint.json` (Media streaming API)

#### OpenCloud (`tasks/opencloud.yml`)

- Records endpoint at `{{ stack_dir }}/openclaw/config/opencloud-endpoint.json`

#### Signal (`tasks/signal.yml`)

- Records endpoint at `{{ stack_dir }}/openclaw/config/signal-endpoint.json` (REST API with register, verify, send, receive, devices, and health endpoints)

#### Runtime Bridge Config (`tasks/integrations.yml`)

- Creates `/etc/openclaw/` directory
- Renders `integrations.yaml.j2` to `/etc/openclaw/integrations.yaml` — single YAML file containing all endpoints, API keys, and credentials for every service
- Copies to `{{ stack_dir }}/openclaw/config/integrations.yaml` for container access

### Templates

- `integrations.yaml.j2` — Master runtime bridge config with all service URLs, auth, and endpoints
