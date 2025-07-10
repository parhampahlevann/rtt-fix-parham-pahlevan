#!/bin/bash

function install_rtt() {
  echo "🚀 در حال نصب RTT..."

  apt update -y
  apt install curl wget unzip -y

  mkdir -p /opt/rtt
  cd /opt/rtt

  wget https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/rtt-linux-amd64.zip -O rtt.zip
  unzip -o rtt.zip
  chmod +x rtt

  cat > /opt/rtt/config.json <<EOF
{
  "listen": [
    {"local": "0.0.0.0:443", "remote": "127.0.0.1:2087"},
    {"local": "0.0.0.0:8081", "remote": "127.0.0.1:8081"},
    {"local": "0.0.0.0:23902", "remote": "127.0.0.1:23902"}
  ]
}
EOF

  cat > /etc/systemd/system/rtt.service <<EOF
[Unit]
Description=RTT Reverse Tunnel
After=network.target

[Service]
ExecStart=/opt/rtt/rtt -config /opt/rtt/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable rtt
  systemctl restart rtt

  echo "✅ نصب RTT با موفقیت انجام شد!"
}

function install_xui() {
  echo "🔧 در حال نصب پنل X-UI..."
  bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)
  echo "✅ X-UI نصب شد. آدرس پنل: http://IP:54321"
}

function restart_rtt() {
  echo "♻️ در حال ریستارت RTT..."
  systemctl restart rtt
  echo "✅ سرویس RTT ریستارت شد."
}

function show_menu() {
  echo "========================================="
  echo "  🎯 اسکریپت نصب RTT - Parham Pahlevan"
  echo "========================================="
  echo "1) نصب RTT (با پورت 443, 8081, 23902)"
  echo "2) نصب پنل X-UI"
  echo "3) ریستارت سرویس RTT"
  echo "4) خروج"
  echo
  read -p "👉 گزینه مورد نظر را انتخاب کنید [1-4]: " choice

  case $choice in
    1) install_rtt ;;
    2) install_xui ;;
    3) restart_rtt ;;
    4) echo "خروج..."; exit 0 ;;
    *) echo "❌ گزینه نامعتبر."; sleep 1; show_menu ;;
  esac
}

# شروع اجرای منو
while true; do
  clear
  show_menu
done
