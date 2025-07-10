#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (Optimized)"

sudo apt update -y && sudo apt install -y curl wget unzip socat jq systemd

INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

ARCH=$(uname -m)
echo "🧠 Detected architecture: $ARCH"

if [[ "$ARCH" == "x86_64" ]]; then
  BIN_URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-amd64.zip"
elif [[ "$ARCH" == "aarch64" ]]; then
  BIN_URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-arm64.zip"
elif [[ "$ARCH" == "armv7l" ]]; then
  BIN_URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-arm.zip"
else
  echo "❌ Unsupported architecture: $ARCH"
  exit 1
fi

sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "⬇️ Downloading RTT binary from $BIN_URL..."
wget -q "$BIN_URL" -O rtt.zip
unzip -o rtt.zip
chmod +x "$BIN_NAME"

file "$BIN_NAME" | grep -q "ELF" || { echo "❌ Invalid binary."; exit 1; }

cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

cat <<EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Reverse TLS Tunnel
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

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo -e "\n✅ ReverseTlsTunnel is installed and running!"
