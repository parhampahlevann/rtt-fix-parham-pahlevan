#!/bin/bash

echo "========================================"
echo "      Parham RTT Tunnel Installer"
echo "========================================"
echo ""

echo "Select server type:"
echo "1) Iran (Client)"
echo "2) Foreign (Server)"
read -rp "Enter choice [1 or 2]: " server_type

read -rp "Enter Token (or leave empty to auto-generate): " token
token=${token:-$(head -c 12 /dev/urandom | xxd -p)}

read -rp "Enter SNI (e.g. www.cloudflare.com): " sni
if [[ -z "$sni" ]]; then
  echo "❌ SNI is required!"
  exit 1
fi

if [[ "$server_type" == "1" ]]; then
  read -rp "Enter IPv4 of foreign server (outside Iran): " foreign_ip
  if [[ -z "$foreign_ip" ]]; then
    echo "❌ Foreign server IP is required for client mode!"
    exit 1
  fi
fi

echo -e "\n🔽 Downloading RTT binary..."
mkdir -p /opt/rtt && cd /opt/rtt || exit
wget -q https://github.com/aymanbagabas/go-rtorrent/releases/latest/download/rtt-linux-amd64 -O rtt
chmod +x rtt
install -m 755 rtt /usr/local/bin/rtt

echo "✅ RTT installed successfully."

echo -e "\n🛠 Creating config file..."
mkdir -p /etc/parham-rtt

if [[ "$server_type" == "1" ]]; then
  cat <<EOF > /etc/parham-rtt/config.json
{
  "mode": "client",
  "server": "$foreign_ip",
  "sni": "$sni",
  "token": "$token"
}
EOF
else
  cat <<EOF > /etc/parham-rtt/config.json
{
  "mode": "server",
  "sni": "$sni",
  "token": "$token"
}
EOF
fi

echo -e "\n🧩 Creating systemd service..."
cat <<EOF > /etc/systemd/system/parham-rtt.service
[Unit]
Description=Parham RTT Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/rtt -config /etc/parham-rtt/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n🔄 Enabling and starting service..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable parham-rtt
systemctl start parham-rtt

sleep 1
status=$(systemctl is-active parham-rtt)

echo ""
if [[ "$status" == "active" ]]; then
  echo "✅ RTT tunnel started successfully!"
  echo "Token: $token"
else
  echo "❌ Failed to start RTT. Use: journalctl -u parham-rtt -e"
fi

echo ""
echo "📌 Check status:    systemctl status parham-rtt"
echo "📌 View logs:       journalctl -u parham-rtt -f"
echo "📌 Remove:          bash <(curl -fsSL https://raw.githubusercontent.com/parhampahlevann/rtt-fix-parham-pahlevan/main/uninstall.sh)"
