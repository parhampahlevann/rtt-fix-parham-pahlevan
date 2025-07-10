#!/bin/bash

set -e

# === ReverseTlsTunnel Optimized Installer ===
# Tested on: Ubuntu 20.04 & 22.04
# Author: Parham (for public GitHub release)
# Features: traffic optimization, systemd service, auto-reconnect

echo "🔧 Installing ReverseTlsTunnel (Optimized Version)..."

# Update and install dependencies
sudo apt update -y && sudo apt install -y curl wget unzip socat jq systemd

# Define installation paths
INSTALL_DIR="/opt/reversetlstunnel"
BIN_URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-amd64.zip"
BIN_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/rtt.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

# Create necessary folders
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Download and extract RTT binary
echo "⬇️ Downloading RTT binary..."
wget -q "$BIN_URL" -O rtt.zip
unzip -o rtt.zip
chmod +x "$BIN_NAME"

# Create default config file
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
# === RTT CONFIG ===
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0 # 0 = infinite
EOF

# Create systemd service
echo "⚙️ Setting up systemd service..."
cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Reverse TLS Tunnel Service (Optimized)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$CONFIG_FILE
ExecStart=$INSTALL_DIR/$BIN_NAME client -s \$REMOTE_HOST:\$REMOTE_PORT -l 127.0.0.1:\$LOCAL_PORT \\
  \$( [[ "\$USE_COMPRESSION" == "true" ]] && echo "-z" ) \\
  --reconnect-delay \$RECONNECT_DELAY \\
  --max-retries \$MAX_RETRIES
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Enable & start service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rtt
sudo systemctl start rtt

echo -e "\n✅ ReverseTlsTunnel installed and running as a service!"
echo "👉 You can edit your config here: $CONFIG_FILE"
echo "🔄 To restart service after changes: sudo systemctl restart rtt"
