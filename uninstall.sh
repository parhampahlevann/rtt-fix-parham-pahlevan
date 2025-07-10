#!/bin/bash

echo "🧹 Uninstalling Parham RTT Tunnel..."

systemctl stop parham-rtt
systemctl disable parham-rtt
rm -f /etc/systemd/system/parham-rtt.service
rm -rf /etc/parham-rtt
rm -f /usr/local/bin/rtt
rm -rf /opt/rtt

systemctl daemon-reload

echo "✅ RTT successfully uninstalled."
