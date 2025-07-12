#!/bin/bash

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script requires root privileges. Please run with sudo or as the root user!"
    exit 1
fi

# Default variables
DEFAULT_MTU=1420
DEFAULT_DNS1="1.1.1.1" # Cloudflare DNS
DEFAULT_DNS2="8.8.8.8" # Google DNS

# Function to check internet and DNS connectivity
check_connectivity() {
    echo "Checking internet connectivity..."
    if ping -c 2 8.8.8.8 > /dev/null 2>&1; then
        echo "Internet connectivity is available."
    else
        echo "Error: No internet connectivity! Please check your network connection."
        exit 1
    fi

    echo "Checking DNS resolution..."
    if nslookup youtube.com > /dev/null 2>&1; then
        echo "DNS resolution is working."
    else
        echo "DNS resolution failed! Setting fixed DNS servers ($DEFAULT_DNS1, $DEFAULT_DNS2)..."
        echo "nameserver $DEFAULT_DNS1" > /etc/resolv.conf
        echo "nameserver $DEFAULT_DNS2" >> /etc/resolv.conf
        if nslookup youtube.com > /dev/null 2>&1; then
            echo "DNS resolution fixed."
        else
            echo "Error: Could not resolve host (e.g., youtube.com). This may be due to ISP restrictions or filtering."
            echo "Suggestions:"
            echo "1. Use a VPN to bypass potential ISP filtering."
            echo "2. Manually add YouTube IP to /etc/hosts (e.g., '142.250.190.14 youtube.com'). Use 'dig youtube.com' to get the latest IP."
            echo "3. Try alternative DNS like Shecan (178.22.122.100) or Electro (78.157.42.100)."
            echo "4. Contact your ISP or network admin for assistance."
            exit 1
        fi
    fi
}

# Function to detect the primary network interface
detect_network_interface() {
    echo "Detecting network interface..."
    INTERFACE=$(ip route show default | grep -oP 'dev \K\S+' | head -1)
    
    if [ -z "$INTERFACE" ]; then
        for iface in eth0 ens3 enp0s3 enp0s8; do
            if ip link show "$iface" > /dev/null 2>&1; then
                INTERFACE="$iface"
                break
            fi
        done
    fi

    if [ -z "$INTERFACE" ]; then
        echo "No default network interface found!"
        echo "Available network interfaces:"
        ip link show | grep -E '^[0-9]+: ' | awk '{print $2}' | sed 's/://' | while read -r iface; do
            echo "- $iface"
        done
        read -p "Please enter the network interface name: " INTERFACE
        if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
            echo "Error: Invalid interface $INTERFACE! Exiting."
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
    echo "Installing Ultimate BBRv2 optimizations by Parham Pahlevan for stable, high-speed, and low ping..."

    # Set fixed MTU
    echo "Setting fixed MTU to $DEFAULT_MTU for interface $INTERFACE..."
    ip link set dev "$INTERFACE" mtu $DEFAULT_MTU
    if [ $? -eq 0 ]; then
        echo "MTU successfully set to $DEFAULT_MTU."
    else
        echo "Error setting MTU! Please check the network interface or permissions."
        exit 1
    fi

    # Apply TCP and network optimizations
    echo "Applying TCP optimizations for stable 4K streaming and low ping..."

    # TCP Keepalive for connection stability
    sysctl -w net.ipv4.tcp_keepalive_time=120
    sysctl -w net.ipv4.tcp_keepalive_intvl=30
    sysctl -w net.ipv4.tcp_keepalive_probes=8

    # Increase connection limits
    sysctl -w net.core.somaxconn=32768
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192
    sysctl -w net.core.netdev_max_backlog=5000
    sysctl -w net.ipv4.tcp_max_tw_buckets=65536

    # Enable BBR or BBRv2
    sysctl -w net.core.default_qdisc=fq
    if modprobe tcp_bbr 2>/dev/null; then
        if sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null; then
            echo "BBR or BBRv2 successfully enabled."
        else
            echo "BBR not supported. Falling back to cubic."
            sysctl -w net.ipv4.tcp_congestion_control=cubic
        fi
    else
        echo "BBR module not available. Falling back to cubic."
        sysctl -w net.ipv4.tcp_congestion_control=cubic
    fi

    # Settings for low latency and stability
    sysctl -w net.ipv4.tcp_low_latency=1
    sysctl -w net.ipv4.tcp_window_scaling=1
    sysctl -w net.ipv4.tcp_sack=1
    sysctl -w net.ipv4.tcp_no_metrics_save=0
    sysctl -w net.ipv4.tcp_ecn=0
    sysctl -w net.ipv4.tcp_mtu_probing=1
    sysctl -w net.ipv4.tcp_base_mss=1024
    sysctl -w net.ipv4.tcp_fastopen=3

    # Optimize TCP buffers for stability
    sysctl -w net.ipv4.tcp_rmem='4096 87380 6291456'
    sysctl -w net.ipv4.tcp_wmem='4096 16384 6291456'
    sysctl -w net.core.rmem_max=8388608
    sysctl -w net.core.wmem_max=8388608

    # Save settings to /etc/sysctl.conf
    echo "Saving settings to /etc/sysctl.conf..."
    cat <<EOT > /etc/sysctl.conf
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=8
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_tw_buckets=65536
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_no_metrics_save=0
net.ipv4.tcp_ecn=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_rmem=4096 87380 6291456
net.ipv4.tcp_wmem=4096 16384 6291456
net.core.rmem_max=8388608
net.core.wmem_max=8388608
EOT

    # Apply sysctl settings
    sysctl -p >/dev/null
    if [ $? -eq 0 ]; then
        echo "Sysctl settings applied successfully."
    else
        echo "Error applying sysctl settings! Please check /etc/sysctl.conf."
        exit 1
    fi

    # Set CPU and IO priority for ReverseTlsTunnel service
    echo "Setting CPU and IO priority for ReverseTlsTunnel service..."
    systemctl set-property rtt.service CPUSchedulingPolicy=rr IOSchedulingPriority=1 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Note: Could not set priority for rtt service. Please check if the rtt service exists."
    fi

    # Disable ufw
    echo "Disabling ufw..."
    ufw disable 2>/dev/null || echo "ufw not installed, skipping."

    # Set fixed DNS
    echo "Setting fixed DNS servers ($DEFAULT_DNS1, $DEFAULT_DNS2)..."
    echo "nameserver $DEFAULT_DNS1" > /etc/resolv.conf
    echo "nameserver $DEFAULT_DNS2" >> /etc/resolv.conf

    # TCP_NODELAY recommendation
    echo "Note: For TCP-based services (e.g., rtt), enable TCP_NODELAY to reduce latency."
    echo "If you have access to the source code, use setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, 1)."
    echo "Contact your application developer for guidance."

    echo "Optimizations installed successfully for stable, high-speed, and low ping!"
}

