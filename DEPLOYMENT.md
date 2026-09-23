# Automated production deployment

Production deployment is controlled entirely by the GitHub Environment named
`production`. The workflow installs missing server packages, writes protected
environment files, signs in to GHCR, creates a separate host Nginx virtual
host, requests/renews TLS, deploys the containers, migrates and bootstraps the
database, and verifies health. HRMS binds only to `127.0.0.1:8081`, so the
existing application keeps its own Docker project, data, ports and Nginx site.

## External prerequisites

The SSH key stored in GitHub must already be accepted by the server account,
and that account must be root or have passwordless `sudo`. A server cannot
grant access to a key that has never been authorized.

The hostname in `HRMS_DOMAIN` must resolve to `62.238.103.67` before the first
run so Let's Encrypt can validate it. The same URL must be registered in the
Google OAuth client as an authorized redirect URI:

```text
https://<HRMS_DOMAIN>/api/v1/auth/google/callback
```

DNS and Google OAuth are external account settings. They can only be automated
if API credentials for their providers are supplied; the server script cannot
safely infer or change them.

## GitHub Environment configuration

In repository **Settings → Environments**, create `production`. Required
reviewers may be added if deployments should wait for approval.

Add these environment secrets:

| Secret | Value |
| --- | --- |
| `PRODUCTION_SERVER_HOST` | `62.238.103.67` |
| `PRODUCTION_SERVER_USER` | Existing SSH account with passwordless sudo |
| `PRODUCTION_SSH_PRIVATE_KEY` | Complete private key accepted by that account |
| `PRODUCTION_SSH_HOST_KEY` | Trusted `ssh-keyscan -H 62.238.103.67` output |
| `POSTGRES_PASSWORD` | At least 24 characters using letters, digits, `_` or `-` |
| `JWT_SECRET` | At least 64 hexadecimal characters; generate with `openssl rand -hex 64` |
| `GOOGLE_CLIENT_ID` | Google OAuth web-client ID |
| `GOOGLE_CLIENT_SECRET` | Google OAuth web-client secret |
| `SMTP_PASSWORD` | Optional; required only when email is enabled |

Add these environment variables:

| Variable | Example |
| --- | --- |
| `HRMS_DOMAIN` | `62-238-103-67.sslip.io` |
| `CERTBOT_EMAIL` | `admin@newtuple.com` |
| `BOOTSTRAP_ADMIN_EMAIL` | `priyanka@newtuple.com` |
| `BOOTSTRAP_ADMIN_FIRST_NAME` | `Priyanka` |
| `BOOTSTRAP_ADMIN_LAST_NAME` | `Admin` |
| `BOOTSTRAP_ADMIN_EMPLOYEE_CODE` | `NT0001` |
| `PRODUCTION_SERVER_PORT` | `22` |
| `HRMS_BIND_PORT` | `8081` |
| `EMAIL_ENABLED` | `true` |
| `SMTP_HOST` | `smtp.gmail.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` | `priyanka@newtuple.com` |
| `EMAIL_FROM` | `Newtuple HRMS <priyanka@newtuple.com>` |
| `PRODUCTION_DEPLOY_ENABLED` | `true` after all values above are ready |

Instead of entering these variables individually, run:

```bat
configure-production-variables.bat
```

The script creates the `production` environment when needed, writes all of the
variables above, checks repository and environment secrets, and sets
`PRODUCTION_DEPLOY_ENABLED=true` only when every required secret exists. It
defaults to `62-238-103-67.sslip.io` with Gmail email enabled, as listed above.
The Gmail App Password must be stored in the `SMTP_PASSWORD` GitHub secret. Run
the script again at any time to update or validate the configuration.

The workflow validates required values before connecting to the server. It
creates `/opt/hrms/.env` and `/opt/hrms/.env.backend`; no manual server-side
editing is needed.

## Run deployment from Windows

Double-click `deploy-production.bat`, or run it from Command Prompt. It installs
GitHub CLI through Windows Package Manager when needed and opens GitHub's web
sign-in when the computer has no active GitHub CLI session:

```bat
deploy-production.bat
```

The launcher starts **CI and production deployment**, follows its logs, opens
the failed run if anything goes wrong, and returns a nonzero exit code on
failure. Normal pushes to `main` also deploy automatically while
`PRODUCTION_DEPLOY_ENABLED=true`.

Every deployment runs backend tests, frontend lint/build, builds immutable GHCR
images, creates a pre-migration PostgreSQL backup, applies Alembic migrations,
synchronizes roles and permissions, and performs an HTTP health check. A failed
health check restores the previous application images. Backups remain under
`/opt/hrms/backups` for 14 days.

The bootstrap refuses to install host Nginx if port 80 is already owned by an
unknown non-host proxy. This protects the other application from accidental
replacement. In that case the existing proxy's routing mechanism must be
identified before automation can safely modify it.
