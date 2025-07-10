#!/bin/bash

# نصب پیشنیازها
apt update -y && apt install curl wget unzip -y

# دانلود RTT و خارج کردن فایل‌ها
mkdir -p /opt/rtt && cd /opt/rtt
wget https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-amd64.zip -O rtt.zip
unzip rtt.zip
chmod +x rtt

# افزودن پورت‌ها: 8081 و 23902 و 443
cat > /opt/rtt/config.json <<EOF
{
  "listen": [
    {"local": "0.0.0.0:443", "remote": "127.0.0.1:2087"},
    {"local": "0.0.0.0:8081", "remote": "127.0.0.1:8081"},
    {"local": "0.0.0.0:23902", "remote": "127.0.0.1:23902"}
  ]
}
EOF

# ساخت سرویس systemd
cat > /etc/systemd/system/rtt.service <<EOF
[Unit]
Description=RTT Service
After=network.target

[Service]
ExecStart=/opt/rtt/rtt -config /opt/rtt/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# فعالسازی و شروع سرویس
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable rtt
systemctl restart rtt

echo "✅ RTT نصب و فعال شد."
