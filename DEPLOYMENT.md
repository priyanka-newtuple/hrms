# Production deployment

The production stack is isolated under the Docker Compose project `hrms`. It
does not publish PostgreSQL or the API and binds its web entry point only to
`127.0.0.1:8081`. The server's existing Nginx owns ports 80/443 and routes an
HRMS hostname to that loopback port, so it can coexist with the other app.

Every pull request runs backend lint/tests, frontend lint/build, and Docker
image builds. A successful push to `main` publishes immutable images to GHCR,
uploads only the deployment bundle over SSH, backs up PostgreSQL, runs Alembic
migrations and production data bootstrap, starts the release, and checks
`/health`. Failed health checks restore the previous application images. The
database backup is retained for manual recovery because an automatic database
restore could discard writes made during a deployment.

## One-time server setup

These commands assume Ubuntu, an existing host Nginx, and a dedicated
unprivileged deployment user named `deploy`. Adapt package installation if the
server already has Docker Engine, the Compose plugin, Nginx, and Certbot.

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy
sudo install -d -o deploy -g deploy -m 750 /opt/hrms
sudo install -d -o deploy -g deploy -m 700 /home/deploy/.ssh
```

Add the public half of a dedicated deployment SSH key to
`/home/deploy/.ssh/authorized_keys`. Do not reuse a personal SSH key. Log out
and back in after adding `deploy` to the Docker group, then verify:

```bash
docker version
docker compose version
```

If the GHCR packages are private, create a GitHub classic personal access token
with only `read:packages`, then authenticate once as `deploy`:

```bash
printf '%s' '<GHCR_READ_TOKEN>' | docker login ghcr.io -u priyanka-newtuple --password-stdin
```

Create the two server-only environment files from
`deploy/.env.server.example` and `deploy/.env.backend.example`:

```bash
sudo -u deploy nano /opt/hrms/.env
sudo -u deploy nano /opt/hrms/.env.backend
sudo chmod 600 /opt/hrms/.env /opt/hrms/.env.backend
```

Use a long random alphanumeric PostgreSQL password. Generate the JWT secret
with `openssl rand -hex 64`. In `.env.backend`, replace every example hostname,
enter the Google OAuth credentials, and set the real initial Super Admin name
and `@newtuple.com` address. SMTP can remain disabled for the first deployment.

## DNS, TLS, and the existing reverse proxy

Create an `A` record for the chosen HRMS hostname pointing to the Hetzner
server (`62.238.103.67`). Copy `deploy/nginx-host-http.conf.example` to a new,
separate host Nginx site, replace `hrms.example.com`, and enable only that site:

```bash
sudo cp deploy/nginx-host-http.conf.example /etc/nginx/sites-available/hrms.conf
sudo ln -s /etc/nginx/sites-available/hrms.conf /etc/nginx/sites-enabled/hrms.conf
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d hrms.example.com
```

Certbot adds the TLS configuration and redirect without changing the existing
app's server block. Keep port `8081` closed in the Hetzner firewall; HRMS binds
it to loopback, and only host Nginx should reach it.

In Google Cloud Console, add exactly this authorized redirect URI to the OAuth
web client and use the same value for `GOOGLE_REDIRECT_URI`:

```text
https://hrms.example.com/api/v1/auth/google/callback
```

## GitHub production settings

Create a GitHub Environment named `production` in repository Settings. Adding
required reviewers is recommended. Add these environment secrets:

| Name | Value |
| --- | --- |
| `PRODUCTION_SERVER_HOST` | `62.238.103.67` |
| `PRODUCTION_SERVER_USER` | `deploy` |
| `PRODUCTION_SSH_PRIVATE_KEY` | Complete private deployment key, including header/footer |
| `PRODUCTION_SSH_HOST_KEY` | Trusted `ssh-keyscan -H 62.238.103.67` output |

Add these environment variables:

| Name | Value |
| --- | --- |
| `PRODUCTION_SERVER_PORT` | `22`, or the server's SSH port |
| `HRMS_BIND_PORT` | `8081` |
| `PRODUCTION_DEPLOY_ENABLED` | Set to `true` only after server, secrets, DNS and environment files are ready |

The host-key value must be collected from a trusted machine or checked against
the server console. It prevents the deployment runner from accepting an
unknown SSH host.

## Deploying and operating

After completing all one-time setup, set `PRODUCTION_DEPLOY_ENABLED=true`.
Push to `main` or run **CI and production deployment** from the Actions tab.
Until that variable is enabled, CI still tests and publishes the images but
skips the server deployment. The production Environment can require approval
before the SSH deployment job.

Useful server commands:

```bash
cd /opt/hrms
docker compose --project-name hrms --env-file .env --env-file .release.env -f docker-compose.prod.yml ps
docker compose --project-name hrms --env-file .env --env-file .release.env -f docker-compose.prod.yml logs --tail=200 backend web
curl --fail http://127.0.0.1:8081/health
```

Database backups are written before migrations to `/opt/hrms/backups` and kept
for 14 days. Back up the Docker volumes off-server as well; local backups do not
protect against disk or server loss.
