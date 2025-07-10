#!/bin/bash

clear
echo -e "\e[96m============================="
echo -e "  Parham RTT Tunnel Script"
echo -e "=============================\e[0m"

# Select type
echo -e "\nSelect server type:"
echo -e "1) Iran (Client)"
echo -e "2) Foreign (Server)"
read -p "Enter choice [1 or 2]: " choice

if [[ "$choice" != "1" && "$choice" != "2" ]]; then
    echo -e "\e[91mInvalid choice. Exiting.\e[0m"
    exit 1
fi

read -p "Enter Token (or leave empty to auto-generate): " token
token=${token:-$(openssl rand -hex 8)}

read -p "Enter SNI (e.g. www.cloudflare.com) [default: pay.anten.ir]: " sni
sni=${sni:-pay.anten.ir}

if [ "$choice" == "1" ]; then
    read -p "Enter IPv4 of foreign server (outside Iran): " server_ip
else
    server_ip=""
fi

mkdir -p /etc/parham-rtt
touch /etc/parham-rtt/config.json

echo -e "\n📥 Downloading RTT binary..."
wget -q -O /usr/local/bin/rtt https://github.com/Lozy/danted-rtt/releases/latest/download/rtt

if [[ ! -f /usr/local/bin/rtt ]]; then
    echo -e "\e[91m❌ Failed to download RTT binary.\e[0m"
    exit 1
fi

chmod +x /usr/local/bin/rtt
echo -e "\e[92m✅ RTT installed successfully.\e[0m"

# Create config file
echo -e "\n🔧 Creating config file..."

if [ "$choice" == "1" ]; then
    cat <<EOF > /etc/parham-rtt/config.json
{
  "log_level": "INFO",
  "token": "$token",
  "server": "$server_ip",
  "sni": "$sni",
  "udp_timeout": 60
}
EOF
else
    cat <<EOF > /etc/parham-rtt/config.json
{
  "log_level": "INFO",
  "token": "$token",
  "listen": ":443",
  "tls": true
}
EOF
fi

echo -e "\e[92m✅ Config file created.\e[0m"

# Create systemd service
echo -e "\n⚙️  Creating systemd service..."

cat <<EOF > /etc/systemd/system/parham-rtt.service
[Unit]
Description=Parham RTT Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/rtt -config /etc/parham-rtt/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo -e "\e[93m🔧 Enabling and starting service...\e[0m"
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable parham-rtt.service
systemctl restart parham-rtt.service

sleep 2

if systemctl is-active --quiet parham-rtt.service; then
    echo -e "\n✅ RTT tunnel started and running!"
else
    echo -e "\n❌ Failed to start RTT. Use: journalctl -u parham-rtt -e"
fi

echo -e "\n🛠️  Token: \e[96m$token\e[0m"
echo -e "\n🔍 Check status: \e[90msystemctl status parham-rtt\e[0m"
echo -e "📄 View logs:     \e[90mjournalctl -u parham-rtt -f\e[0m"
echo -e "❌ Remove:        \e[90mbash <(curl -fsSL https://raw.githubusercontent.com/parhampahlevann/rtt-fix-parham-pahlevan/main/uninstall.sh)\e[0m"
