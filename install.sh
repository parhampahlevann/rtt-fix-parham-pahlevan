#!/bin/bash

# Global variables
SCRIPT_NAME="BBR VIP Optimizer"
SCRIPT_VERSION="2.1"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
SYSCTL_BACKUP="/etc/sysctl.conf.bak"

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
}

# Detect distribution
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        echo -e "${RED}Error: Could not detect OS!${NC}"
        exit 1
    fi
}

# Network interface selection
select_interface() {
    interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
    
    if [ ${#interfaces[@]} -eq 1 ]; then
        INTERFACE=${interfaces[0]}
        echo -e "${GREEN}Auto-selected interface: $INTERFACE${NC}"
        return
    fi

    echo -e "${YELLOW}Available network interfaces:${NC}"
    PS3="Please select interface (1-${#interfaces[@]}): "
    select INTERFACE in "${interfaces[@]}"; do
        if [ -n "$INTERFACE" ]; then
            break
        else
            echo -e "${RED}Invalid selection!${NC}"
        continue
        fi
    done
}

# Kernel version check
check_kernel_version() {
    local required="4.9"
    local current=$(uname -r | cut -d. -f1-2)
    
    if (( $(echo "$current < $required" | bc -l) )); then
        echo -e "${RED}Warning: Kernel $current is too old for BBR. Minimum required: $required${NC}"
        return 1
    fi
    return 0
}

# BBR configuration
configure_bbr() {
    echo -e "${YELLOW}Configuring TCP congestion control...${NC}"
    
    # Try BBRv2 first
    if modprobe tcp_bbr2 2>/dev/null; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr2
        echo -e "${GREEN}BBRv2 enabled successfully!${NC}"
    elif modprobe tcp_bbr; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr
        echo -e "${GREEN}BBRv1 enabled successfully!${NC}"
    else
        sysctl -w net.ipv4.tcp_congestion_control=cubic
        echo -e "${RED}BBR not available. Falling back to Cubic.${NC}"
        return 1
    fi

    # Configure qdisc
    if modprobe sch_cake 2>/dev/null; then
        sysctl -w net.core.default_qdisc=cake
    else
        sysctl -w net.core.default_qdisc=fq_codel
    fi
    
    return 0
}

# TCP optimization
optimize_tcp() {
    echo -e "${YELLOW}Applying TCP optimizations...${NC}"
    
    cat << EOF > /etc/sysctl.d/60-bbr-optimizations.conf
# Connection management
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_tw_buckets = 200000

# Performance tuning
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# Buffer settings
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 16384 8388608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

    sysctl --system
}

# Network configuration
configure_network() {
    echo -e "${YELLOW}Configuring network settings...${NC}"
    
    # MTU configuration
    local target_mtu=${1:-1420}
    ip link set dev "$INTERFACE" mtu "$target_mtu"
    
    # Persistent MTU setting
    case $OS in
        ubuntu|debian)
            if [ -f "/etc/netplan/01-netcfg.yaml" ]; then
                sed -i "/$INTERFACE:/,/mtu:/ s/mtu:.*/mtu: $target_mtu/" /etc/netplan/01-netcfg.yaml
                netplan apply
            fi
            ;;
        centos|rhel)
            if [ -f "/etc/sysconfig/network-scripts/ifcfg-$INTERFACE" ]; then
                sed -i "/MTU=/d" "/etc/sysconfig/network-scripts/ifcfg-$INTERFACE"
                echo "MTU=$target_mtu" >> "/etc/sysconfig/network-scripts/ifcfg-$INTERFACE"
                systemctl restart network
            fi
            ;;
    esac
    
    # DNS configuration
    configure_dns "1.1.1.1" "8.8.8.8"
    
    # IPv6 configuration (optional)
    read -p "Disable IPv6? (y/n): " disable_ipv6
    if [[ "$disable_ipv6" =~ [yY] ]]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=1
        sysctl -w net.ipv6.conf.default.disable_ipv6=1
        echo -e "${GREEN}IPv6 has been disabled.${NC}"
    fi
}

# DNS configuration
configure_dns() {
    local dns1=${1:-"1.1.1.1"}
    local dns2=${2:-"8.8.8.8"}
    
    echo -e "${YELLOW}Configuring DNS servers...${NC}"
    
    # Systemd-resolved
    if systemctl is-active systemd-resolved &>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d/
        cat << EOF > /etc/systemd/resolved.conf.d/bbr.conf
[Resolve]
DNS=$dns1 $dns2
DNSOverTLS=opportunistic
EOF
        systemctl restart systemd-resolved
        return
    fi
    
    # Traditional resolv.conf
    cat << EOF > /etc/resolv.conf
nameserver $dns1
nameserver $dns2
EOF
    
    # For CentOS/RHEL
    if [ -f "/etc/sysconfig/network-scripts/ifcfg-$INTERFACE" ]; then
        sed -i "/DNS[12]=/d" "/etc/sysconfig/network-scripts/ifcfg-$INTERFACE"
        echo "DNS1=$dns1" >> "/etc/sysconfig/network-scripts/ifcfg-$INTERFACE"
        echo "DNS2=$dns2" >> "/etc/sysconfig/network-scripts/ifcfg-$INTERFACE"
        systemctl restart network
    fi
}

