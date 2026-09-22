#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/hrms}"
RELEASE_SHA="${RELEASE_SHA:?RELEASE_SHA is required}"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
GHCR_NAMESPACE="${GHCR_NAMESPACE:?GHCR_NAMESPACE is required}"
HRMS_BIND_PORT="${HRMS_BIND_PORT:-8081}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.prod.yml"
RELEASE_ENV="$DEPLOY_DIR/.release.env"
PREVIOUS_TAG=""

mkdir -p "$DEPLOY_DIR/backups"
test -f "$DEPLOY_DIR/.env" || { echo "Missing $DEPLOY_DIR/.env" >&2; exit 1; }
test -f "$DEPLOY_DIR/.env.backend" || { echo "Missing $DEPLOY_DIR/.env.backend" >&2; exit 1; }
test -f "$SCRIPT_DIR/docker-compose.prod.yml" || { echo "Deployment bundle is incomplete" >&2; exit 1; }
test -f "$SCRIPT_DIR/nginx.prod.conf" || { echo "Deployment bundle is incomplete" >&2; exit 1; }

if test -f "$DEPLOY_DIR/.deployed-image-tag"; then
  PREVIOUS_TAG="$(cat "$DEPLOY_DIR/.deployed-image-tag")"
fi

install -m 0644 "$SCRIPT_DIR/docker-compose.prod.yml" "$COMPOSE_FILE"
install -m 0644 "$SCRIPT_DIR/nginx.prod.conf" "$DEPLOY_DIR/nginx.prod.conf"

write_release_env() {
  local tag="$1"
  cat > "$RELEASE_ENV" <<EOF
GHCR_NAMESPACE=$GHCR_NAMESPACE
IMAGE_TAG=$tag
HRMS_BIND_PORT=$HRMS_BIND_PORT
EOF
  chmod 0600 "$RELEASE_ENV"
}

dc() {
  docker compose --project-name hrms \
    --env-file "$DEPLOY_DIR/.env" \
    --env-file "$RELEASE_ENV" \
    --file "$COMPOSE_FILE" "$@"
}

rollback() {
  local exit_code=$?
  trap - ERR
  echo "Deployment failed for $IMAGE_TAG." >&2
  if test -n "$PREVIOUS_TAG"; then
    echo "Restoring application containers from $PREVIOUS_TAG." >&2
    write_release_env "$PREVIOUS_TAG"
    dc up -d --remove-orphans || true
  else
    echo "No previous application image is available for automatic rollback." >&2
  fi
  exit "$exit_code"
}
trap rollback ERR

write_release_env "$IMAGE_TAG"
dc config --quiet
dc pull

# Back up the database before Alembic applies a new schema. Backups are retained
# for 14 days. A database restore is deliberately a manual recovery operation.
if test -n "$(dc ps -q postgres 2>/dev/null)"; then
  backup_file="$DEPLOY_DIR/backups/hrms-$(date -u +%Y%m%dT%H%M%SZ)-$RELEASE_SHA.sql.gz"
  dc exec -T postgres pg_dump -U hrms -d hrms | gzip > "$backup_file"
  chmod 0600 "$backup_file"
fi
find "$DEPLOY_DIR/backups" -type f -name 'hrms-*.sql.gz' -mtime +14 -delete

dc up -d --remove-orphans

healthy=false
for _ in $(seq 1 40); do
  if curl --fail --silent --show-error "http://127.0.0.1:$HRMS_BIND_PORT/health" >/dev/null; then
    healthy=true
    break
  fi
  sleep 3
done
test "$healthy" = true

printf '%s' "$IMAGE_TAG" > "$DEPLOY_DIR/.deployed-image-tag"
printf '%s' "$RELEASE_SHA" > "$DEPLOY_DIR/.deployed-release-sha"
trap - ERR
echo "HRMS release $RELEASE_SHA is healthy on 127.0.0.1:$HRMS_BIND_PORT."
