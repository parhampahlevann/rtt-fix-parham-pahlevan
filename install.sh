#!/bin/bash

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script requires root privileges. Please run with sudo or as the root user!"
    exit 1
fi

# Default variables
DEFAULT_MTU=1420
DEFAULT_DNS1="1.1.1.1"
DEFAULT_DNS2="8.8.8.8"

# Function to check internet and DNS connectivity
check_connectivity() {
    echo "Checking internet and DNS connectivity..."
    if ping -c 1 8.8.8.8 > /dev/null 2>&1; then
        echo "Internet connectivity is available."
    else
        echo "No internet connectivity! Please check your network connection."
        exit 1
    fi

    if nslookup github.com > /dev/null 2>&1; then
        echo "DNS resolution is working."
    else
        echo "DNS resolution failed! Setting default DNS servers ($DEFAULT_DNS1, $DEFAULT_DNS2)..."
        echo "nameserver $DEFAULT_DNS1" > /etc/resolv.conf
        echo "nameserver $DEFAULT_DNS2" >> /etc/resolv.conf
        if nslookup github.com > /dev/null 2>&1; then
            echo "DNS resolution fixed."
        else
            echo "Error: Could not resolve host (e.g., github.com). This may be due to ISP restrictions or filtering."
            echo "Suggestions:"
            echo "1. Use a VPN to bypass potential ISP filtering."
            echo "2. Manually add GitHub IP to /etc/hosts (e.g., '185.199.108.133 raw.githubusercontent.com')."
            echo "3. Contact your ISP or network admin for assistance."
            exit 1
        fi
    fi
}

# Function to detect the primary network interface
detect_network_interface() {
    # Try to detect the primary interface using the default route
    INTERFACE=$(ip route show default | grep -oP 'dev \K\S+' | head -1)
    
    # If no interface is found, try common interfaces
    if [ -z "$INTERFACE" ]; then
        for iface in eth0 ens3 enp0s3; do
            if ip link show "$iface" > /dev/null 2>&1; then
                INTERFACE="$iface"
                break
            fi
        done
    fi

    # If still no interface, list all available interfaces and prompt user
    if [ -z "$INTERFACE" ]; then
        echo "No default network interface found!"
        echo "Available network interfaces:"
        ip link show | grep -E '^[0-9]+: ' | awk '{print $2}' | sed 's/://' | while read -r iface; do
            echo "- $iface"
        done
        read -p "Please enter the network interface name: " INTERFACE
        if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
            echo "Invalid interface $INTERFACE! Exiting."
            exit 1
        fi
    fi
    echo "Selected network interface: $INTERFACE"
}

# Check connectivity and DNS
check_connectivity

# Detect network interface
detect_network_interface

# Backup original sysctl.conf
SYSCTL_BACKUP="/etc/sysctl.conf.bak"
if [ ! -f "$SYSCTL_BACKUP" ]; then
    cp /etc/sysctl.conf "$SYSCTL_BACKUP" 2>/dev/null || touch "$SYSCTL_BACKUP"
fi

