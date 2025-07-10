#!/bin/bash

set -e

# رنگ‌ها
green='\e[32m'
red='\e[31m'
yellow='\e[33m'
blue='\e[34m'
nc='\e[0m'

echo -e "${green}==> Parham RTT Installer vFinal [Auto Fix]${nc}"

# معماری سیستم
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_BIN="rtt-linux-amd64" ;;
    aarch64) ARCH_BIN="rtt-linux-arm64" ;;
    armv7l) ARCH_BIN="rtt-linux-arm" ;;
    *) echo -e "${red}❌ Unsupported architecture: $ARCH${nc}"; exit 1 ;;
esac

BIN_URL="https://github.com/ParhamPahlevanN/rtt-fix-parham-pahlevan/raw/main/binaries/$ARCH_BIN"

install_rtt() {
    echo -e "${blue}⬇️ Downloading RTT binary for $ARCH_BIN...${nc}"
    curl -L "$BIN_URL" -o /usr/local/bin/rtt || { echo -e "${red}❌ Failed to download binary.${nc}"; exit 1; }
    chmod +x /usr/local/bin/rtt

    echo -e "${green}✅ RTT installed successfully.${nc}"
}

create_config() {
    mkdir -p /etc/rtt
    read -p "Enter Token (or leave empty to auto-generate): " TOKEN
    TOKEN=${TOKEN:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)}

    read -p "Enter SNI [default: pay.anten.ir]: " SNI
    SNI=${SNI:-pay.anten.ir}

    read -p "Enter IPv4 of foreign server (outside Iran): " SERVER_IP

    cat > /etc/rtt/config.json <<EOF
{
  "token": "$TOKEN",
  "sni": "$SNI",
  "foreign_server_ip": "$SERVER_IP"
}
EOF
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

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable parham-rtt
    systemctl restart parham-rtt

    sleep 2
    systemctl status parham-rtt --no-pager
}

test_port() {
    echo -e "${blue}🔍 Testing port 443 connectivity to foreign server...${nc}"
    timeout 5 bash -c "</dev/tcp/${SERVER_IP}/443" && echo -e "${green}✅ Port 443 reachable${nc}" || echo -e "${red}❌ Port 443 blocked or unreachable${nc}"
}

uninstall() {
    echo -e "${yellow}⚠️ Uninstalling RTT...${nc}"
    systemctl stop parham-rtt || true
    systemctl disable parham-rtt || true
    rm -f /usr/local/bin/rtt /etc/systemd/system/parham-rtt.service
    rm -rf /etc/rtt
    systemctl daemon-reload
    echo -e "${green}✅ Uninstalled successfully.${nc}"
    exit 0
}

main_menu() {
    echo -e "${blue}
1) Install as Iran (Client)
2) Uninstall
${nc}"
    read -p "Choose option [1-2]: " CHOICE

    case "$CHOICE" in
        1)
            install_rtt
            create_config
            test_port
            create_service
            ;;
        2)
            uninstall
            ;;
        *)
            echo -e "${red}❌ Invalid choice${nc}"
            exit 1
            ;;
    esac
}

main_menu
