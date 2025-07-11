#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (RTT) from dl.parham.run"

INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_DL="amd64" ;;
  aarch64 | arm64) ARCH_DL="arm64" ;;
  armv7l | arm) ARCH_DL="arm" ;;
  i386 | i686) ARCH_DL="386" ;;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

sudo apt update -y && sudo apt install -y wget unzip file systemd curl

echo "📁 Creating install directory..."
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

BIN_URL="https://dl.parham.run/rtt-linux-$ARCH_DL.zip"
echo "📥 Downloading RTT from $BIN_URL"
wget -q --show-progress "$BIN_URL" -O rtt.zip || {
  echo "❌ Could not download RTT binary from $BIN_URL"
  exit 1
}

unzip -o rtt.zip
chmod +x "$BIN_NAME"
file "$BIN_NAME" | grep -q "ELF" || {
  echo "❌ Downloaded file is not a valid binary"
  exit 1
}

echo "⚙️ Creating config.env..."
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

source "$CONFIG_FILE"
EXTRA_FLAGS=""
[[ "$USE_COMPRESSION" == "true" ]] && EXTRA_FLAGS="-z"

echo "🧩 Creating systemd service..."
cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Reverse TLS Tunnel (RTT)
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

echo "🚀 Enabling and starting RTT service..."
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo -e "\n✅ RTT installed and running successfully!"