# Function to install optimizations
install_optimizations() {
    echo "Installing BBR VIP optimizations by Parham Pahlevan..."

    # Set default MTU
    echo "Setting MTU to $DEFAULT_MTU for interface $INTERFACE..."
    ip link set dev "$INTERFACE" mtu $DEFAULT_MTU
    if [ $? -eq 0 ]; then
        echo "MTU successfully set to $DEFAULT_MTU."
    else
        echo "Error setting MTU! Please check the network interface or permissions."
        exit 1
    fi

    # Apply TCP and network optimizations
    echo "Applying TCP optimizations for streaming and downloading..."

    # TCP Keepalive for connection stability and lower latency (Heartbeat)
    sysctl -w net.ipv4.tcp_keepalive_time=120
    sysctl -w net.ipv4.tcp_keepalive_intvl=30
    sysctl -w net.ipv4.tcp_keepalive_probes=10

    # Increase connection limits
    sysctl -w net.core.somaxconn=65535
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192
    sysctl -w net.core.netdev_max_backlog=5000
    sysctl -w net.ipv4.tcp_max_tw_buckets=200000

    # Enhance BBR for streaming and downloading
    sysctl -w net.core.default_qdisc=fq_codel
    if sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null; then
        echo "BBR successfully enabled."
    else
        echo "BBR not supported, attempting to enable BBRv2..."
        modprobe tcp_bbr 2>/dev/null
        sysctl -w net.ipv4.tcp_congestion_control=bbr
    fi

    # Additional settings for low latency and streaming
    sysctl -w net.ipv4.tcp_low_latency=1
    sysctl -w net.ipv4.tcp_window_scaling=1
    sysctl -wmaking -w net.ipv4.tcp_sack=1
    sysctl -w net.ipv4.tcp_no_metrics_save=0
    sysctl -w net.ipv4.tcp_ecn=1
    sysctl -w net.ipv4.tcp_adv_win_scale=1
    sysctl -w net.ipv4.tcp_moderate_rcvbuf=1

    # Optimize TCP Fast Open
    sysctl -w net.ipv4.tcp_fastopen=3

    # Optimize MTU and MSS
    sysctl -w net.ipv4.tcp_mtu_probing=1
    sysctl -w net.ipv4.tcp_base_mss=1024

    # Optimize TCP buffers
    sysctl -w net.ipv4.tcp_rmem='4096 87380 8388608'
    sysctl -w net.ipv4.tcp_wmem='4096 16384 8388608'
    sysctl -w net.core.rmem_max=16777216
    sysctl -w net.core.wmem_max=16777216

    # Save settings to /etc/sysctl.conf
    echo "Saving settings to /etc/sysctl.conf..."
    cat <<EOT > /etc/sysctl.conf
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
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

    # Disable ufw
    echo "Disabling ufw..."
    ufw disable 2>/dev/null || echo "ufw not installed, skipping."

    # Set default DNS
    echo "Setting default DNS servers ($DEFAULT_DNS1, $DEFAULT_DNS2)..."
    echo "nameserver $DEFAULT_DNS1" > /etc/resolv.conf
    echo "nameserver $DEFAULT_DNS2" >> /etc/resolv.conf

    # TCP_NODELAY recommendation
    echo "Note: For applications using TCP sockets (e.g., rtt), consider enabling TCP_NODELAY to reduce latency."
    echo "If you have access to the source code, use setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, 1)."
    echo "Contact your application developer for further guidance."

    echo "BBR VIP optimizations installed successfully!"
}

# Function to uninstall optimizations
uninstall_optimizations() {
    echo "Uninstalling BBR VIP optimizations..."

    # Restore original sysctl.conf
    if [ -f "$SYSCTL_BACKUP" ]; then
        echo "Restoring original /etc/sysctl.conf..."
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        sysctl -p
    else
        echo "No backup of sysctl.conf found! Resetting to minimal defaults..."
        > /etc/sysctl.conf
        sysctl -p
    fi

    # Reset MTU to default (1500)
    echo "Resetting MTU to 1500 for interface $INTERFACE..."
    ip link set dev "$INTERFACE" mtu 1500

    # Disable ufw
    echo "Disabling ufw..."
    ufw disable 2>/dev/null || echo "ufw not installed, skipping."

    # Reset DNS to system defaults
    echo "Resetting DNS to system defaults..."
    echo "" > /etc/resolv.conf

    echo "Optimizations uninstalled successfully!"
}

