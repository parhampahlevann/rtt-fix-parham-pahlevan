#!/bin/bash

# ReverseTlsTunnel Auto Installer by Parham
# Based on original work by radkesvat, fixed traffic & stability issues

install_rtt_server() {
    echo "Installing RTT Server (on foreign server)..."
    mkdir -p /opt/rtt
    cd /opt/rtt || exit

    echo "Downloading RtTunnel binary..."
    arch=$(uname -m)
    if [[ $arch == "x86_64" ]]; then
        url="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/RtTunnel_Linux_amd64"
    elif [[ $arch == "aarch64" ]]; then
        url="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/RtTunnel_Linux_arm64"
    else
        echo "Unsupported architecture: $arch"
        exit 1
    fi

    curl -Lo RtTunnel "$url" && chmod +x RtTunnel

    read -rp "Enter listening port for RTT server (e.g. 443): " rtt_port
    read -rp "Enter shared token (same on both servers): " token

    cat > /opt/rtt/config_server.json <<EOF
{
  "mode": "server",
  "listen": ":$rtt_port",
  "token": "$token"
}
EOF

    cat > /etc/systemd/system/rtt.service <<EOF
[Unit]
Description=Reverse TLS Tunnel Server
After=network.target

[Service]
ExecStart=/opt/rtt/RtTunnel -c /opt/rtt/config_server.json
Restart=always
User=root
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable rtt
    systemctl restart rtt

    echo "✅ RTT Server installed and running on port $rtt_port"
}

install_rtt_client() {
    echo "Installing RTT Client (on Iran server)..."
    mkdir -p /opt/rtt
    cd /opt/rtt || exit

    echo "Downloading RtTunnel binary..."
    arch=$(uname -m)
    if [[ $arch == "x86_64" ]]; then
        url="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/RtTunnel_Linux_amd64"
    elif [[ $arch == "aarch64" ]]; then
        url="https://github.com/radkesvat/ReverseTlsTunnel/releases/latest/download/RtTunnel_Linux_arm64"
    else
        echo "Unsupported architecture: $arch"
        exit 1
    fi

    curl -Lo RtTunnel "$url" && chmod +x RtTunnel

    read -rp "Enter remote server IP (foreign server): " remote_ip
    read -rp "Enter remote server port: " remote_port
    read -rp "Enter shared token: " token
    read -rp "Enter SNI (e.g. pay.anten.ir): " sni
    read -rp "Enter local port to forward (e.g. 2083): " local_port
    read -rp "Enter how it should listen locally (e.g. :2083): " listen

cat > /opt/rtt/config_client.json <<EOF
{
  "mode": "client",
  "listen": "$listen",
  "remote": "$remote_ip:$remote_port",
  "token": "$token",
  "sni": "$sni",
  "target": "127.0.0.1:$local_port"
}
EOF

    cat > /etc/systemd/system/rtt.service <<EOF
[Unit]
Description=Reverse TLS Tunnel Client
After=network.target

[Service]
ExecStart=/opt/rtt/RtTunnel -c /opt/rtt/config_client.json
Restart=always
User=root
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable rtt
    systemctl restart rtt

    echo "✅ RTT Client installed and forwarding to 127.0.0.1:$local_port"
}

uninstall_rtt() {
    echo "Removing RTT service..."
    systemctl stop rtt
    systemctl disable rtt
    rm -f /etc/systemd/system/rtt.service
    rm -rf /opt/rtt
    systemctl daemon-reload
    echo "✅ RTT completely removed."
}

show_menu() {
    echo "============ Reverse TLS Tunnel Installer ============"
    echo "1) Install on FOREIGN server (RTT Server)"
    echo "2) Install on IRAN server (RTT Client)"
    echo "3) Uninstall RTT"
    echo "0) Exit"
    echo "======================================================"
    read -rp "Select an option [0-3]: " opt

    case "$opt" in
        1) install_rtt_server ;;
        2) install_rtt_client ;;
        3) uninstall_rtt ;;
        0) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
}

show_menu
