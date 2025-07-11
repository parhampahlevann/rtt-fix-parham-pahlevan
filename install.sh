#!/bin/bash
set -e
echo "🔧 Installing Optimized ReverseTlsTunnel"

# Config
VERSION="v1.4.2"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) FLAV="amd64" ;;
  aarch64|arm64) FLAV="arm64" ;;
  armv7l|arm) FLAV="arm" ;;
  i386|i686) FLAV="386" ;;
  *) echo "❌ Unsupported arch: $ARCH"; exit 1 ;;
esac

# Install dependencies
sudo apt update -y
sudo apt install -y wget unzip file systemd

# Setup
PREFIX="/opt/rtt-optimized"
BIN="$PREFIX/rtt"
mkdir -p "$PREFIX"
cd "$PREFIX"

# Download binary
URL="https://dl.parham.run/rtt-linux-$FLAV.zip"
echo "📥 Downloading from $URL"
wget -q --show-progress "$URL" -O app.zip
unzip -o app.zip
chmod +x rtt

# Validate
file rtt | grep -q ELF || { echo "❌ Invalid binary"; exit 1; }

# Create default config
cat <<EOF | sudo tee "$PREFIX/config.env" > /dev/null
REMOTE_HOST=your.server.ip
REMOTE_PORT=443
LOCAL_PORT=22
MAX_RETRIES=0
COMPRESSION=true
MULTIPLEX=8
EOF

# Service file with performance tuning
sudo tee /etc/systemd/system/rtt-optimized.service > /dev/null <<EOF
[Unit]
Description=RTT Optimized Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
EnvironmentFile=$PREFIX/config.env
ExecStart=$BIN client \
  -s \$REMOTE_HOST:\$REMOTE_PORT \
  -l 0.0.0.0:\$LOCAL_PORT \
  --sock-buf 262144 \
  --tcp-keepalive 60 \
  --session-ticket \
  \$( [[ "\$COMPRESSION" == "true" ]] && echo "-z") \
  --multiplex \$MULTIPLEX \
  --reconnect-delay 5 \
  --max-retries \$MAX_RETRIES
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Enable & start
sudo systemctl daemon-reload
sudo systemctl enable rtt-optimized
sudo systemctl restart rtt-optimized

echo "✅ RTT optimized installed and running!"
systemctl status rtt-optimized --no-pager