# Firewall configuration
configure_firewall() {
    echo -e "${YELLOW}Configuring firewall...${NC}"
    
    if command -v ufw &>/dev/null; then
        ufw disable
        echo -e "${GREEN}UFW firewall disabled.${NC}"
    elif command -v firewalld &>/dev/null; then
        systemctl stop firewalld
        systemctl disable firewalld
        echo -e "${GREEN}Firewalld disabled.${NC}"
    elif command -v iptables &>/dev/null; then
        iptables -F
        iptables -X
        iptables -Z
        echo -e "${GREEN}IPTables rules cleared.${NC}"
    fi
}

# Service prioritization
prioritize_services() {
    local service_name="ReverseTlsTunnel"
    
    if systemctl is-active "$service_name" &>/dev/null; then
        systemctl set-property "$service_name" CPUSchedulingPolicy=rr
        systemctl set-property "$service_name" IOSchedulingPriority=2
        echo -e "${GREEN}Priority set for $service_name service.${NC}"
    fi
}

# Installation
install_optimizations() {
    echo -e "\n${GREEN}=== $SCRIPT_NAME (v$SCRIPT_VERSION) ===${NC}"
    echo -e "By ${YELLOW}$AUTHOR${NC}\n"
    
    check_root
    detect_os
    select_interface
    check_kernel_version
    
    # Backup current settings
    cp /etc/sysctl.conf "$SYSCTL_BACKUP"
    
    # Apply optimizations
    configure_bbr
    optimize_tcp
    configure_network
    configure_firewall
    prioritize_services
    
    echo -e "\n${GREEN}Optimizations completed successfully!${NC}"
    echo -e "A detailed log has been saved to ${YELLOW}$LOG_FILE${NC}"
}

# Uninstallation
uninstall_optimizations() {
    check_root
    
    echo -e "\n${YELLOW}=== Reverting optimizations ===${NC}"
    
    # Restore sysctl settings
    if [ -f "$SYSCTL_BACKUP" ]; then
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        sysctl -p
        rm -f /etc/sysctl.d/60-bbr-optimizations.conf
        echo -e "${GREEN}System settings restored.${NC}"
    else
        echo -e "${RED}No backup found! Manual restoration required.${NC}"
    fi
    
    # Reset network settings
    ip link set dev "$INTERFACE" mtu 1500
    echo "" > /etc/resolv.conf
    
    # Restart network services
    systemctl restart systemd-networkd 2>/dev/null || service networking restart 2>/dev/null
    
    echo -e "\n${GREEN}Optimizations have been removed.${NC}"
}

# Status check
check_status() {
    echo -e "\n${YELLOW}=== Current System Status ===${NC}"
    
    # Kernel info
    echo -e "\n${GREEN}Kernel Information:${NC}"
    uname -r
    
    # BBR status
    echo -e "\n${GREEN}TCP Congestion Control:${NC}"
    sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'
    
    # Qdisc status
    echo -e "\n${GREEN}Queue Discipline:${NC}"
    sysctl net.core.default_qdisc | awk '{print $3}'
    
    # Network info
    echo -e "\n${GREEN}Network Interface ($INTERFACE):${NC}"
    ip -o link show "$INTERFACE" | awk '{print "MTU:", $5}'
    
    # DNS info
    echo -e "\n${GREEN}DNS Configuration:${NC}"
    grep nameserver /etc/resolv.conf || echo "No DNS servers configured"
    
    # Firewall status
    echo -e "\n${GREEN}Firewall Status:${NC}"
    if command -v ufw &>/dev/null; then
        ufw status | grep Status
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --state
    else
        echo "No active firewall detected"
    fi
}

# Interactive menu
show_menu() {
    while true; do
        echo -e "\n${GREEN}=== $SCRIPT_NAME Menu ===${NC}"
        echo "1. Install Optimizations"
        echo "2. Uninstall Optimizations"
        echo "3. Check System Status"
        echo "4. Change MTU"
        echo "5. Change DNS Servers"
        echo "6. Reboot System"
        echo "7. Exit"
        
        read -p "Select an option [1-7]: " choice
        
        case $choice in
            1) install_optimizations ;;
            2) uninstall_optimizations ;;
            3) check_status ;;
            4) 
                read -p "Enter new MTU (68-9000): " new_mtu
                if [[ "$new_mtu" =~ ^[0-9]+$ && "$new_mtu" -ge 68 && "$new_mtu" -le 9000 ]]; then
                    configure_network "$new_mtu"
                else
                    echo -e "${RED}Invalid MTU value!${NC}"
                fi
                ;;
            5)
                read -p "Enter primary DNS: " dns1
                read -p "Enter secondary DNS (optional): " dns2
                configure_dns "$dns1" "$dns2"
                ;;
            6) 
                read -p "Are you sure you want to reboot? (y/n): " confirm
                [[ "$confirm" =~ [yY] ]] && reboot
                ;;
            7) exit 0 ;;
            *) echo -e "${RED}Invalid option!${NC}" ;;
        esac
    done
}

# Main execution
if [[ "$1" == "--install" ]]; then
    install_optimizations
elif [[ "$1" == "--uninstall" ]]; then
    uninstall_optimizations
elif [[ "$1" == "--status" ]]; then
    check_status
else
    show_menu
fi