# Function to show status
show_status() {
    echo "Checking system status..."

    # Check rtt service status
    if systemctl is-active rtt.service >/dev/null 2>&1; then
        echo "ReverseTlsTunnel (rtt) service: Active"
    else
        echo "ReverseTlsTunnel (rtt) service: Inactive or not found"
    fi

    # Check current MTU
    CURRENT_MTU=$(ip link show "$INTERFACE" | grep -oP 'mtu \K\d+' || echo "Unknown")
    echo "Current MTU: $CURRENT_MTU"

    # Check congestion control
    CURRENT_BBR=$(sysctl -n net.ipv4.tcp_congestion_control || echo "Unknown")
    echo "TCP Congestion Control: $CURRENT_BBR"

    # Check TCP Keepalive settings (Heartbeat)
    echo "TCP Keepalive settings (Heartbeat):"
    echo "  Keepalive Time: $(sysctl -n net.ipv4.tcp_keepalive_time) seconds"
    echo "  Keepalive Interval: $(sysctl -n net.ipv4.tcp_keepalive_intvl) seconds"
    echo "  Keepalive Probes: $(sysctl -n net.ipv4.tcp_keepalive_probes)"

    # Check DNS servers
    echo "Current DNS servers:"
    cat /etc/resolv.conf | grep nameserver || echo "No DNS servers configured."

    # Check ufw status
    if command -v ufw >/dev/null && ufw status | grep -q "inactive"; then
        echo "ufw: Disabled"
    else
        echo "ufw: Enabled or not installed"
    fi
}

# Function to change MTU
change_mtu() {
    echo "Current MTU: $(ip link show "$INTERFACE" | grep -oP 'mtu \K\d+' || echo "Unknown")"
    read -p "Enter new MTU value (between 1280 and 1500, default $DEFAULT_MTU): " CUSTOM_MTU
    if [[ "$CUSTOM_MTU" =~ ^[0-9]+$ && "$CUSTOM_MTU" -ge 1280 && "$CUSTOM_MTU" -le 1500 ]]; then
        ip link set dev "$INTERFACE" mtu $CUSTOM_MTU
        if [ $? -eq 0 ]; then
            echo "MTU set to $CUSTOM_MTU."
        else
            echo "Error setting MTU! Please check the network interface or permissions."
        fi
    else
        echo "Invalid MTU value! Keeping current MTU."
    fi
}

# Function to change DNS
change_dns() {
    echo "Current DNS servers:"
    cat /etc/resolv.conf | grep nameserver || echo "No DNS servers configured."
    echo "Default DNS servers: $DEFAULT_DNS1, $DEFAULT_DNS2"
    read -p "Do you want to change DNS servers? (y/n): " dns_choice
    if [[ "$dns_choice" == "y" || "$dns_choice" == "Y" ]]; then
        read -p "Enter first DNS server: " DNS1
        read -p "Enter second DNS server (optional): " DNS2
        if [[ -n "$DNS1" ]]; then
            echo "nameserver $DNS1" > /etc/resolv.conf
            if [[ -n "$DNS2" ]]; then
                echo "nameserver $DNS2" >> /etc/resolv.conf
            fi
            echo "DNS servers updated successfully."
        else
            echo "No valid DNS server provided! Keeping current configuration."
        fi
    else
        echo "Applying default DNS servers ($DEFAULT_DNS1, $DEFAULT_DNS2)..."
        echo "nameserver $DEFAULT_DNS1" > /etc/resolv.conf
        echo "nameserver $DEFAULT_DNS2" >> /etc/resolv.conf
    fi
}

# Function to reboot server
reboot_server() {
    read -p "Are you sure you want to reboot the server? (y/n): " reboot_choice
    if [[ "$reboot_choice" == "y" || "$reboot_choice" == "Y" ]]; then
        echo "Rebooting server..."
        reboot
    else
        echo "Reboot canceled."
    fi
}

# Menu
while true; do
    echo -e "\n=== BBR VIP By Parham Pahlevan ==="
    echo "1. Install BBR VIP By Parham Pahlevan"
    echo "2. Uninstall optimizations"
    echo "3. Show status"
    echo "4. Change MTU"
    echo "5. Change DNS"
    echo "6. Reboot"
    echo "7. Exit"
    read -p "Select an option [1-7]: " option

    case $option in
        1) install_optimizations ;;
        2) uninstall_optimizations ;;
        3) show_status ;;
        4) change_mtu ;;
        5) change_dns ;;
        6) reboot_server ;;
        7) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option! Please select a number between 1 and 7." ;;
    esac
done