# Function to uninstall optimizations
uninstall_optimizations() {
    echo "Uninstalling all optimizations..."

    # Restore original sysctl.conf or clear it
    if [ -f "$SYSCTL_BACKUP" ] && [ -s "$SYSCTL_BACKUP" ]; then
        echo "Restoring original /etc/sysctl.conf..."
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        sysctl -p >/dev/null
        if [ $? -eq 0 ]; then
            echo "Sysctl settings restored successfully."
        else
            echo "Error restoring sysctl settings! Clearing /etc/sysctl.conf..."
            > /etc/sysctl.conf
            sysctl -p >/dev/null
        fi
    else
        echo "No valid backup of sysctl.conf found! Clearing /etc/sysctl.conf..."
        > /etc/sysctl.conf
        sysctl -p >/dev/null
    fi

    # Reset MTU to default (1500)
    echo "Resetting MTU to 1500 for interface $INTERFACE..."
    ip link set dev "$INTERFACE" mtu 1500
    if [ $? -eq 0 ]; then
        echo "MTU reset to 1500."
    else
        echo "Error resetting MTU! Please check the network interface."
    fi

    # Reset CPU and IO priority for rtt service
    echo "Resetting CPU and IO priority for ReverseTlsTunnel service..."
    systemctl reset-property rtt.service CPUSchedulingPolicy IOSchedulingPriority 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "Note: Could not reset priority for rtt service. Please check if the rtt service exists."
    fi

    # Remove BBR module if loaded
    echo "Removing BBR module if loaded..."
    rmmod tcp_bbr 2>/dev/null || echo "BBR module not loaded, skipping."

    # Disable ufw
    echo "Disabling ufw..."
    ufw disable 2>/dev/null || echo "ufw not installed, skipping."

    # Reset DNS to system defaults
    echo "Resetting DNS to system defaults..."
    if [ -f "/etc/resolv.conf.bak" ]; then
        cp /etc/resolv.conf.bak /etc/resolv.conf
        echo "Restored original DNS settings."
    else
        echo "" > /etc/resolv.conf
        echo "Cleared DNS settings to allow system defaults."
    fi

    echo "All optimizations uninstalled successfully!"
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

    # Check TCP Keepalive settings
    echo "TCP Keepalive settings:"
    echo "  Keepalive Time: $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "Unknown") seconds"
    echo "  Keepalive Interval: $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo "Unknown") seconds"
    echo "  Keepalive Probes: $(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo "Unknown")"

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
    echo -e "\n=== Ultimate BBRv2 By Parham Pahlevan ==="
    echo "1. Install Ultimate BBRv2 By Parham Pahlevan"
    echo "2. Uninstall all optimizations"
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
