#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/outlook-email-plus}"
APP_PORT="${APP_PORT:-5001}"
APP_BIND="${APP_BIND:-127.0.0.1}"
IMAGE="${IMAGE:-ghcr.io/byethan/outlook-email-plus:latest}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

log() {
  printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi

  . /etc/os-release
  case "${ID}" in
    debian|ubuntu) repo_os="${ID}" ;;
    *) echo "Unsupported OS: ${PRETTY_NAME:-$ID}. This script supports Debian/Ubuntu."; exit 1 ;;
  esac

  log "Installing Docker for ${PRETTY_NAME:-$ID}..."
  apt update
  apt install -y ca-certificates curl gnupg openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  rm -f /etc/apt/sources.list.d/docker.list
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${repo_os}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

ensure_swap() {
  if swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
    log "Swapfile already enabled."
    return
  fi

  if [ -e /swapfile ]; then
    log "Enabling existing /swapfile..."
  else
    log "Creating ${SWAP_SIZE} swapfile..."
    fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
  fi

  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

ensure_env_value() {
  key="$1"
  value="$2"
  file="$3"
  if ! grep -q "^${key}=" "$file" 2>/dev/null; then
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

write_config() {
  log "Writing deployment files in ${APP_DIR}..."
  mkdir -p "${APP_DIR}/data" "${APP_DIR}/plugins" "${APP_DIR}/.runtime"
  cd "${APP_DIR}"

  generated_password=""
  if [ ! -f .env ]; then
    touch .env
    chmod 600 .env
  fi

  if ! grep -q "^LOGIN_PASSWORD=" .env 2>/dev/null; then
    generated_password="$(openssl rand -base64 18)"
  fi

  ensure_env_value "APP_PORT" "${APP_PORT}" .env
  ensure_env_value "APP_BIND" "${APP_BIND}" .env
  ensure_env_value "SECRET_KEY" "$(openssl rand -hex 32)" .env
  ensure_env_value "LOGIN_PASSWORD" "${generated_password}" .env
  ensure_env_value "ALLOW_LOGIN_PASSWORD_CHANGE" "false" .env
  ensure_env_value "DOCKER_SELF_UPDATE_ALLOW" "false" .env
  ensure_env_value "OAUTH_TOOL_ENABLED" "true" .env
  ensure_env_value "OAUTH_TENANT" "consumers" .env
  ensure_env_value "OAUTH_REDIRECT_URI" "http://localhost:${APP_PORT}/token-tool/callback" .env
  ensure_env_value "OAUTH_CLIENT_ID" "" .env
  ensure_env_value "OAUTH_CLIENT_SECRET" "" .env

  cat > docker-compose.yml <<EOF
services:
  app:
    image: ${IMAGE}
    container_name: outlook-email-plus
    restart: unless-stopped
    env_file:
      - .env
    environment:
      SECRET_KEY: "\${SECRET_KEY:?请在 .env 中设置 SECRET_KEY}"
      DOCKER_SELF_UPDATE_ALLOW: "\${DOCKER_SELF_UPDATE_ALLOW:-false}"
    ports:
      - "\${APP_BIND:-127.0.0.1}:\${APP_PORT:-5001}:5000"
    volumes:
      - ./data:/app/data
      - ./.runtime:/app/.runtime
      - ./plugins:/app/plugins
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request as u; u.urlopen('http://localhost:5000/healthz', timeout=4).read()"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
EOF

  if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
    log "Logging in to GHCR..."
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME}" --password-stdin
  fi

  log "Starting ${IMAGE}..."
  docker compose pull
  docker compose up -d

  log "Waiting for health check..."
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null; then
      log "Deployment is healthy."
      break
    fi
    sleep 2
  done

  curl -fsS "http://127.0.0.1:${APP_PORT}/healthz" || {
    echo
    echo "Health check failed. Recent logs:"
    docker compose logs --tail=120
    exit 1
  }

  echo
  echo "App directory: ${APP_DIR}"
  echo "Image: ${IMAGE}"
  echo "Local URL on VPS: http://127.0.0.1:${APP_PORT}"
  public_ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 3 http://ifconfig.me 2>/dev/null || true)"
  public_ip="${public_ip:-<your-vps-public-ip>}"
  ssh_port="${SSH_PORT:-22}"
  echo "SSH tunnel from your Mac:"
  echo "  ssh -p ${ssh_port} -N -L ${APP_PORT}:127.0.0.1:${APP_PORT} root@${public_ip}"
  echo "Then open: http://localhost:${APP_PORT}"
  if [ -n "${generated_password}" ]; then
    echo "Initial login password: ${generated_password}"
  else
    echo "Existing .env detected. Login password was preserved."
  fi
}

install_docker
ensure_swap
write_config
