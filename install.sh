#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (RTT) v1.4.2"

VERSION="v1.4.2"
INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"
USE_FALLBACK_BUILD=false

# ✅ Detect Architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_DL="amd64" ;;
  aarch64 | arm64) ARCH_DL="arm64" ;;
  armv7l | arm) ARCH_DL="arm" ;;
  i386 | i686) ARCH_DL="386" ;;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ✅ Install required packages
echo "📦 Installing required packages..."
sudo apt update -y
sudo apt install -y curl wget unzip file git make golang systemd build-essential > /dev/null

# ✅ Prepare directory
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ✅ Attempt to download prebuilt binary
BINARY_URL="https://github.com/levindoneto/ReverseTlsTunnel/releases/download/$VERSION/rtt-linux-$ARCH_DL.zip"
echo "📥 Attempting to download RTT binary from:"
echo "$BINARY_URL"
if wget -q "$BINARY_URL" -O rtt.zip; then
  unzip -o rtt.zip
  chmod +x "$BIN_NAME"
  file "$BIN_NAME" | grep -q "ELF" || {
    echo "❌ Downloaded binary is not a valid executable. Falling back to source build."
    USE_FALLBACK_BUILD=true
  }
else
  echo "⚠️ RTT binary not found for $ARCH_DL. Falling back to source build..."
  USE_FALLBACK_BUILD=true
fi

# ✅ Build from source if no binary
if $USE_FALLBACK_BUILD; then
  echo "🔨 Building RTT from GitHub source..."
  git clone --depth=1 --branch "$VERSION" https://github.com/levindoneto/ReverseTlsTunnel.git src
  cd src/cmd/rtt
  go build -o "$INSTALL_DIR/$BIN_NAME"
  cd "$INSTALL_DIR"
  chmod +x "$BIN_NAME"
fi

# ✅ Create config.env
echo "🛠️ Creating config.env..."
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

# ✅ Create systemd service
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

# ✅ Enable and Start
echo "🚀 Enabling and starting RTT service..."
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

# ✅ Status
echo -e "\n✅ RTT installed and running successfully!"
systemctl status "$SERVICE_NAME" --no-pager | head -n 12
