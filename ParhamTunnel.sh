#!/bin/bash

set -e

green='\e[32m'
red='\e[31m'
yellow='\e[33m'
blue='\e[34m'
nc='\e[0m'

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_BIN="rtt-linux-amd64" ;;
    aarch64) ARCH_BIN="rtt-linux-arm64" ;;
    armv7l) ARCH_BIN="rtt-linux-arm" ;;
    *) echo -e "${red}❌ Unsupported architecture: $ARCH${nc}"; exit 1 ;;
esac

BIN_URL="https://github.com/ParhamPahlevanN/rtt-fix-parham-pahlevan/raw/main/binaries/$ARCH_BIN"

install_rtt_binary() {
    echo -e "${blue}⬇️ Downloading RTT binary...${nc}"
    curl -L "$BIN_URL" -o /usr/local/bin/rtt
    chmod +x /usr/local/bin/rtt
    echo -e "${green}✅ RTT binary installed.${nc}"
}

install_client() {
    install_rtt_binary
    mkdir -p /etc/rtt
    read -p "Enter Token (or leave blank to auto-generate): " TOKEN
    TOKEN=${TOKEN:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)}

    read -p "Enter SNI [default: pay.anten.ir]: " SNI
    SNI=${SNI:-pay.anten.ir}

    read -p "Enter IPv4 of foreign server (outside Iran): " SERVER_IP

    echo -e "${blue}🔌 Testing connectivity to $SERVER_IP:443...${nc}"
    timeout 5 bash -c "</dev/tcp/$SERVER_IP/443" && echo -e "${green}✅ Port 443 open${nc}" || echo -e "${red}⚠️ Port 443 seems closed or filtered${nc}"

    cat > /etc/rtt/config.json <<EOF
{
  "token": "$TOKEN",
  "sni": "$SNI",
  "foreign_server_ip": "$SERVER_IP"
}
EOF

    create_service
}

install_server() {
    install_rtt_binary
    mkdir -p /etc/rtt
    read -p "Enter Token (same as client): " TOKEN

    cat > /etc/rtt/config.json <<EOF
{
  "token": "$TOKEN",
  "listen": ":443"
}
EOF

    create_service
}

create_service() {
    cat > /etc/systemd/system/parham-rtt.service <<EOF
[Unit]
Description=Parham RTT Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/rtt -config /etc/rtt/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable parham-rtt
    systemctl restart parham-rtt
    sleep 2
    systemctl status parham-rtt --no-pager
}

uninstall_rtt() {
    echo -e "${yellow}🗑️ Uninstalling RTT...${nc}"
    systemctl stop parham-rtt || true
    systemctl disable parham-rtt || true
    rm -f /usr/local/bin/rtt
    rm -f /etc/systemd/system/parham-rtt.service
    rm -rf /etc/rtt
    systemctl daemon-reload
    echo -e "${green}✅ RTT completely uninstalled.${nc}"
    exit 0
}

main_menu() {
    echo -e "${blue}
🔧 Select installation mode:
1) Iran (Client)
2) Foreign (Server)
3) Uninstall RTT
${nc}"
    read -p "Enter choice [1-3]: " CHOICE

    case "$CHOICE" in
        1) install_client ;;
        2) install_server ;;
        3) uninstall_rtt ;;
        *) echo -e "${red}❌ Invalid choice${nc}"; exit 1 ;;
    esac
}

main_menu
