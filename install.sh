#!/bin/bash

function install_rtt() {
  echo "🚀 Installing RTT..."

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

  echo "✅ RTT installed successfully!"
}

function install_xui() {
  echo "🔧 Installing X-UI panel..."
  bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)
  echo "✅ X-UI installation completed. Panel: http://<your_ip>:54321"
}

function restart_rtt() {
  echo "♻️ Restarting RTT service..."
  systemctl restart rtt
  echo "✅ RTT service restarted."
}

function show_menu() {
  echo "========================================="
  echo "     RTT Setup Script by Parham Pahlevan"
  echo "========================================="
  echo "1) Install RTT (multi-port: 443, 8081, 23902)"
  echo "2) Install X-UI Panel"
  echo "3) Restart RTT Service"
  echo "4) Exit"
  echo
  read -p "👉 Enter your choice [1-4]: " choice

  case $choice in
    1) install_rtt ;;
    2) install_xui ;;
    3) restart_rtt ;;
    4) echo "Exiting..."; exit 0 ;;
    *) echo "❌ Invalid option."; sleep 1; show_menu ;;
  esac
}

# Start Menu Loop
while true; do
  clear
  show_menu
done
