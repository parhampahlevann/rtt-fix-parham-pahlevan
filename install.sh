#!/bin/bash set -e

SERVICE_NAME="optimized-rtt" INSTALL_DIR="/opt/optimized-rtt" BIN_NAME="rtt" CONFIG_FILE="$INSTALL_DIR/config.env" VERSION="v1.4.2"

function detect_arch() { ARCH=$(uname -m) case "$ARCH" in x86_64) FLAV="amd64" ;; aarch64 | arm64) FLAV="arm64" ;; armv7l | arm) FLAV="arm" ;; i386 | i686) FLAV="386" ;; *) echo "❌ Unsupported architecture: $ARCH" && exit 1 ;; esac }

function install_rtt() { echo "🔧 Installing Optimized ReverseTlsTunnel..." detect_arch

sudo apt update -y sudo apt install -y wget unzip file git build-essential golang systemd

sudo mkdir -p "$INSTALL_DIR" cd "$INSTALL_DIR"

URL="https://dl.parham.run/rtt-linux-$FLAV.zip" echo "📥 Downloading RTT from $URL" if wget -q "$URL" -O rtt.zip; then unzip -o rtt.zip chmod +x "$BIN_NAME" file "$BIN_NAME" | grep -q ELF || { echo "❌ Invalid binary format. Falling back to source build." build_from_source } else echo "⚠️ RTT binary not found. Building from source..." build_from_source fi

echo "🛠️ Writing config.env..." cat <<EOF | sudo tee "$CONFIG_FILE" > /dev/null REMOTE_HOST=your.server.ip REMOTE_PORT=443 LOCAL_PORT=22 USE_COMPRESSION=true KEEP_ALIVE=60 RECONNECT_DELAY=5 MAX_RETRIES=0 MULTIPLEX=8 EOF

echo "🔧 Creating systemd service..." sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF [Unit] Description=Optimized ReverseTlsTunnel Service After=network-online.target Wants=network-online.target

[Service] Type=simple WorkingDirectory=$INSTALL_DIR EnvironmentFile=$CONFIG_FILE ExecStart=$INSTALL_DIR/$BIN_NAME client \ -s $REMOTE_HOST:$REMOTE_PORT \ -l 0.0.0.0:$LOCAL_PORT \ --session-ticket \ --tcp-keep

