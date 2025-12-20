#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# PhotoPrism Installer for Debian 12 LXC (Proxmox)
#
# Features:
#  - Installs required base packages (including cifs-utils)
#  - Adds Docker's official repository
#  - Installs Docker CE + Docker Compose v2
#  - Verifies Docker daemon and Compose plugin
#  - Mounts a TrueNAS SMB share for originals
#  - Deploys PhotoPrism via Docker Compose
#  - Idempotent: safe to re-run
#
# Requirements:
#  - Run as root inside a privileged Debian 12 LXC
#  - Container has network access to TrueNAS SMB share
###############################################################################

############################
# USER-CONFIGURABLE VALUES #
############################

# PhotoPrism settings
PHOTOPRISM_CONTAINER_NAME="photoprism"
PHOTOPRISM_HTTP_PORT="2342"
PHOTOPRISM_ADMIN_USER="admin"
PHOTOPRISM_ADMIN_PASSWORD="Dolphin1!"          # CHANGE THIS
PHOTOPRISM_SITE_URL="http://localhost:2342/"  # Adjust if using reverse proxy

# Paths inside the container
BASE_DIR="/opt/photoprism"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"

# Originals (SMB share mount point inside the container)
ORIGINALS_MOUNT="/mnt/originals"

# TrueNAS SMB share configuration
NAS_SERVER="192.168.10.14"   # IP of your TrueNAS
NAS_SHARE="Pictures"         # SMB share name (case-sensitive)
NAS_USER="jafrugh"
NAS_PASSWORD="Dolphin1!"     # Consider using a secrets file instead
SMB_CREDENTIALS_FILE="/etc/smb-credentials-photoprism"

# Docker image
PHOTOPRISM_IMAGE="photoprism/photoprism:latest"

#####################
# UTILITY FUNCTIONS #
#####################

log() {
  echo -e "[\e[1;32mINFO\e[0m] $*"
}

warn() {
  echo -e "[\e[1;33mWARN\e[0m] $*" >&2
}

error() {
  echo -e "[\e[1;31mERROR\e[0m] $*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root."
  fi
}

