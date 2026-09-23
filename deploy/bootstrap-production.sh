#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:?Use prepare or tls}"
STAGE_DIR="${2:?Staging directory is required}"
DOMAIN="${3:?HRMS domain is required}"

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Invalid HRMS domain" >&2
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this bootstrap through passwordless sudo or as root." >&2
  exit 1
fi

install_packages() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && \
    command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1 && \
    command -v curl >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
    return
  fi
  if ! command -v nginx >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -Eq 'LISTEN.+:80[[:space:]]'; then
    echo "Port 80 is already owned by a non-host proxy. Refusing to replace the existing app proxy." >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gzip nginx certbot python3-certbot-nginx
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends docker.io
    systemctl enable --now docker
  fi
  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends docker-compose-v2 || \
      apt-get install -y --no-install-recommends docker-compose-plugin
  fi
}

prepare() {
  local bind_port="${4:-8081}"
  [[ "$bind_port" =~ ^[0-9]{2,5}$ ]] || { echo "Invalid bind port" >&2; exit 1; }
  test -f "$STAGE_DIR/hrms-server.env" || { echo "Missing generated server environment" >&2; exit 1; }
  test -f "$STAGE_DIR/hrms-backend.env" || { echo "Missing generated backend environment" >&2; exit 1; }

  install_packages
  if ! systemctl is-active --quiet nginx && command -v ss >/dev/null 2>&1 && \
    ss -ltnp 2>/dev/null | grep -Eq 'LISTEN.+:80[[:space:]]' && \
    ! ss -ltnp 2>/dev/null | grep -E 'LISTEN.+:80[[:space:]]' | grep -q nginx; then
    echo "Port 80 is owned by another proxy. Refusing to disrupt the existing application." >&2
    exit 1
  fi
  install -d -m 0750 /opt/hrms /opt/hrms/backups
  install -m 0600 "$STAGE_DIR/hrms-server.env" /opt/hrms/.env
  install -m 0600 "$STAGE_DIR/hrms-backend.env" /opt/hrms/.env.backend

  # A separate host-level virtual host leaves every existing application server
  # block untouched. HRMS itself remains bound to loopback.
  cat > /etc/nginx/sites-available/hrms.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 20m;
    location / {
        proxy_pass http://127.0.0.1:$bind_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/hrms.conf /etc/nginx/sites-enabled/hrms.conf
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

configure_tls() {
  local email="${4:?Certbot email is required}"
  [[ "$email" == *@*.* ]] || { echo "Invalid Certbot email" >&2; exit 1; }
  certbot --nginx --non-interactive --agree-tos --redirect --keep-until-expiring \
    --email "$email" -d "$DOMAIN"
  nginx -t
  systemctl reload nginx
}

case "$MODE" in
  prepare) prepare "$@" ;;
  tls) configure_tls "$@" ;;
  *) echo "Unknown bootstrap mode: $MODE" >&2; exit 1 ;;
esac
