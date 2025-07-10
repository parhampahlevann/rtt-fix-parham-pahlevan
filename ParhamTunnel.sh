#!/bin/bash

echo -e "\e[96m=============================="
echo -e " Parham RTT Tunnel Script"
echo -e "==============================\e[0m"

echo -e "\nSelect an option:"
echo "1) Install as Iran Client"
echo "2) Install as Foreign Server"
echo "3) Uninstall RTT Tunnel"
read -p "Enter your choice [1-3]: " CHOICE

if [[ "$CHOICE" == "3" ]]; then
  echo "🚫 Uninstalling ParhamTunnel (RTT)..."
  systemctl stop parham-rtt
  systemctl disable parham-rtt
  rm -f /etc/systemd/system/parham-rtt.service
  rm -f /usr/local/bin/rtt
  rm -rf /etc/parham-rtt
  systemctl daemon-reload
  echo "✅ RTT successfully uninstalled from the system."
  exit 0
fi

# شناسایی معماری
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_DL="amd64" ;;
  aarch64) ARCH_DL="arm64" ;;
  armv7l|armhf) ARCH_DL="arm" ;;
  *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

read -p "Enter Token (or leave empty to auto-generate): " TOKEN
if [[ -z "$TOKEN" ]]; then
  TOKEN=$(cat /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)
fi

read -p "Enter SNI (default: pay.anten.ir): " SNI
SNI=${SNI:-pay.anten.ir}

if [[ "$CHOICE" == "1" ]]; then
  read -p "Enter IPv4 of foreign server (outside Iran): " SERVER_IP
fi

echo -e "\n📥 Downloading RTT binary for $ARCH..."
curl -L -o /usr/local/bin/rtt "https://github.com/trimstray/reverse-tls-tunnel/releases/latest/download/rtt_linux_${ARCH_DL}" || { echo "❌ Failed to download RTT binary"; exit 1; }
chmod +x /usr/local/bin/rtt

echo "✅ RTT installed successfully."

CONFIG_DIR="/etc/parham-rtt"
mkdir -p "$CONFIG_DIR"

if [[ "$CHOICE" == "1" ]]; then
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "mode": "client",
  "remote": "$SERVER_IP:443",
  "token": "$TOKEN",
  "sni": "$SNI"
}
EOF
else
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "mode": "server",
  "listen": ":443",
  "token": "$TOKEN"
}
EOF
fi

echo "🔧 Creating systemd service..."

cat > /etc/systemd/system/parham-rtt.service <<EOF
[Unit]
Description=Parham RTT Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/rtt -config $CONFIG_DIR/config.json
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable parham-rtt
systemctl start parham-rtt

sleep 2

if systemctl is-active --quiet parham-rtt; then
  echo -e "\n✅ RTT tunnel started successfully!"
  echo "Token: $TOKEN"
else
  echo -e "\n❌ Failed to start RTT."
  echo "🔍 To debug: journalctl -u parham-rtt -e"
fi

echo -e "\n📌 Status:   systemctl status parham-rtt"
echo -e "📌 Logs:     journalctl -u parham-rtt -f"
echo -e "🗑️  Uninstall any time: re-run this script and select option 3"
