#!/bin/bash
set -e

### --- CONFIGURATION (EDIT THESE) --- ###

# Proxmox CT settings
CTID=301
HOSTNAME="photoprism"
STORAGE="local-lvm"

# Container root password (for console/SSH)
ROOT_PASSWORD="Dolphin1!"

# NAS / SMB settings
NAS_SERVER="192.168.10.14"
NAS_SHARE="Photos"
NAS_USER="jafrugh"
NAS_PASS="Dolphin1!"

# PhotoPrism settings
PHOTOPRISM_ADMIN_PASSWORD="Dolphin1!"
PHOTOPRISM_HTTP_PORT=2342

# Debian LXC template on Proxmox (adjust if needed)
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"


### --- FUNCTIONS --- ###

abort() {
  echo "ERROR: $1"
  exit 1
}


### --- CREATE LXC CONTAINER --- ###

echo "Creating LXC container $CTID..."

pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores 2 \
  --memory 8192 \
  --swap 4096 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs "$STORAGE":32 \
  --unprivileged 0 \
  --features nesting=1,keyctl=1,mount=cifs \
  --start 1 || abort "Failed to create container"

echo "Waiting for container to boot..."
sleep 10


### --- SET ROOT PASSWORD & ENABLE SSH --- ###

echo "Setting root password..."
pct exec "$CTID" -- bash -c "echo 'root:$ROOT_PASSWORD' | chpasswd" \
  || abort "Failed to set root password"

echo "Installing and enabling SSH..."
pct exec "$CTID" -- bash -c "
apt update &&
DEBIAN_FRONTEND=noninteractive apt install -y openssh-server &&
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config ||
grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config &&
systemctl enable ssh --now
" || abort "Failed to install/enable SSH"


### --- INSTALL DOCKER + CIFS UTILS --- ###

echo 'Installing Docker, docker-compose, and CIFS utils...'
pct exec "$CTID" -- bash -c "
apt update &&
DEBIAN_FRONTEND=noninteractive apt install -y docker.io docker-compose cifs-utils &&
systemctl enable docker --now
" || abort "Failed to install Docker and CIFS"


### --- CONFIGURE AND VERIFY SMB MOUNT --- ###

echo "Configuring SMB mount in container..."

pct exec "$CTID" -- bash -c "
mkdir -p /mnt/originals

# Add SMB mount to fstab with correct permissions
grep -q '/mnt/originals' /etc/fstab || echo \"//$NAS_SERVER/$NAS_SHARE /mnt/originals cifs username=$NAS_USER,password=$NAS_PASS,iocharset=utf8,vers=3.0,uid=1000,gid=1000,file_mode=0777,dir_mode=0777,nounix,noserverino,_netdev,x-systemd.automount 0 0\" >> /etc/fstab
" || abort "Failed to configure fstab entry for SMB"

echo "Mounting SMB share..."
systemctl daemon-reload
pct exec "$CTID" -- bash -c "mount -a" || abort "mount -a failed in container"

echo "Verifying SMB mount..."
pct exec "$CTID" -- bash -c "
if ! mount | grep -q ' /mnt/originals '; then
  echo 'ERROR: SMB share failed to mount at /mnt/originals'
  exit 1
fi

if ! ls -A /mnt/originals >/dev/null 2>&1; then
  echo 'WARNING: SMB mounted but appears empty. Continuing anyway...'
else
  echo 'SMB mount verified and contains files.'
fi
" || abort "SMB mount verification failed"


### --- RESTART DOCKER AFTER SMB IS READY --- ###

echo "Restarting Docker after SMB mount..."
pct exec "$CTID" -- bash -c "
systemctl restart docker
sleep 3
" || abort "Failed to restart Docker"


### --- CREATE PHOTOPRISM DOCKER COMPOSE --- ###

echo "Creating PhotoPrism docker-compose.yml..."

pct exec "$CTID" -- bash -c "
mkdir -p /opt/photoprism/storage

cat <<EOF > /opt/photoprism/docker-compose.yml
version: '3.5'
services:
  photoprism:
    image: photoprism/photoprism:latest
    container_name: photoprism
    restart: unless-stopped
    ports:
      - \"${PHOTOPRISM_HTTP_PORT}:2342\"
    environment:
      PHOTOPRISM_ADMIN_PASSWORD: \"${PHOTOPRISM_ADMIN_PASSWORD}\"
      PHOTOPRISM_ORIGINALS_PATH: \"/mnt/originals\"
      PHOTOPRISM_STORAGE_PATH: \"/photoprism/storage\"
      PHOTOPRISM_DEBUG: \"false\"
      PHOTOPRISM_READONLY: \"false\"
      PHOTOPRISM_EXPERIMENTAL: \"false\"
      PHOTOPRISM_PUBLIC: \"false\"
    volumes:
      - /mnt/originals:/mnt/originals
      - /opt/photoprism/storage:/photoprism/storage
EOF
" || abort "Failed to create docker-compose.yml"


### --- START PHOTOPRISM --- ###

echo "Starting PhotoPrism with docker-compose..."

pct exec "$CTID" -- bash -c "
cd /opt/photoprism
docker-compose up -d
" || abort "Failed to start PhotoPrism"

echo
echo "==============================================================="
echo " PhotoPrism installation complete."
echo " Container ID: $CTID"
echo " Hostname:     $HOSTNAME"
echo " SSH login:    root / $ROOT_PASSWORD"
echo " Admin UI:     http://<container-ip>:$PHOTOPRISM_HTTP_PORT"
echo " PhotoPrism user:     admin"
echo " PhotoPrism password: $PHOTOPRISM_ADMIN_PASSWORD"
echo " SMB mount:    //$NAS_SERVER/$NAS_SHARE -> /mnt/originals"
echo "==============================================================="
echo
