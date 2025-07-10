#!/bin/bash

GREEN='\033[0;32m'
NC='\033[0m'

BIN_URL="https://github.com/rapiz1/rathole/releases/download/v0.5.0/rathole-x86_64-unknown-linux-gnu.tar.gz"
BIN_NAME="rathole"
INSTALL_DIR="/usr/local/bin"

function install_rtt_binary() {
    echo -e "${GREEN}⬇️ در حال دریافت فایل باینری RTT...${NC}"
    wget -qO rtt.tar.gz "$BIN_URL" || { echo "❌ دریافت فایل ناموفق بود."; exit 1; }
    tar -xzf rtt.tar.gz
    mv "$BIN_NAME" "$INSTALL_DIR/rtt"
    chmod +x "$INSTALL_DIR/rtt"
    rm -f rtt.tar.gz
}

function uninstall_rtt() {
    echo -e "${GREEN}🧹 در حال حذف کامل RTT...${NC}"
    systemctl stop rtt
    systemctl disable rtt
    rm -f /etc/systemd/system/rtt.service
    rm -f /usr/local/bin/rtt
    rm -rf /etc/rtt
    echo -e "${GREEN}✅ حذف کامل شد.${NC}"
    exit 0
}

function create_server_config() {
    echo -e "${GREEN}📝 در حال ساخت کانفیگ سرور...${NC}"
    mkdir -p /etc/rtt
    cat > /etc/rtt/config.toml <<EOF
[server]
bind_addr = "0.0.0.0:23902"
default_token = "$1"

[server.services.v2ray1]
bind_addr = "0.0.0.0:8080"
token = "$1"

[server.services.v2ray2]
bind_addr = "0.0.0.0:8081"
token = "$1"
EOF
}

function create_client_config() {
    echo -e "${GREEN}📝 در حال ساخت کانفیگ کلاینت...${NC}"
    mkdir -p /etc/rtt
    cat > /etc/rtt/config.toml <<EOF
[client]
remote_addr = "$1:23902"
default_token = "$2"

[client.services.v2ray1]
local_addr = "127.0.0.1:2080"
remote_addr = "127.0.0.1:8080"

[client.services.v2ray2]
local_addr = "127.0.0.1:2081"
remote_addr = "127.0.0.1:8081"
EOF
}

function create_service() {
    echo -e "${GREEN}🔧 در حال ساخت سرویس systemd...${NC}"
    cat > /etc/systemd/system/rtt.service <<EOF
[Unit]
Description=RTT Tunnel
After=network.target

[Service]
ExecStart=$INSTALL_DIR/rtt -c /etc/rtt/config.toml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable rtt
    systemctl start rtt
    sleep 1
    systemctl status rtt --no-pager
}

function main_menu() {
    clear
    echo -e "${GREEN}============================="
    echo "     Parham Tunnel Setup"
    echo -e "=============================${NC}"
    echo "1. نصب روی سرور ایران (Client)"
    echo "2. نصب روی سرور خارج (Server)"
    echo "3. حذف کامل سرویس"
    echo "0. خروج"
    read -p "➤ گزینه مورد نظر را انتخاب کنید: " CHOICE

    case "$CHOICE" in
        1)
            read -p "🌐 آدرس IPv4 سرور خارج را وارد کنید: " SERVER_IP
            read -p "🔐 رمز توکن اتصال (Token): " TOKEN
            install_rtt_binary
            create_client_config "$SERVER_IP" "$TOKEN"
            create_service
            echo -e "${GREEN}✅ نصب کلاینت با موفقیت انجام شد.${NC}"
            ;;
        2)
            read -p "🔐 رمز توکن اتصال (Token): " TOKEN
            install_rtt_binary
            create_server_config "$TOKEN"
            create_service
            echo -e "${GREEN}✅ نصب سرور با موفقیت انجام شد.${NC}"
            ;;
        3)
            uninstall_rtt
            ;;
        0)
            exit 0
            ;;
        *)
            echo "❌ گزینه نامعتبر!"
            sleep 1
            main_menu
            ;;
    esac
}

main_menu
