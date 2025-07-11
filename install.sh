#!/bin/bash
set -e

INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

# Detect architecture
detect_arch() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7l | arm) echo "arm" ;;
    i386 | i686) echo "386" ;;
    *) echo "unsupported" ;;
  esac
}

# Get latest GitHub tag
get_latest_tag() {
  curl -s https://api.github.com/repos/levindoneto/ReverseTlsTunnel/releases/latest \
    | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Install RTT
install_rtt() {
  echo "🔧 Installing ReverseTlsTunnel (RTT)"
  sudo apt update -y && sudo apt install -y curl wget unzip file systemd || true

  ARCH_DL=$(detect_arch)
  if [[ "$ARCH_DL" == "unsupported" ]]; then
    echo "❌ Unsupported architecture: $(uname -m)"
    exit 1
  fi

  TAG=$(get_latest_tag)
  if [[ -z "$TAG" ]]; then
    echo "❌ Could not fetch release tag from GitHub"
    exit 1
  fi

  BIN_URL="https://github.com/levindoneto/ReverseTlsTunnel/releases/download/$TAG/rtt-linux-$ARCH_DL.zip"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  echo "📥 Downloading RTT binary for $ARCH_DL from $BIN_URL"
  wget -q "$BIN_URL" -O rtt.zip || { echo "❌ Failed to download binary from $BIN_URL"; exit 1; }

  unzip -o rtt.zip
  chmod +x "$BIN_NAME"
  file "$BIN_NAME" | grep -q "ELF" || { echo "❌ Invalid RTT binary format."; exit 1; }

  echo "⚙️ Writing config.env..."
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

  echo "🔧 Creating systemd service..."
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

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"

  echo -e "\n✅ RTT installed and running using release [$TAG] on $(uname -m)!"
}

# Uninstall RTT
uninstall_rtt() {
  echo "🗑️ Uninstalling RTT..."
  sudo systemctl stop "$SERVICE_NAME" || true
  sudo systemctl disable "$SERVICE_NAME" || true
  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reload
  sudo rm -rf "$INSTALL_DIR"
  echo "✅ RTT uninstalled successfully."
}

# Check status
check_status() {
  echo "📊 RTT Service Status:"
  systemctl status "$SERVICE_NAME" --no-pager || echo "ℹ️ RTT not installed."
}

# Main menu
while true; do
  echo -e "\n==== RTT Installer Menu ===="
  echo "1) نصب RTT (Install)"
  echo "2) حذف RTT (Uninstall)"
  echo "3) بررسی وضعیت سرویس (Status)"
  echo "0) خروج (Exit)"
  read -rp "➡️ انتخاب شما: " choice

  case $choice in
    1) install_rtt ;;
    2) uninstall_rtt ;;
    3) check_status ;;
    0) echo "👋 خروج."; exit 0 ;;
    *) echo "❗ گزینه نامعتبر، لطفا یکی از گزینه‌های بالا را وارد کنید." ;;
  esac
done
