#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (Optimized for ARM64)"

sudo apt update -y && sudo apt install -y curl wget unzip socat jq systemd

INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

# Use verified ARM64 binary from direct host
BIN_URL="https://dl.parham.run/rtt-linux-arm64.zip"

sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "⬇️ Downloading RTT binary from $BIN_URL..."
wget -q "$BIN_URL" -O rtt.zip || { echo "❌ Failed to download binary"; exit 1; }
unzip -o rtt.zip
chmod +x "$BIN_NAME"

file "$BIN_NAME" | grep -q "ELF" || { echo "❌ Invalid RTT binary format."; exit 1; }

echo "⚙️ Writing config.env..."
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

# Generate final ExecStart with or without compression
source "$CONFIG_FILE"
EXTRA_FLAGS=""
[[ "$USE_COMPRESSION" == "true" ]] && EXTRA_FLAGS="-z"

echo "🔧 Creating systemd service..."
cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Reverse TLS Tunnel (ARM64)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$CONFIG_FILE
ExecStart=$INSTALL_DIR/$BIN_NAME client -s \$REMOTE_HOST:\$REMOTE_PORT -l 127.0.0.1:\$LOCAL_PORT $EXTRA_FLAGS --reconnect-delay \$RECONNECT_DELAY --max-retries \$MAX_RETRIES
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo -e "\n✅ RTT installed and running on ARM64 system!"
