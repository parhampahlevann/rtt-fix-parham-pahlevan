#!/bin/bash

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script requires root privileges. Please run with sudo or as the root user!"
   exit 1
fi

# Default variables
DEFAULT_MTU=1420
INTERFACE="eth0" # Change this if you have a different network interface
TRAFFIC_RATE="50mbit" # Default rate for video streaming

# Verify network interface exists
ip link show $INTERFACE > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Network interface $INTERFACE not found! Please check the interface name."
    exit 1
fi

# Set default MTU
echo "Setting MTU to $DEFAULT_MTU for interface $INTERFACE..."
ip link set dev $INTERFACE mtu $DEFAULT_MTU
if [ $? -eq 0 ]; then
    echo "MTU successfully set to $DEFAULT_MTU."
else
    echo "Error setting MTU! Please check the network interface or permissions."
    exit 1
fi

# Option to manually set MTU
read -p "Do you want to manually set the MTU? (y/n, default $DEFAULT_MTU): " choice
if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    read -p "Please enter the new MTU value (between 1280 and 1500): " CUSTOM_MTU
    if [[ "$CUSTOM_MTU" =~ ^[0-9]+$ && "$CUSTOM_MTU" -ge 1280 && "$CUSTOM_MTU" -le 1500 ]]; then
        ip link set dev $INTERFACE mtu $CUSTOM_MTU
        echo "MTU set to $CUSTOM_MTU."
    else
        echo "Invalid MTU value! Default value $DEFAULT_MTU will be retained."
    fi
fi

# Apply TCP and network optimizations
echo "Applying TCP optimizations for streaming and downloading..."

# TCP Keepalive for connection stability
sysctl -w net.ipv4.tcp_keepalive_time=300
sysctl -w net.ipv4.tcp_keepalive_intvl=60
sysctl -w net.ipv4.tcp_keepalive_probes=10

# Increase connection limits
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=8192
sysctl -w net.core.netdev_max_backlog=5000
sysctl -w net.ipv4.tcp_max_tw_buckets=200000

# Enhance BBR for streaming and downloading
sysctl -w net.core.default_qdisc=fq_codel # Use fq_codel for lower latency
if sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null; then
    echo "BBR successfully enabled."
else
    echo "BBR not supported, attempting to enable BBRv2..."
    # Attempt to use BBRv2 (requires modern kernel)
    modprobe tcp_bbr
    sysctl -w net.ipv4.tcp_congestion_control=bbr
fi

# Additional settings for low latency and streaming optimization
sysctl -w net.ipv4.tcp_low_latency=1
sysctl -w net.ipv4.tcp_window_scaling=1
sysctl -w net.ipv4.tcp_sack=1
sysctl -w net.ipv4.tcp_no_metrics_save=0
sysctl -w net.ipv4.tcp_ecn=1 # Enable ECN for congestion control
sysctl -w net.ipv4.tcp_adv_win_scale=1
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1

# Optimize TCP Fast Open
sysctl -w net.ipv4.tcp_fastopen=3

# Optimize MTU and MSS
sysctl -w net.ipv4.tcp_mtu_probing=1
sysctl -w net.ipv4.tcp_base_mss=1024

# Optimize TCP buffers for streaming and downloading
sysctl -w net.ipv4.tcp_rmem='4096 87380 8388608' # Increased for high bandwidth
sysctl -w net.ipv4.tcp_wmem='4096 16384 8388608'
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# Save settings to /etc/sysctl.conf
echo "Saving settings to /etc/sysctl.conf..."
cat <<EOT > /etc/sysctl.conf
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=10
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_tw_buckets=200000
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_no_metrics_save=0
net.ipv4.tcp_ecn=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 16384 8388608
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOT

# Apply sysctl settings
sysctl -p

# Set CPU and IO priority for ReverseTlsTunnel service
echo "Setting CPU and IO priority for ReverseTlsTunnel service..."
systemctl set-property rtt.service CPUSchedulingPolicy=rr IOSchedulingPriority=2 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Error setting priority for rtt service. Please check if the rtt service exists."
fi

# Configure Traffic Shaping for streaming
echo "Configuring Traffic Shaping with rate $TRAFFIC_RATE..."
tc qdisc add dev $INTERFACE root handle 1: htb default 10
tc class add dev $INTERFACE parent 1: classid 1:10 htb rate $TRAFFIC_RATE
tc qdisc add dev $INTERFACE parent 1:10 handle 10: fq_codel
if [ $? -eq 0 ]; then
    echo "Traffic Shaping successfully configured."
else
    echo "Error configuring Traffic Shaping! Please check tc configuration."
fi

# Prioritize HTTPS traffic (port 443) for streaming
tc filter add dev $INTERFACE protocol ip parent 1: prio 1 u32 match ip dport 443 0xffff flowid 1:10
tc filter add dev $INTERFACE protocol ip parent 1: prio 1 u32 match ip sport 443 0xffff flowid 1:10

# Configure firewall (ufw)
echo "Configuring firewall to allow ports 22 and 443..."
ufw allow 22
ufw allow 443
ufw --force enable

# Install and check Netdata for monitoring
if ! command -v netdata &> /dev/null; then
    echo "Installing Netdata for real-time monitoring..."
    bash <(curl -Ss https://my-netdata.io/kickstart.sh) --dont-wait
else
    echo "Netdata is already installed."
fi

echo "Settings applied successfully!"
echo "Check Netdata at http://<your-server-ip>:19999 for monitoring."
echo "To test ping and speed, use commands like ping and iperf3."
