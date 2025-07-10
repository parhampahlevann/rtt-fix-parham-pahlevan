#!/bin/bash

# نصب ابزارهای لازم
apt update -y && apt install curl wget unzip -y

# ساخت مسیر و دانلود RTT
mkdir -p /opt/rtt && cd /opt/rtt
wget https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-amd64.zip -O rtt.zip
unzip -o rtt.zip
chmod +x rtt

# تنظیمات کانفیگ چند پورت
cat > /opt/rtt/config.json <<EOF
{
  "listen": [
    {"local": "0.0.0.0:443", "remote": "127.0.0.1:2087"},
    {"local": "0.0.0.0:8081", "remote": "127.0.0.1:8081"},
    {"local": "0.0.0.0:23902", "remote": "127.0.0.1:23902"}
  ]
}
EOF

# ساخت فایل سرویس systemd
cat > /etc/systemd/system/rtt.service <<EOF
[Unit]
Description=RTT Reverse Tunnel Service
After=network.target

[Service]
ExecStart=/opt/rtt/rtt -config /opt/rtt/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# فعال‌سازی سرویس
systemctl daemon-reload
systemctl enable rtt
systemctl restart rtt

echo "✅ نصب کامل شد! سرویس روی پورت‌های 443, 8081, و 23902 فعال است."
