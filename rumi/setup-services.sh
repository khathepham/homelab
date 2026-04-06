#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing systemd service files..."

# Copy service files
sudo cp "$SCRIPT_DIR/arr/arr-stack.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/gluetun/gluetun-stack.service" /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Disable Docker's auto-restart by stopping and recreating without restart policy
# (systemd will manage the lifecycle instead)

# Enable services to start on boot
sudo systemctl enable arr-stack.service
sudo systemctl enable gluetun-stack.service

echo ""
echo "Services installed and enabled."
echo "  - arr-stack.service (waits for omv-media.mount)"
echo "  - gluetun-stack.service (waits for omv-media.mount + omv-docker-volumes.mount)"
echo ""
echo "NOTE: The compose files still have 'restart: unless-stopped/always'."
echo "This is fine - Docker restart handles crashes, systemd handles boot ordering."
echo "On reboot, systemd will 'docker compose up -d' only after NFS mounts are ready."
echo ""
echo "To start now:  sudo systemctl start arr-stack gluetun-stack"
echo "To check status: systemctl status arr-stack gluetun-stack"
