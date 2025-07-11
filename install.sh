#!/bin/bash
# Optimization script for ReverseTlsTunnel on Ubuntu 22.04
# Goals: Reduce traffic, eliminate disconnections, lower ping, and improve stability
# Author: Optimized for ReverseTlsTunnel by Grok
# License: MIT (feel free to share on GitHub)

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

# Check if running on Ubuntu 22.04
if ! lsb_release -d | grep -q "Ubuntu 22.04"; then
  echo "This script is designed for Ubuntu 22.04. Proceed with caution."
  read -p "Continue? (y/n): " confirm
  if [ "$confirm" != "y" ]; then
    exit 1
  fi
fi

# Backup sysctl.conf
cp /etc/sysctl.conf /etc/sysctl.conf.bak
echo "Backed up sysctl.conf to /etc/sysctl.conf.bak"

# Enable BBR congestion control for lower latency and better throughput
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# Optimize TCP buffers for high traffic
echo "net.ipv4.tcp_rmem = 4096 87380 8388608" >> /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 16384 4194304" >> /etc/sysctl.conf
echo "net.ipv4.tcp_window_scaling=1" >> /etc/sysctl.conf
echo "net.ipv4.tcp_low_latency=1" >> /etc/sysctl.conf

# Enable TCP Fast Open to reduce connection setup time
echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf

# Optimize MTU probing and MSS for better packet handling
echo "net.ipv4.tcp_mtu_probing=1" >> /etc/sysctl.conf
echo "net.ipv4.tcp_base_mss=1024" >> /etc/sysctl.conf

# Increase max connections for high user load
echo "net.core.somaxconn=65535" >> /etc/sysctl.conf
echo "net.ipv4.tcp_max_syn_backlog=8192" >> /etc/sysctl.conf
echo "net.core.netdev_max_backlog=5000" >> /etc/sysctl.conf

# TCP Keepalive to prevent disconnections
echo "net.ipv4.tcp_keepalive_time=300" >> /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_intvl=60" >> /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_probes=10" >> /etc/sysctl.conf

# Enable packet compression (optional, requires application-level support)
# If ReverseTlsTunnel supports compression, enable it in its config
# Example: Add zlib or lz4 compression if supported by the tool
if [ -f "/usr/local/bin/rtt" ]; then
  echo "Checking for compression support in ReverseTlsTunnel..."
  # Placeholder: Add compression config if supported (edit /etc/rtt.conf or equivalent)
  # Example: echo "compression=zlib" >> /etc/rtt.conf
  echo "Please check if ReverseTlsTunnel supports compression (e.g., zlib/lz4) and enable it manually."
fi

# Apply sysctl changes
sysctl -p
echo "Applied TCP optimizations."

# Install and configure ufw for security and to drop unnecessary packets
apt-get update
apt-get install -y ufw
ufw allow 22/tcp  # Allow SSH
ufw allow 443/tcp # Allow TLS (adjust based on ReverseTlsTunnel port)
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
echo "Firewall configured with ufw."

# Install netdata for real-time monitoring (optional)
apt-get install -y netdata
systemctl enable netdata
systemctl start netdata
echo "Netdata installed for monitoring. Access it at http://<server-ip>:19999"

# Optimize ReverseTlsTunnel process (assuming it's running as a systemd service)
if systemctl list-units | grep -q "rtt"; then
  echo "Optimizing ReverseTlsTunnel service..."
  # Increase file descriptor limits
  echo "* soft nofile 65535" >> /etc/security/limits.conf
  echo "* hard nofile 65535" >> /etc/security/limits.conf
  # Set CPU and IO priority
  systemctl set-property rtt.service CPUSchedulingPolicy=rr CPUSchedulingPriority=20 IOSchedulingClass=best-effort IOSchedulingPriority=2
  systemctl daemon-reload
  systemctl restart rtt
  echo "ReverseTlsTunnel service optimized."
else
  echo "ReverseTlsTunnel service not found. Please ensure it's installed and running."
fi

# Install tc (traffic control) to limit bandwidth and reduce congestion
apt-get install -y iproute2
# Example: Limit bandwidth to 10Mbps on eth0 (adjust interface and rate as needed)
tc qdisc add dev eth0 root tbf rate 10mbit burst 32kbit latency 50ms
echo "Traffic shaping applied to limit bandwidth and reduce congestion."

# Log optimization details
echo "Optimization completed at $(date)" >> /var/log/rtt_optimization.log
echo "Details:" >> /var/log/rtt_optimization.log
echo "- Enabled BBR for better TCP performance" >> /var/log/rtt_optimization.log
echo "- Optimized TCP buffers and keepalive settings" >> /var/log/rtt_optimization.log
echo "- Configured ufw for security" >> /var/log/rtt_optimization.log
echo "- Installed netdata for monitoring" >> /var/log/rtt_optimization.log
echo "- Applied traffic shaping with tc" >> /var/log/rtt_optimization.log

# Final instructions
echo "Optimization complete! Please test the tunnel."
echo "Monitor performance using: http://<server-ip>:19999 (Netdata)"
echo "Check logs at: /var/log/rtt_optimization.log"
echo "If compression is supported, enable it in ReverseTlsTunnel config."
echo "To share on GitHub, upload this script and test thoroughly."
