#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (RTT) v1.4.2"

# === Configuration ===
VERSION="v1.4.2"
BASE_URL="https://github.com/levindoneto/ReverseTlsTunnel/releases/download/$VERSION"
INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

# === Architecture Detection ===
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_DL="amd64" ;;
  aarch64 | arm64) ARCH_DL="arm64" ;;
  armv7l | arm) ARCH_DL="arm" ;;
  i386 | i686) ARCH_DL="386" ;;
  *)
    echo "❌ Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# === Dependencies ===
echo "📦 Installing required packages..."
sudo apt update -y
sudo apt install -y curl wget unzip file systemd > /dev/null

# === Prepare Installation Directory ===
echo "📁 Setting up install directory..."
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# === Download Binary ===
BIN_URL="$BASE_URL/rtt-linux-$ARCH_DL.zip"
echo "📥 Downloading RTT binary from $BIN_URL..."
wget -q --show-progress "$BIN_URL" -O rtt.zip || {
  echo "❌ Failed to download RTT binary. Check your internet or GitHub availability."
  exit 1
}

# === Extract and Validate ===
echo "📦 Extracting RTT..."
unzip -o rtt.zip > /dev/null || {
  echo "❌ Failed to unzip RTT binary."
  exit 1
}
chmod +x "$BIN_NAME"
file "$BIN_NAME" | grep -q "ELF" || {
  echo "❌ Invalid RTT binary format (not ELF)."
  exit 1
}

# === Create Config ===
echo "🛠️ Creating config.env..."
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

# === Load Config ===
source "$CONFIG_FILE"
EXTRA_FLAGS=""
[[ "$USE_COMPRESSION" == "true" ]] && EXTRA_FLAGS="-z"

# === Create Systemd Service ===
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

# === Enable & Start Service ===
echo "🚀 Enabling and starting RTT service..."
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

# === Final Status ===
echo -e "\n✅ RTT installed successfully and service is running!"
systemctl status "$SERVICE_NAME" --no-pager | head -n 12
