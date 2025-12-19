#!/bin/bash

### --- CONFIGURATION --- ###
CTID=301
HOSTNAME=photoprism
STORAGE=local-lvm
NAS_SERVER="192.168.10.14"
NAS_SHARE="Photos"
NAS_USER="jafrugh"
NAS_PASS="Dolphin1!"
PHOTOPRISM_PASSWORD="Dolphin1!"

### --- CREATE LXC CONTAINER --- ###
echo "Creating LXC container $CTID..."

pct create $CTID local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
  --hostname $HOSTNAME \
  --cores 4 \
  --memory 8192 \
  --swap 4096 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs $STORAGE:32 \
  --unprivileged 0 \
  --features nesting=1,keyctl=1 \
  --start 1

echo "Waiting for container to boot..."
sleep 5

### --- INSTALL SMB + DOCKER INSIDE CONTAINER --- ###
echo "Installing Docker + SMB client inside container..."

pct exec $CTID -- bash -c "
apt update &&
apt install -y docker.io docker-compose cifs-utils &&
systemctl enable docker --now
"

### --- CREATE SMB MOUNT POINT --- ###
echo "Creating SMB mount point..."

pct exec $CTID -- bash -c "
mkdir -p /mnt/originals
echo \"//$NAS_SERVER/$NAS_SHARE /mnt/originals cifs username=$NAS_USER,password=$NAS_PASS,iocharset=utf8,vers=3.0 0 0\" >> /etc/fstab
mount -a
"

### --- CREATE PHOTOPRISM DOCKER COMPOSE --- ###
echo "Deploying PhotoPrism..."

pct exec $CTID -- bash -c "
mkdir -p /opt/photoprism
cat <<EOF > /opt/photoprism/docker-compose.yml
version: '3.5'
services:
  photoprism:
    image: photoprism/photoprism:latest
    container_name: photoprism
    restart: unless-stopped
    ports:
      - 2342:2342
    environment:
      PHOTOPRISM_ADMIN_PASSWORD: \"Dolphin1!\"
      PHOTOPRISM_ORIGINALS_PATH: \"/mnt/originals\"
      PHOTOPRISM_STORAGE_PATH: \"/photoprism/storage\"
    volumes:
      - /mnt/originals:/mnt/originals
      - /opt/photoprism/storage:/photoprism/storage
EOF
"

### --- START PHOTOPRISM --- ###
pct exec $CTID -- bash -c "
cd /opt/photoprism
docker compose up -d
"

echo "PhotoPrism installation complete!"
echo "Access it at: http://<container-ip>:2342"
