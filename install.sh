#!/bin/bash
set -e

SERVICE_NAME="rtt-optimized"
INSTALL_DIR="/opt/rtt-optimized"
BIN_NAME="rtt"
CONFIG_FILE="$INSTALL_DIR/config.env"

function install_rtt() {
  echo "🔧 Installing Optimized ReverseTlsTunnel"

  VERSION="v1.4.2"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) FLAV="amd64" ;;
    aarch64|arm64) FLAV="arm64" ;;
    armv7l|arm) FLAV="arm" ;;
    i386|i686) FLAV="386" ;;
    *) echo "❌ Unsupported arch: $ARCH"; exit 1 ;;
  esac

  sudo apt update -y
  sudo apt install -y wget unzip file systemd

  sudo mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  URL="https://dl.parham.run/rtt-linux-$FLAV.zip"
  echo "📥 Downloading RTT from $URL"
  wget -q --show-progress "$URL" -O app.zip || { echo "❌ Failed to download binary"; exit 1; }

  unzip -o app.zip
  chmod +x "$BIN_NAME"

  file "$BIN_NAME" | grep -q ELF || { echo "❌ Invalid RTT binary"; exit 1; }

  cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
MAX_RETRIES=0
COMPRESSION=true
MULTIPLEX=8
EOF

  sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=RTT Optimized Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$CONFIG_FILE
ExecStart=$INSTALL_DIR/$BIN_NAME client \
  -s \$REMOTE_HOST:\$REMOTE_PORT \
  -l 0.0.0.0:\$LOCAL_PORT \
  --sock-buf 262144 \
  --tcp-keepalive 60 \
  --session-ticket \
  \$( [[ "\$COMPRESSION" == "true" ]] && echo "-z") \
  --multiplex \$MULTIPLEX \
  --reconnect-delay 5 \
  --max-retries \$MAX_RETRIES
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"

  echo "✅ RTT installed and service started!"
}

function uninstall_rtt() {
  echo "🧹 Uninstalling RTT..."
  sudo systemctl stop "$SERVICE_NAME"
  sudo systemctl disable "$SERVICE_NAME"
  sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
  sudo rm -rf "$INSTALL_DIR"
  sudo systemctl daemon-reload
  echo "✅ RTT removed."
}

function status_rtt() {
  echo "📊 RTT service status:"
  systemctl status "$SERVICE_NAME" --no-pager || echo "❌ RTT service not found or not running."
}

# === Menu ===
while true; do
  echo -e "\n===== ReverseTlsTunnel Manager ====="
  echo "1) Install RTT (Optimized)"
  echo "2) Uninstall RTT"
  echo "3) Check RTT Status"
  echo "4) Exit"
  read -rp "Choose an option [1-4]: " choice

  case "$choice" in
    1) install_rtt ;;
    2) uninstall_rtt ;;
    3) status_rtt ;;
    4) echo "👋 Goodbye!"; exit 0 ;;
    *) echo "❌ Invalid option, please choose 1-4." ;;
  esac
done
