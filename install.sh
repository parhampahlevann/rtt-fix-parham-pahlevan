#!/bin/bash
set -e

# 🔧 نصب بهینه ReverseTlsTunnel - نسخه بدون وابستگی به API
VERSION="v1.4.2"
BASE_URL="https://github.com/levindoneto/ReverseTlsTunnel/releases/download/$VERSION"
INSTALL_DIR="/opt/reversetlstunnel"
BIN_NAME="rtt"
SERVICE_NAME="rtt"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_FILE="$INSTALL_DIR/config.env"

# 📌 تشخیص معماری
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_DL="amd64" ;;
  aarch64 | arm64) ARCH_DL="arm64" ;;
  armv7l | arm) ARCH_DL="arm" ;;
  i386 | i686) ARCH_DL="386" ;;
  *) echo "❌ معماری پشتیبانی نمی‌شود: $ARCH" && exit 1 ;;
esac

# 📦 نصب پکیج‌های موردنیاز
sudo apt update -y && sudo apt install -y curl wget unzip file systemd || true

# 📁 آماده‌سازی مسیر نصب
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ⬇️ دانلود باینری مخصوص معماری
BIN_URL="$BASE_URL/rtt-linux-$ARCH_DL.zip"
echo "📥 در حال دانلود باینری RTT برای $ARCH_DL از:"
echo "$BIN_URL"

wget -q "$BIN_URL" -O rtt.zip || {
  echo "❌ خطا در دانلود فایل از GitHub. لطفاً اتصال اینترنت را بررسی کنید."
  exit 1
}

unzip -o rtt.zip
chmod +x "$BIN_NAME"

# 🧪 بررسی فرمت فایل
file "$BIN_NAME" | grep -q "ELF" || {
  echo "❌ فایل دانلود شده معتبر نیست یا خراب شده."
  exit 1
}

# ⚙️ ساخت فایل config.env
echo "⚙️ نوشتن config.env"
cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
USE_COMPRESSION=true
RECONNECT_DELAY=5
MAX_RETRIES=0
EOF

# 📦 بارگذاری متغیرها
source "$CONFIG_FILE"
EXTRA_FLAGS=""
[[ "$USE_COMPRESSION" == "true" ]] && EXTRA_FLAGS="-z"

# 🧩 ساخت سرویس systemd
echo "🔧 ساخت سرویس systemd"
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

# 🚀 فعال‌سازی سرویس
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo -e "\n✅ نصب RTT با موفقیت انجام شد! نسخه: $VERSION"
