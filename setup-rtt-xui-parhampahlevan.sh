#!/bin/bash

# Author: Parham Pahlevan
# Script: Multi-port RTT Tunnel installer + X-UI integration (optimized)

set -e

# Root check
if [ "$EUID" -ne 0 ]; then
  echo "❌ لطفاً اسکریپت را با دسترسی root اجرا کنید."
  exit 1
fi

# Ports you want RTT to listen on (6 ports now)
PORTS=(443 8443 2096 2087 23902 8081)

# Install dependencies
apt update -y
apt install -y curl unzip wget git systemd net-tools

# Install ReverseTlsTunnel (RTT)
INSTALL_DIR="/opt/rtt"
RTT_REPO="https://github.com/radkesvat/ReverseTlsTunnel"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
git clone "$RTT_REPO" .
chmod +x install.sh
./install.sh

# Create systemd services for each port
for PORT in "${PORTS[@]}"; do
  SERVICE_FILE="/etc/systemd/system/rtt-$PORT.service"
  cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=RTT Tunnel on port $PORT
After=network.target

[Service]
ExecStart=$INSTALL_DIR/rtt -mode server -listen :$PORT
Restart=always
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
done

# Reload systemd & enable services
systemctl daemon-reexec
systemctl daemon-reload

for PORT in "${PORTS[@]}"; do
  systemctl enable rtt-$PORT
  systemctl restart rtt-$PORT
  echo "✅ RTT فعال شد روی پورت: $PORT"
done

# Install x-ui panel
bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)

# Result message
clear
echo -e "\n🎉 نصب کامل شد!"
echo -e "🌀 پورت‌های فعال شده: ${PORTS[*]}"
echo -e "🌐 آدرس پنل X-UI: http://<IP-سرور>:54321"
echo -e "نام کاربری: admin | رمز عبور: admin"
