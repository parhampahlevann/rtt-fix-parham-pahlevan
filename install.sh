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
FALLBACK_DNS="178.22.122.100" # Shecan DNS
SYSCTL_CUSTOM="/etc/sysctl.d/99-bbr-ultimate.conf"

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
        set_dns
        if nslookup youtube.com > /dev/null 2>&1; then
            echo "DNS resolution fixed."
        else
            echo "Trying fallback DNS ($FALLBACK_DNS)..."
            set_fallback_dns
            if nslookup youtube.com > /dev/null 2>&1; then
                echo "DNS resolution fixed with fallback DNS."
            else
                echo "Error: Could not resolve host (e.g., youtube.com). This may be due to ISP restrictions or filtering."
                echo "Suggestions:"
                echo "1. Use a VPN to bypass potential ISP filtering."
                echo "2. Manually add YouTube IP to /etc/hosts (e.g., '142.250.190.14 youtube.com'). Use 'dig youtube.com' to get the latest IP."
                echo "3. Try alternative DNS like Electro (78.157.42.100)."
                echo "4. Contact your ISP or network admin for assistance."
                exit 1
            fi
        fi
    fi
}

# Function to set DNS
set_dns() {
    echo "Backing up current DNS settings..."
    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || echo "No existing /etc/resolv.conf to backup."

    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo "System uses systemd-resolved. Updating DNS via resolved.conf..."
        echo "[Resolve]" > /etc/systemd/resolved.conf
        echo "DNS=$DEFAULT_DNS1 $DEFAULT_DNS2" >> /etc/systemd/resolved.conf
        echo "FallbackDNS=$FALLBACK_DNS" >> /etc/systemd/resolved.conf
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        echo "Setting DNS directly in /etc/resolv.conf..."
        echo "nameserver $DEFAULT_DNS1" > /etc/resolv.conf
        echo "nameserver $DEFAULT_DNS2" >> /etc/resolv.conf
    fi
}

# Function to set fallback DNS
set_fallback_dns() {
    echo "Backing up current DNS settings..."
    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || echo "No existing /etc/resolv.conf to backup."

    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo "System uses systemd-resolved. Updating DNS via resolved.conf..."
        echo "[Resolve]" > /etc/systemd/resolved.conf
        echo "DNS=$FALLBACK_DNS" >> /etc/systemd/resolved.conf
        echo "FallbackDNS=1.1.1.1 8.8.8.8" >> /etc/systemd/resolved.conf
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        echo "Setting fallback DNS in /etc/resolv.conf..."
        echo "nameserver $FALLBACK_DNS" > /etc/resolv.conf
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

    # Write sysctl settings to custom file
    echo "Saving settings to $SYSCTL_CUSTOM..."
    cat <<EOT > $SYSCTL_CUSTOM
# Ultimate BBRv2 by Parham Pahlevan
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=8
net.core.somaxconn=16384
net.ipv4.tcp_max_syn_backlog=4096
net.core.netdev_max_backlog=3000
net.ipv4.tcp_max_tw_buckets=32768
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
net.ipv4.tcp_rmem=4096 65536 4194304
net.ipv4.tcp_wmem=4096 16384 4194304
net.core.rmem_max=6291456
net.core.wmem_max=6291456
EOT

    # Load BBR module
    if modprobe tcp_bbr 2>/dev/null; then
        echo "BBR module loaded successfully."
    else
        echo
