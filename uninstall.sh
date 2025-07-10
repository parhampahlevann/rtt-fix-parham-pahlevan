#!/bin/bash

echo "🔧 Uninstalling ParhamTunnel (RTT)..."

# Stop and disable systemd service
systemctl stop rtt.service
systemctl disable rtt.service
rm -f /etc/systemd/system/rtt.service
systemctl daemon-reload

# Remove RTT binary if exists
rm -f /usr/local/bin/rtt

# Remove logs and configs (optional)
rm -rf /etc/rtt
rm -rf /var/log/rtt

echo "✅ RTT successfully uninstalled from the system."
