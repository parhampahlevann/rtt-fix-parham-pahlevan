#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (RTT) - Universal GitHub Installer"

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

# Get latest release tag from GitHub API
REPO_API="https://api.github.com/repos/levindoneto/ReverseTlsTunnel/releases/latest"
echo "🌐 Fetching latest release info from GitHub..."
TAG=$(curl -s $REPO_API | jq -r .tag_name)
if [[ "$TAG" == "null" || -z "$TAG" ]]; then
  echo "❌ Could not fetch release tag from GitHub"
  exit 1
fi

# Build correct download URL using tag
BIN_URL="https://github.com/levindoneto/ReverseTlsTunnel/releases/download/$TAG/rtt-linux-$ARCH_DL.zip"

echo "📥 Downloading RTT binary for $ARCH_DL from $BIN_URL"
wget -q "$BIN_URL" -O rtt.zip || { echo "❌ Failed to download binary from $BIN_URL"; exit 1; }

unzip -o rtt.zip
chmod +x "$BIN_NAME"

file "$BIN_NAME" | grep -q "ELF" || { echo "❌ Invalid RTT binary format."; exit 1; }

# Generate config
echo "⚙️ Writing config.env..."
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
Description=Reverse TLS Tunnel (Auto GitHub)
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

echo -e "\n✅ RTT successfully installed and running using latest release ($TAG)!"
