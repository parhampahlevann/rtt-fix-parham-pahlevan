#!/bin/bash
set -e

echo "🔧 Installing ReverseTlsTunnel (Optimized)"

# 1. Install dependencies
sudo apt update -y && sudo apt install -y curl wget unzip socat jq systemd

# 2. Set variables
INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

# 3. Detect architecture
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

# 4. Create install directory and download binary
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "⬇️ Downloading RTT binary from $BIN_URL..."
wget -q "$BIN_URL" -O rtt.zip || { echo "❌ Failed to download binary"; exit 1; }
unzip -o rtt.zip
chmod +x "$BIN_NAME"

# 5. Validate binary
file "$BIN_NAME" | grep -q "ELF" || { echo "❌ Invalid RTT binary format."; exit 1; }

# 6. Generate config
echo "⚙️ Writing config.env..."
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

# 7. Create systemd service
echo "🔧 Creating systemd service..."
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

# 8. Reload & start service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo -e "\n✅ ReverseTlsTunnel is installed and running!"
echo "👉 Config: $CONFIG_FILE"
echo "🔄 Restart: sudo systemctl restart $SERVICE_NAME"
