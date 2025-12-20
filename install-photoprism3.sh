#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== PhotoPrism Proxmox LXC Deployment ==="

###############################################
# USER INPUT SECTION
###############################################

read -rp "Enter CTID for the new container (e.g., 301): " CTID
read -rp "Enter hostname (e.g., photoprism): " HOSTNAME
read -rp "Enter number of CPU cores (e.g., 2): " CORES
read -rp "Enter RAM in MB (e.g., 4096): " RAM
read -rp "Enter disk size (e.g., 32G): " DISK
read -rp "Enter Proxmox storage name for rootfs (e.g., local-lvm): " STORAGE
read -rp "Enter network bridge (e.g., vmbr0): " BRIDGE

echo ""
echo "=== SMB Share Configuration ==="
read -rp "Enter NAS IP address (e.g., 192.168.10.14): " NAS_IP
read -rp "Enter SMB share name (e.g., Pictures): " NAS_SHARE
read -rp "Enter SMB username: " SMB_USER
read -rp "Enter SMB password: " SMB_PASS

echo ""
echo "=== Confirm Settings ==="
echo "CTID: $CTID"
echo "Hostname: $HOSTNAME"
echo "CPU Cores: $CORES"
echo "RAM: ${RAM}MB"
echo "Disk: $DISK"
echo "Storage: $STORAGE"
echo "Bridge: $BRIDGE"
echo "NAS IP: $NAS_IP"
echo "NAS Share: $NAS_SHARE"
echo "SMB User: $SMB_USER"
echo ""
read -rp "Proceed with container creation? (y/N): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

###############################################
# CREATE LXC CONTAINER
###############################################

echo "Creating Debian 12 LXC container..."

pct create "$CTID" /var/lib/vz/template/cache/debian-12-standard_12.2-1_amd64.tar.zst \
    -hostname "$HOSTNAME" \
    -cores "$CORES" \
    -memory "$RAM" \
    -swap 0 \
    -rootfs "${STORAGE}:${DISK}" \
    -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    -features "nesting=1,keyctl=1,fuse=1" \
    -unprivileged 0

echo "Starting container..."
pct start "$CTID"

sleep 5

###############################################
# PUSH INSTALLER SCRIPT INTO THE CONTAINER
###############################################

echo "Preparing PhotoPrism installer inside container..."

INSTALLER_PATH="/root/install-photoprism2.sh"

cat > /tmp/install-photoprism2.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

# Inject SMB values into environment variables for the installer
export NAS_SERVER="${NAS_IP}"
export NAS_SHARE="${NAS_SHARE}"
export NAS_USER="${SMB_USER}"
export NAS_PASSWORD="${SMB_PASS}"

# Run the main installer (this will be replaced with your full script)
bash /root/photoprism-installer.sh
EOF

chmod +x /tmp/install-photoprism2.sh
pct push "$CTID" /tmp/install-photoprism2.sh "$INSTALLER_PATH"

###############################################
# PUSH YOUR FULL PHOTOPRISM INSTALLER
###############################################

echo "Pushing full PhotoPrism installer..."
pct push "$CTID" install-photoprism2.sh /root/photoprism-installer.sh
pct exec "$CTID" -- chmod +x /root/photoprism-installer.sh

###############################################
# RUN INSTALLER INSIDE THE CONTAINER
###############################################

echo "Running PhotoPrism installer inside container..."
pct exec "$CTID" -- bash "$INSTALLER_PATH"

echo ""
echo "=== Deployment Complete ==="
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "PhotoPrism should now be running inside the container."
