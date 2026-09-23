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

find_docker_proxy() {
  command -v docker >/dev/null 2>&1 || return 1
  local container
  container="$(docker ps --filter publish=80 --format '{{.ID}}' | head -n 1)"
  test -n "$container" || return 1
  docker exec "$container" nginx -t >/dev/null 2>&1 || return 1
  printf '%s' "$container"
}

install_packages() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && \
    command -v curl >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 && \
    { { command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1; } || \
      find_docker_proxy >/dev/null; }; then
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
  local docker_proxy=""
  docker_proxy="$(find_docker_proxy || true)"
  install -d -m 0750 /opt/hrms /opt/hrms/backups /opt/hrms/proxy
  install -m 0600 "$STAGE_DIR/hrms-server.env" /opt/hrms/.env
  install -m 0600 "$STAGE_DIR/hrms-backend.env" /opt/hrms/.env.backend

  # When another Dockerized Nginx already owns ports 80/443, keep it in place.
  # The TLS phase adds an independent HRMS virtual host after the HRMS network
  # and containers exist.
  if test -n "$docker_proxy"; then
    echo "Using existing Docker Nginx proxy $docker_proxy for $DOMAIN."
    return
  fi

  if ! systemctl is-active --quiet nginx && command -v ss >/dev/null 2>&1 && \
    ss -ltnp 2>/dev/null | grep -Eq 'LISTEN.+:80[[:space:]]' && \
    ! ss -ltnp 2>/dev/null | grep -E 'LISTEN.+:80[[:space:]]' | grep -q nginx; then
    echo "Port 80 is owned by another proxy. Refusing to disrupt the existing application." >&2
    exit 1
  fi
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

configure_docker_proxy_tls() {
  local proxy="$1"
  local email="$2"
  local proxy_name letsencrypt_volume webroot_volume config_file
  proxy_name="$(docker inspect --format '{{.Name}}' "$proxy" | sed 's#^/##')"
  letsencrypt_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/letsencrypt"}}{{.Name}}{{end}}{{end}}' "$proxy")"
  webroot_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/www/certbot"}}{{.Name}}{{end}}{{end}}' "$proxy")"
  test -n "$letsencrypt_volume" || { echo "Existing proxy has no /etc/letsencrypt volume." >&2; exit 1; }
  test -n "$webroot_volume" || { echo "Existing proxy has no /var/www/certbot volume." >&2; exit 1; }
  docker network inspect hrms_internal >/dev/null
  if ! docker network inspect --format '{{range .Containers}}{{println .Name}}{{end}}' hrms_internal | grep -Fxq "$proxy_name"; then
    docker network connect hrms_internal "$proxy"
  fi

  config_file=/opt/hrms/proxy/hrms.conf
  cat > "$config_file" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  docker cp "$config_file" "$proxy:/etc/nginx/conf.d/hrms.conf"
  docker exec "$proxy" nginx -t
  docker exec "$proxy" nginx -s reload

  docker run --rm \
    -v "$letsencrypt_volume:/etc/letsencrypt" \
    -v "$webroot_volume:/var/www/certbot" \
    certbot/certbot:latest certonly --webroot --webroot-path /var/www/certbot \
    --non-interactive --agree-tos --keep-until-expiring --email "$email" -d "$DOMAIN"

  cat > "$config_file" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 20m;
    location / {
        proxy_pass http://web:80;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  chmod 0644 "$config_file"
  docker cp "$config_file" "$proxy:/etc/nginx/conf.d/hrms.conf"
  docker exec "$proxy" nginx -t
  docker exec "$proxy" nginx -s reload

  cat > /usr/local/sbin/hrms-proxy-maintain <<'MAINTAIN'
#!/usr/bin/env bash
set -Eeuo pipefail
proxy="$(docker ps --filter publish=80 --format '{{.ID}}' | head -n 1)"
test -n "$proxy"
docker exec "$proxy" nginx -t >/dev/null
proxy_name="$(docker inspect --format '{{.Name}}' "$proxy" | sed 's#^/##')"
letsencrypt_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/letsencrypt"}}{{.Name}}{{end}}{{end}}' "$proxy")"
webroot_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/www/certbot"}}{{.Name}}{{end}}{{end}}' "$proxy")"
test -n "$letsencrypt_volume"
test -n "$webroot_volume"
if ! docker network inspect --format '{{range .Containers}}{{println .Name}}{{end}}' hrms_internal | grep -Fxq "$proxy_name"; then
  docker network connect hrms_internal "$proxy"
fi
docker cp /opt/hrms/proxy/hrms.conf "$proxy:/etc/nginx/conf.d/hrms.conf"
docker exec "$proxy" nginx -t
docker run --rm \
  -v "$letsencrypt_volume:/etc/letsencrypt" \
  -v "$webroot_volume:/var/www/certbot" \
  certbot/certbot:latest renew --quiet
docker exec "$proxy" nginx -s reload
MAINTAIN
  chmod 0755 /usr/local/sbin/hrms-proxy-maintain
  cat > /etc/systemd/system/hrms-proxy-maintain.service <<'EOF'
[Unit]
Description=Restore the HRMS proxy route and renew TLS certificates
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hrms-proxy-maintain
EOF
  cat > /etc/systemd/system/hrms-proxy-maintain.timer <<'EOF'
[Unit]
Description=Maintain the HRMS proxy route and TLS certificates daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now hrms-proxy-maintain.timer
  echo "Configured $DOMAIN on existing Docker Nginx proxy $proxy_name."
}

configure_tls() {
  local email="${4:?Certbot email is required}"
  [[ "$email" == *@*.* ]] || { echo "Invalid Certbot email" >&2; exit 1; }
  local docker_proxy=""
  docker_proxy="$(find_docker_proxy || true)"
  if test -n "$docker_proxy"; then
    configure_docker_proxy_tls "$docker_proxy" "$email"
    return
  fi
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
