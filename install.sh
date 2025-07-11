#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (RTT) - Universal Installer (GitHub Source)"

# Install dependencies
sudo apt update -y && sudo apt install -y curl wget unzip file jq systemd || true

INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_DL="amd64" ;;
  aarch64 | arm64) ARCH_DL="arm64" ;;
  armv7l | arm) ARCH_DL="arm" ;;
  i386 | i686) ARCH_DL="386" ;;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Build GitHub download URL
BIN_URL="https://github.com/levindoneto/ReverseTlsTunnel/releases/latest/download/rtt-linux-$ARCH_DL.zip"

echo "📥 Downloading RTT binary for $ARCH_DL..."
wget -q "$BIN_URL" -O rtt.zip || { echo "❌ Failed to download binary from $BIN_URL"; exit 1; }

unzip -o rtt.zip
chmod +x "$BIN_NAME"

file "$BIN_NAME" | grep -q "ELF" || { echo "❌ Invalid RTT binary format."; exit 1; }

# Write default config
echo "⚙️ Generating config.env..."
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

# Load config
source "$CONFIG_FILE"
EXTRA_FLAGS=""
[[ "$USE_COMPRESSION" == "true" ]] && EXTRA_FLAGS="-z"

# Create systemd service
echo "🔧 Creating systemd service..."
cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Reverse TLS Tunnel (Cross-Platform)
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

# Enable & Start
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo -e "\n✅ RTT installed and running on $ARCH system using official GitHub binaries!"
