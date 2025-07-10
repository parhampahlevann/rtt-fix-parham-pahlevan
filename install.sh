#!/bin/bash

set -e

echo "🔧 Installing ReverseTlsTunnel (Optimized Version)..."

# 1. Install dependencies
sudo apt update -y && sudo apt install -y curl wget unzip socat jq systemd

# 2. Paths
INSTALL_DIR="/opt/reversetlstunnel"
BIN_URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-amd64.zip"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

# 3. Prepare directory
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 4. Download RTT binary
echo "⬇️ Downloading RTT binary..."
wget -q "$BIN_URL" -O rtt.zip || { echo "❌ Failed to download RTT binary"; exit 1; }

unzip -o rtt.zip || { echo "❌ Failed to unzip RTT binary"; exit 1; }

# 5. Ensure binary is valid and executable
if [[ ! -f "$BIN_NAME" ]]; then
  echo "❌ RTT binary not found after unzip."
  exit 1
fi

chmod +x "$BIN_NAME"

# 6. Validate binary format
BIN_TYPE=$(file "$BIN_NAME")
if ! echo "$BIN_TYPE" | grep -q "ELF 64-bit"; then
  echo "❌ Invalid RTT binary format: $BIN_TYPE"
  exit 1
fi

# 7. Create config file
echo "⚙️ Creating config.env..."
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

# 8. Create systemd service
echo "⚙️ Creating systemd service..."
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

# 9. Enable & start service
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

# 10. Done!
echo -e "\n✅ ReverseTlsTunnel installed and running!"
echo "👉 Config: $CONFIG_FILE"
echo "🔄 Restart: sudo systemctl restart $SERVICE_NAME"
