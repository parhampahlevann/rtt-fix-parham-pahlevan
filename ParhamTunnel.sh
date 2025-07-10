#!/bin/bash

set -e

echo -e "\n\033[1;36m========== Parham RTT Tunnel Script ==========\033[0m\n"

function uninstall() {
    echo -e "\n🔧 Uninstalling RTT Service..."
    systemctl stop parham-rtt 2>/dev/null || true
    systemctl disable parham-rtt 2>/dev/null || true
    rm -f /etc/systemd/system/parham-rtt.service
    rm -rf /etc/parham-rtt
    rm -f /usr/local/bin/rtt
    echo -e "✅ RTT completely removed.\n"
    exit 0
}

function check_port_443() {
    if ss -tuln | grep -q ':443'; then
        echo -e "\n❌ Port 443 is already in use! Please stop the conflicting service and try again."
        exit 1
    fi
}

function detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        *) echo "unsupported" ;;
    esac
}

function download_rtt_binary() {
    ARCH=$(detect_arch)
    if [[ "$ARCH" == "unsupported" ]]; then
        echo -e "\n❌ Unsupported architecture: $(uname -m)"
        exit 1
    fi
    echo -e "\n📥 Downloading RTT binary for $ARCH..."
    curl -L -o /usr/local/bin/rtt https://github.com/azadnetworks/ReverseTlsTunnel/releases/latest/download/rtt-linux-$ARCH
    chmod +x /usr/local/bin/rtt
    file /usr/local/bin/rtt | grep -qi "ELF" || { echo -e "\n❌ Failed to download valid RTT binary."; exit 1; }
    echo -e "✅ RTT installed successfully."
}

function create_config() {
    mkdir -p /etc/parham-rtt
    echo -e "\n🔧 Creating config file..."

    read -p $'\nSelect server type:\n1) Iran (Client)\n2) Foreign (Server)\n\nEnter choice [1 or 2]: ' SERVER_TYPE
    if [[ "$SERVER_TYPE" != "1" && "$SERVER_TYPE" != "2" ]]; then
        echo "❌ Invalid choice"; exit 1
    fi

    read -p "Enter Token (or leave empty to auto-generate): " TOKEN
    TOKEN=${TOKEN:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}

    read -p "Enter SNI (e.g. www.cloudflare.com) [default: pay.anten.ir]: " SNI
    SNI=${SNI:-pay.anten.ir}

    if [[ "$SERVER_TYPE" == "1" ]]; then
        read -p "Enter IPv4 of foreign server (outside Iran): " SERVER_IP
        cat <<EOF > /etc/parham-rtt/config.json
{
  "remote": "$SERVER_IP:443",
  "key": "$TOKEN",
  "sni": "$SNI"
}
EOF
    else
        cat <<EOF > /etc/parham-rtt/config.json
{
  "listen": ":443",
  "key": "$TOKEN"
}
EOF
    fi

    echo -e "✅ Config saved to /etc/parham-rtt/config.json"
    echo -e "Token: $TOKEN"
}

function create_service() {
    echo -e "\n🔧 Creating systemd service..."
    cat <<EOF > /etc/systemd/system/parham-rtt.service
[Unit]
Description=Parham RTT Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/rtt -config /etc/parham-rtt/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    echo -e "🟦 Enabling and starting service..."
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable parham-rtt
    systemctl restart parham-rtt

    sleep 2
    if systemctl is-active --quiet parham-rtt; then
        echo -e "\n✅ RTT Tunnel is now running!"
    else
        echo -e "\n❌ Failed to start RTT. Use: journalctl -u parham-rtt -e"
    fi
}

function show_menu() {
    echo -e "\n\033[1;32m==== MENU ====\033[0m"
    echo "1) Install RTT Tunnel"
    echo "2) Uninstall RTT"
    echo "0) Exit"
    read -p "Enter choice: " CHOICE
    case $CHOICE in
        1)
            check_port_443
            download_rtt_binary
            create_config
            create_service
            ;;
        2)
            uninstall
            ;;
        0)
            exit 0
            ;;
        *)
            echo "❌ Invalid option"; exit 1
            ;;
    esac
}

# Run
show_menu
