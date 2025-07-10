#!/bin/bash

set -e

RED='\e[91m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
RESET='\e[0m'

arch=$(uname -m)
binary_url=""

# تعیین باینری مناسب بر اساس معماری
case "$arch" in
  x86_64) binary_url="https://github.com/ParhamPahlevanN/rtt-fix-parham-pahlevan/raw/main/binaries/rtt-linux-amd64" ;;
  aarch64) binary_url="https://github.com/ParhamPahlevanN/rtt-fix-parham-pahlevan/raw/main/binaries/rtt-linux-arm64" ;;
  armv7l) binary_url="https://github.com/ParhamPahlevanN/rtt-fix-parham-pahlevan/raw/main/binaries/rtt-linux-arm" ;;
  *) echo -e "${RED}Unsupported architecture: $arch${RESET}"; exit 1 ;;
esac

echo -e "${YELLOW}Parham RTT Tunnel Script${RESET}"
echo ""
echo "1) Iran (Client)"
echo "2) Foreign (Server)"
echo "3) Uninstall RTT"
read -p "Enter choice [1 or 2 or 3]: " choice

if [[ $choice == 3 ]]; then
  echo -e "${YELLOW}Removing RTT...${RESET}"
  systemctl stop parham-rtt.service || true
  systemctl disable parham-rtt.service || true
  rm -f /etc/systemd/system/parham-rtt.service
  rm -f /usr/local/bin/rtt
  rm -f /usr/local/bin/config.json
  systemctl daemon-reload
  echo -e "${GREEN}✅ RTT successfully removed.${RESET}"
  exit 0
fi

read -p "Enter Token (or leave empty to auto-generate): " token
token=${token:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)}

read -p "Enter SNI (e.g. www.cloudflare.com) [Default: pay.anten.ir]: " sni
sni=${sni:-pay.anten.ir}

read -p "Enter IPv4 of foreign server (outside Iran): " server_ip

# تست باز بودن پورت 443 روی آی‌پی
echo -e "${BLUE}Testing connection to ${server_ip}:443...${RESET}"
timeout 3 bash -c "</dev/tcp/${server_ip}/443" 2>/dev/null \
  && echo -e "${GREEN}✅ Port 443 is open${RESET}" \
  || { echo -e "${RED}❌ Port 443 is not reachable. Check firewall or IP.${RESET}"; exit 1; }

echo -e "${BLUE}📥 Downloading RTT binary...${RESET}"
curl -L "$binary_url" -o /usr/local/bin/rtt
chmod +x /usr/local/bin/rtt

echo -e "${GREEN}✅ RTT binary installed successfully.${RESET}"

echo -e "${BLUE}⚙️ Creating config file...${RESET}"
cat <<EOF > /usr/local/bin/config.json
{
  "remote": "$server_ip:443",
  "token": "$token",
  "sni": "$sni"
}
EOF

echo -e "${BLUE}⚙️ Creating systemd service...${RESET}"
cat <<EOF > /etc/systemd/system/parham-rtt.service
[Unit]
Description=Parham RTT Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/rtt -config /usr/local/bin/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable parham-rtt.service
systemctl restart parham-rtt.service

sleep 2
if systemctl is-active --quiet parham-rtt.service; then
  echo -e "${GREEN}✅ RTT tunnel installed and started successfully!${RESET}"
  echo -e "${YELLOW}Token: $token${RESET}"
else
  echo -e "${RED}❌ Failed to start RTT.${RESET}"
  echo -e "📄 View logs: ${BLUE}journalctl -u parham-rtt -e${RESET}"
fi
