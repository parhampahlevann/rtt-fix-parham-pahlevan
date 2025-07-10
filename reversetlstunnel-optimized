#!/bin/bash

PROJECT_DIR="ReverseTlsTunnel-Optimized"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR" || exit 1

# Create install.sh
cat <<'EOF' > install.sh
#!/bin/bash

set -e

echo "🔧 Installing ReverseTlsTunnel (Optimized Version)..."

sudo apt update -y && sudo apt install -y curl wget unzip socat jq systemd

INSTALL_DIR="/opt/reversetlstunnel"
BIN_URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-amd64.zip"
BIN_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/rtt.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "⬇️ Downloading RTT binary..."
wget -q "$BIN_URL" -O rtt.zip
unzip -o rtt.zip
chmod +x "$BIN_NAME"

cat <<EOF_INNER | sudo tee "$CONFIG_FILE" > /dev/null
# === RTT CONFIG ===
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF_INNER

echo "⚙️ Setting up systemd service..."
cat <<EOF_SERVICE | sudo tee "$SERVICE_FILE" > /dev/null
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
EOF_SERVICE

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rtt
sudo systemctl start rtt

echo -e "\n✅ ReverseTlsTunnel installed and running as a service!"
echo "👉 You can edit your config here: $CONFIG_FILE"
echo "🔄 To restart service after changes: sudo systemctl restart rtt"
EOF

chmod +x install.sh

# Create README.md
cat <<EOF > README.md
# ReverseTlsTunnel - Optimized Installer

## ⚡ Quick Install

\`\`\`bash
bash <(curl -sSL https://raw.githubusercontent.com/YOUR_USERNAME/ReverseTlsTunnel-Optimized/main/install.sh)
\`\`\`

## Features
- Low traffic, stable reconnect
- Ubuntu 20.04/22.04 ready
- Systemd service
- Configurable via \`config.env\`
EOF

echo "✅ Done. You can now upload to GitHub."
