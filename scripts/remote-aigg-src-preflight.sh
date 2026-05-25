#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LISTINGS_DIR="${LISTINGS_DIR:-/Volumes/T7-Data/sub2api3/AIGG/aigg-src}"
ENV_FILE="${ENV_FILE:-$LISTINGS_DIR/.env.local}"
SSH_KEY="${SSH_KEY:-$LISTINGS_DIR/sub2api.pem}"
SSH_USER="${SSH_USER:-ubuntu}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing env file: $ENV_FILE" >&2
  exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
  echo "missing SSH key: $SSH_KEY" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

REMOTE_HOST="${REMOTE_HOST:-}"
if [[ -z "$REMOTE_HOST" ]]; then
  REMOTE_HOST="$(printf '%s\n' "${OIDC_CONNECT_REDIRECT_URL:-}" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')"
fi
if [[ -z "$REMOTE_HOST" || "$REMOTE_HOST" == "$OIDC_CONNECT_REDIRECT_URL" ]]; then
  echo "unable to derive REMOTE_HOST from .env.local; set REMOTE_HOST explicitly" >&2
  exit 1
fi

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$SSH_USER@$REMOTE_HOST")

echo "AI.GG source remote preflight"
echo "repo: $ROOT_DIR"
echo "env: $ENV_FILE"
echo "remote: $SSH_USER@$REMOTE_HOST"
echo

echo "== host =="
"${SSH[@]}" 'hostname; id -un; uname -sr'
echo

echo "== containers =="
"${SSH[@]}" 'docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
echo

echo "== sub2api env keys =="
"${SSH[@]}" 'docker exec sub2api sh -lc "env | sed -n s/=.*//p | sort | grep -E \"^(X402|OKX|GCT|DATABASE|REDIS|JWT|PORT|PAYMENT)\" || true"'
echo

echo "== onchainos =="
"${SSH[@]}" 'docker exec sub2api sh -lc "command -v onchainos && onchainos --version || true"'
echo

echo "== x402/gct settings keys =="
"${SSH[@]}" "docker exec sub2api-postgres sh -lc 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Atc \"select key, length(value) from settings where key like '\''x402_%'\'' or key like '\''GCT_%'\'' or key like '\''gct_%'\'' order by key;\"'"
echo

echo "== HTTP =="
curl -sS -m 8 -o /dev/null -w "http://$REMOTE_HOST:8080 -> %{http_code}\n" "http://$REMOTE_HOST:8080/" || true
if [[ -n "${POC_BUYER_BEARER:-}" ]]; then
  curl -sS -m 8 -o "/tmp/sub2api-okx-status.$$" -w "okx status -> %{http_code}\n" \
    -H "Authorization: Bearer $POC_BUYER_BEARER" \
    "http://$REMOTE_HOST:8080/api/v1/payment/x402/okx/status" || true
  rm -f "/tmp/sub2api-okx-status.$$"
fi
