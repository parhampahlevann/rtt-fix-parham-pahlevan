#!/bin/bash

echo "=============================="
echo "   Parham RTT Tunnel Script"
echo "=============================="
echo
echo "Select server type:"
echo "1) Iran (Client)"
echo "2) Foreign (Server)"
read -p "Enter choice [1 or 2]: " server_type

read -p "Enter Token (or leave empty to generate one): " token
if [ -z "$token" ]; then
  token=$(openssl rand -hex 12)
  echo "Generated Token: $token"
fi

read -p "Enter SNI (e.g. www.cloudflare.com): " sni
[ -z "$sni" ] && sni="www.cloudflare.com"

if [ "$server_type" = "1" ]; then
  read -p "Enter IPv4 of foreign server: " foreign_ip
fi

# Default ports
ports=(443 8081 23902)

# Download RTT binary
echo "[*] Downloading RTT..."
wget -qO rtt https://github.com/Red5d/rtunnel/releases/latest/download/rtunnel-linux-amd64
chmod +x rtt
mv rtt /usr/local/bin/rtt

# Create config file
mkdir -p /etc/parham-rtt
config_file="/etc/parham-rtt/config.json"

if [ "$server_type" = "1" ]; then
  cat > "$config_file" <<EOF
{
  "role": "client",
  "token": "$token",
  "server": "$foreign_ip",
  "sni": "$sni",
  "tunnels": {
EOF

  for port in "${ports[@]}"; do
    echo "    \"$port\": {\"listen\": \"127.0.0.1:$port\"}," >> "$config_file"
  done

  sed -i '$ s/,$//' "$config_file" # remove last comma
  echo "  }" >> "$config_file"
  echo "}" >> "$config_file"

else
  cat > "$config_file" <<EOF
{
  "role": "server",
  "token": "$token",
  "tunnels": {
EOF

  for port in "${ports[@]}"; do
    echo "    \"$port\": {\"listen\": \":$port\"}," >> "$config_file"
  done

  sed -i '$ s/,$//' "$config_file"
  echo "  }" >> "$config_file"
  echo "}" >> "$config_file"
fi

# Systemd service
cat > /etc/systemd/system/parham-rtt.service <<EOF
[Unit]
Description=Parham RTT Tunnel Service
After=network.target

[Service]
ExecStart=/usr/local/bin/rtt -config /etc/parham-rtt/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable parham-rtt
systemctl restart parham-rtt

echo
echo "✅ RTT tunnel installed and started successfully!"
echo "Token: $token"
echo
echo "To check status: systemctl status parham-rtt"
echo "To remove: bash <(curl -fsSL https://raw.githubusercontent.com/parhampahlevann/rtt-fix-parham-pahlevan/main/uninstall.sh)"
