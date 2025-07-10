#!/bin/bash

# رنگ‌ها برای لاگ‌ها
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}نصب RTT و X-ui توسط Parham Pahlevan شروع شد...${NC}"

# آپدیت سیستم
apt update && apt upgrade -y

# نصب ابزارهای پایه
apt install -y curl wget unzip socat git cron

# نصب RTT (نسخه بهینه‌شده با مولتی‌پورت)
mkdir -p /opt/rtt && cd /opt/rtt
wget -O RtTunnel https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/RtTunnel
chmod +x RtTunnel

# ایجاد سرویس systemd برای اجرای مداوم
cat > /etc/systemd/system/rtt.service << EOF
[Unit]
Description=Reverse TLS Tunnel
After=network.target

[Service]
ExecStart=/opt/rtt/RtTunnel server -listen :443,:8443,:2087,:2096,:23902,:8081
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# راه‌اندازی سرویس RTT
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable rtt
systemctl start rtt

echo -e "${GREEN}RTT نصب و راه‌اندازی شد ✅${NC}"

# نصب X-ui
bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)

echo -e "${GREEN}نصب کامل شد. X-ui در آدرس زیر در دسترس است:${NC}"
echo -e "${GREEN}http://<IP>:54321 با یوزر admin و رمز admin${NC}"
