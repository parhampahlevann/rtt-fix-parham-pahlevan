#!/bin/bash

# Global Configuration
SCRIPT_NAME="BBR VIP Optimizer"
SCRIPT_VERSION="2.3"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
SYSCTL_BACKUP="/etc/sysctl.conf.bak"
CRON_JOB_FILE="/etc/cron.d/bbr_vip_autoreset"

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1

# Color and Formatting
RED='\033[0;31m'
BOLD_RED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'
UNDERLINE='\033[4m'

# Header Display
show_header() {
    clear
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════╗"
    echo -e "║   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}   ║"
    echo -e "╚════════════════════════════════════════════════╝${NC}"
}

# Root Check
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${BOLD_RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
}

# OS Detection
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        echo -e "${BOLD_RED}Error: Could not detect OS!${NC}"
        exit 1
    fi
}

# Network Interface Selection
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
        fi
    done
}

# Kernel Version Check
check_kernel_version() {
    local required="4.9"
    local current=$(uname -r | cut -d. -f1-2)
    
    if (( $(echo "$current < $required" | bc -l) ); then
        echo -e "${YELLOW}Warning: Kernel $current is old. Minimum required: $required${NC}"
        return 1
    fi
    return 0
}

# BBR Configuration
configure_bbr() {
    echo -e "\n${YELLOW}Configuring TCP congestion control...${NC}"
    
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

# TCP Optimization
optimize_tcp() {
    echo -e "\n${YELLOW}Applying TCP optimizations...${NC}"
    
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

# Network Configuration
configure_network() {
    local target_mtu=${1:-1420}
    echo -e "\n${YELLOW}Configuring network settings...${NC}"
    
    # MTU configuration
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
    
    # IPv6 configuration
    read -p "Disable IPv6? (y/n): " disable_ipv6
    if [[ "$disable_ipv6" =~ [yY] ]]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=1
        sysctl -w net.ipv6.conf.default.disable_ipv6=1
        echo -e "${GREEN}IPv6 has been disabled.${NC}"
    fi
}

# DNS Configuration
configure_dns() {
    local dns1=${1:-"1.1.1.1"}
    local dns2=${2:-"8.8.8.8"}
    
    echo -e "\n${YELLOW}Configuring DNS servers...${NC}"
    
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

# Firewall Configuration
configure_firewall() {
    echo -e "\n${YELLOW}Configuring firewall...${NC}"
    
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

# Service Prioritization
prioritize_services() {
    local service_name="ReverseTlsTunnel"
    
    if systemctl is-active "$service_name" &>/dev/null; then
        systemctl set-property "$service_name" CPUSchedulingPolicy=rr
        systemctl set-property "$service_name" IOSchedulingPriority=2
        echo -e "${GREEN}Priority set for $service_name service.${NC}"
    fi
}

# X-UI Detection
detect_xui() {
    if systemctl is-active x-ui >/dev/null 2>&1; then
        echo "x-ui"
    elif [ -f "/usr/local/x-ui/x-ui" ]; then
        echo "x-ui"
    else
        echo ""
    fi
}

# Cron Job Management
add_cron_job() {
    local service_name="$1"
    local interval="${2:-15}"
    
    echo -e "\n${YELLOW}Adding cron job to restart $service_name every $interval minutes...${NC}"
    
    echo "*/$interval * * * * root systemctl restart $service_name >/dev/null 2>&1" > "$CRON_JOB_FILE"
    chmod 644 "$CRON_JOB_FILE"
    systemctl restart cron
    
    echo -e "${GREEN}Cron job added successfully!${NC}"
    echo -e "Cron file: ${BLUE}$CRON_JOB_FILE${NC}"
}

remove_cron_job() {
    if [ -f "$CRON_JOB_FILE" ]; then
        rm -f "$CRON_JOB_FILE"
        systemctl restart cron
        echo -e "${GREEN}Cron job removed successfully!${NC}"
    else
        echo -e "${YELLOW}No active cron job found.${NC}"
    fi
}

# Auto-Reset Configuration
configure_auto_reset() {
    echo -e "\n${GREEN}=== Service Auto-Reset Configuration ===${NC}"
    
    local xui_service=$(detect_xui)
    local service_choice=""
    
    if [ -n "$xui_service" ]; then
        read -p "Detected X-UI service. Configure auto-reset for X-UI? (y/n): " confirm
        [[ "$confirm" =~ [yY] ]] && service_choice="x-ui"
    fi
    
    if [ -z "$service_choice" ]; then
        read -p "Enter the service name you want to auto-reset (e.g., nginx, x-ui): " service_choice
    fi
    
    if ! systemctl is-active "$service_choice" >/dev/null 2>&1; then
        echo -e "${RED}Error: Service $service_choice not found or not active!${NC}"
        return 1
    fi
    
    read -p "Enter reset interval in minutes (default 15): " interval
    interval=${interval:-15}
    
    add_cron_job "$service_choice" "$interval"
}

# Installation
install_optimizations() {
    show_header
    check_root
    detect_os
    select_interface
    check_kernel_version
    
    cp /etc/sysctl.conf "$SYSCTL_BACKUP"
    
    configure_bbr
    optimize_tcp
    configure_network
    configure_firewall
    prioritize_services
    
    echo -e "\n${GREEN}Optimizations completed successfully!${NC}"
    echo -e "Log file: ${BLUE}$LOG_FILE${NC}"
}

# Uninstallation
uninstall_optimizations() {
    show_header
    check_root
    
    echo -e "\n${YELLOW}=== Reverting optimizations ===${NC}"
    
    if [ -f "$SYSCTL_BACKUP" ]; then
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        sysctl -p
        rm -f /etc/sysctl.d/60-bbr-optimizations.conf
        echo -e "${GREEN}System settings restored.${NC}"
    else
        echo -e "${RED}No backup found! Manual restoration required.${NC}"
    fi
    
    ip link set dev "$INTERFACE" mtu 1500
    echo "" > /etc/resolv.conf
    systemctl restart systemd-networkd 2>/dev/null || service networking restart 2>/dev/null
    
    echo -e "\n${GREEN}Optimizations have been removed.${NC}"
}

# Status Check
check_status() {
    show_header
    echo -e "\n${YELLOW}=== Current System Status ===${NC}"
    
    echo -e "\n${BOLD}Kernel Information:${NC}"
    uname -r
    
    echo -e "\n${BOLD}TCP Congestion Control:${NC}"
    sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'
    
    echo -e "\n${BOLD}Queue Discipline:${NC}"
    sysctl net.core.default_qdisc | awk '{print $3}'
    
    echo -e "\n${BOLD}Network Interface ($INTERFACE):${NC}"
    ip -o link show "$INTERFACE" | awk '{print "MTU:", $5}'
    
    echo -e "\n${BOLD}DNS Configuration:${NC}"
    grep nameserver /etc/resolv.conf || echo "No DNS servers configured"
    
    echo -e "\n${BOLD}Firewall Status:${NC}"
    if command -v ufw &>/dev/null; then
        ufw status | grep Status
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --state
    else
        echo "No active firewall detected"
    fi
    
    if [ -f "$CRON_JOB_FILE" ]; then
        echo -e "\n${BOLD}Active Auto-Reset:${NC}"
        echo "Service: $(awk '{print $6}' $CRON_JOB_FILE | cut -d'/' -f3)"
        echo "Interval: $(awk '{print $1}' $CRON_JOB_FILE | cut -d'/' -f2) minutes"
    fi
}

# Interactive Menu
show_menu() {
    while true; do
        show_header
        echo -e "\n${BOLD}Main Menu:${NC}"
        echo -e "1. ${GREEN}Install Optimizations${NC}"
        echo -e "2. ${RED}Uninstall Optimizations${NC}"
        echo -e "3. ${BLUE}Check System Status${NC}"
        echo -e "4. Change MTU"
        echo -e "5. Change DNS Servers"
        echo -e "6. Reboot System"
        echo -e "7. Configure Service Auto-Reset"
        echo -e "8. Remove Auto-Reset Cron Job"
        echo -e "9. ${BOLD_RED}Exit${NC}"
        
        read -p "Select an option [1-9]: " choice
        
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
            7) configure_auto_reset ;;
            8) remove_cron_job ;;
            9) 
                echo -e "\n${BOLD_RED}╔════════════════════════════════════════╗"
                echo -e "║                                            ║"
                echo -e "║          Modified By ${BOLD}Parham Pahlevan${NC}${BOLD_RED}          ║"
                echo -e "║                                            ║"
                echo -e "╚════════════════════════════════════════╝${NC}"
                exit 0 
                ;;
            *) echo -e "${RED}Invalid option!${NC}" ;;
        esac
        
        read -p "Press [Enter] to continue..."
    done
}

# Main Execution
if [[ "$1" == "--install" ]]; then
    install_optimizations
elif [[ "$1" == "--uninstall" ]]; then
    uninstall_optimizations
elif [[ "$1" == "--status" ]]; then
    check_status
else
    show_menu
fi