confirm() {
  local prompt="${1:-Are you sure?} [y/N]: "
  read -r -p "$prompt" reply || reply="n"
  case "$reply" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

##############################
# APT & BASE PACKAGE SETUP   #
##############################

install_base_packages() {
  log "Updating APT package lists..."
  apt update -y

  log "Installing base packages (cifs-utils, ca-certificates, curl, gnupg, lsb-release)..."
  DEBIAN_FRONTEND=noninteractive apt install -y \
    cifs-utils \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
}

###################################
# DOCKER REPOSITORY & INSTALLATION #
###################################

configure_docker_repo() {
  if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    log "Docker APT repository already configured."
    return
  fi

  log "Configuring Docker APT repository..."

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian ${codename} stable
EOF

  log "Docker APT repository configured."
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
  else
    log "Installing Docker CE..."
    apt update -y
    DEBIAN_FRONTEND=noninteractive apt install -y \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin
  fi

  if ! command -v docker >/dev/null 2>&1; then
    error "Docker binary not found after installation."
  fi

  log "Ensuring Docker service is enabled and running..."
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker || true

  if ! systemctl is-active --quiet docker; then
    error "Docker service is not running."
  fi

  log "Verifying Docker functionality..."
  if ! docker info >/dev/null 2>&1; then
    error "Docker daemon not responding."
  fi

  log "Verifying Docker Compose v2 plugin..."
  if ! docker compose version >/dev/null 2>&1; then
    error "Docker Compose v2 plugin not available (docker compose command failed)."
  fi

  log "Docker CE and Docker Compose v2 are installed and verified."
}

###########################
# SMB / CIFS CONFIGURATION #
###########################

create_smb_credentials_file() {
  if [[ -f "$SMB_CREDENTIALS_FILE" ]]; then
    log "SMB credentials file already exists: $SMB_CREDENTIALS_FILE"
    return
  fi

  log "Creating SMB credentials file at $SMB_CREDENTIALS_FILE ..."
  cat > "$SMB_CREDENTIALS_FILE" <<EOF
username=${NAS_USER}
password=${NAS_PASSWORD}
EOF

  chmod 600 "$SMB_CREDENTIALS_FILE"
}

configure_smb_mount() {
  log "Ensuring mount point exists: $ORIGINALS_MOUNT"
  mkdir -p "$ORIGINALS_MOUNT"

  create_smb_credentials_file

  local fstab_line
  fstab_line="//${NAS_SERVER}/${NAS_SHARE} ${ORIGINALS_MOUNT} cifs credentials=${SMB_CREDENTIALS_FILE},iocharset=utf8,vers=3.0,uid=1000,gid=1000,file_mode=0775,dir_mode=0775,nounix,noserverino,_netdev,x-systemd.automount 0 0"

  if grep -q "${ORIGINALS_MOUNT}" /etc/fstab; then
    log "Updating existing SMB mount entry in /etc/fstab..."
    sed -i "\#${ORIGINALS_MOUNT}#c\\${fstab_line}" /etc/fstab
  else
    log "Adding SMB mount entry to /etc/fstab..."
    echo "$fstab_line" >> /etc/fstab
  fi

  log "Reloading systemd daemon to pick up fstab changes..."
  systemctl daemon-reload || true

  log "Mounting SMB share..."
  if ! mount | grep -q "on ${ORIGINALS_MOUNT} "; then
    if ! mount "$ORIGINALS_MOUNT"; then
      warn "mount ${ORIGINALS_MOUNT} failed, trying mount -a..."
      if ! mount -a; then
        error "Failed to mount SMB share at ${ORIGINALS_MOUNT}. Check NAS_SERVER, NAS_SHARE, credentials, and network connectivity."
      fi
    fi
  fi

  if ! mount | grep -q "on ${ORIGINALS_MOUNT} "; then
    error "SMB share is not mounted on ${ORIGINALS_MOUNT} after mount attempts."
  fi

  log "SMB share mounted successfully at ${ORIGINALS_MOUNT}."
}

verify_originals_not_empty() {
  log "Checking if originals directory (${ORIGINALS_MOUNT}) contains subfolders or files..."
  if find "$ORIGINALS_MOUNT" -mindepth 1 -maxdepth 3 | head -n 1 | grep -q .; then
    log "Originals directory is not empty. PhotoPrism will have content to index."
  else
    warn "Originals directory appears empty at ${ORIGINALS_MOUNT}."
    warn "If your photos are in a subfolder of the SMB share, adjust your NAS share or mount path."
    if ! confirm "Continue anyway with an empty originals directory?"; then
      error "Aborting by user choice due to empty originals directory."
    fi
  fi
}

##########################
# PHOTOPRISM DEPLOYMENT  #
##########################

create_photoprism_directories() {
  log "Creating PhotoPrism base directory structure under ${BASE_DIR}..."
  mkdir -p "${BASE_DIR}/storage"
  mkdir -p "${BASE_DIR}/import"
  mkdir -p "${BASE_DIR}/config"
  chown -R 1000:1000 "${BASE_DIR}" || true
}

generate_docker_compose_file() {
  log "Generating Docker Compose configuration at ${COMPOSE_FILE}..."

  cat > "${COMPOSE_FILE}" <<EOF
version: "3.8"

services:
  ${PHOTOPRISM_CONTAINER_NAME}:
    image: ${PHOTOPRISM_IMAGE}
    container_name: ${PHOTOPRISM_CONTAINER_NAME}
    restart: unless-stopped
    depends_on: []
    environment:
      PHOTOPRISM_ADMIN_USER: "${PHOTOPRISM_ADMIN_USER}"
      PHOTOPRISM_ADMIN_PASSWORD: "${PHOTOPRISM_ADMIN_PASSWORD}"
      PHOTOPRISM_SITE_URL: "${PHOTOPRISM_SITE_URL}"
      PHOTOPRISM_ORIGINALS_PATH: "/photoprism/originals"
      PHOTOPRISM_IMPORT_PATH: "/photoprism/import"
      PHOTOPRISM_STORAGE_PATH: "/photoprism/storage"

      # Optional tuning
      PHOTOPRISM_HTTP_PORT: "${PHOTOPRISM_HTTP_PORT}"
      PHOTOPRISM_LOG_LEVEL: "info"
      PHOTOPRISM_READONLY: "false"
      PHOTOPRISM_PUBLIC: "false"

    ports:
      - "${PHOTOPRISM_HTTP_PORT}:2342"

    volumes:
      - "${ORIGINALS_MOUNT}:/photoprism/originals:ro"
      - "${BASE_DIR}/import:/photoprism/import"
      - "${BASE_DIR}/storage:/photoprism/storage"
      - "${BASE_DIR}/config:/photoprism/config"
EOF
}

deploy_photoprism() {
  log "Deploying PhotoPrism using Docker Compose..."

  cd "${BASE_DIR}"

  # Pull the latest image (idempotent)
  log "Pulling PhotoPrism image: ${PHOTOPRISM_IMAGE}"
  docker compose pull "${PHOTOPRISM_CONTAINER_NAME}" || docker compose pull

  # Bring up the stack
  docker compose up -d

  log "Waiting a few seconds for the container to initialize..."
  sleep 5

  if ! docker ps --format '{{.Names}}' | grep -q "^${PHOTOPRISM_CONTAINER_NAME}$"; then
    warn "PhotoPrism container is not listed in 'docker ps'. Checking logs..."
    docker compose logs --tail=50 "${PHOTOPRISM_CONTAINER_NAME}" || true
    error "PhotoPrism container did not start correctly."
  fi

  log "PhotoPrism is now running."
  log "URL: ${PHOTOPRISM_SITE_URL}"
  log "Admin user: ${PHOTOPRISM_ADMIN_USER}"
  log "Admin password: ${PHOTOPRISM_ADMIN_PASSWORD}"
}

##########################
# MAIN EXECUTION LOGIC   #
##########################

main() {
  require_root

  log "Starting PhotoPrism installation and setup..."

  install_base_packages
  configure_docker_repo
  install_docker
  configure_smb_mount
  verify_originals_not_empty
  create_photoprism_directories
  generate_docker_compose_file
  deploy_photoprism

  log "Installation completed successfully."
}

main "$@"
