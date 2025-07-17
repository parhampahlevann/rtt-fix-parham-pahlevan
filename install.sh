#!/bin/bash

# Global Configuration
SCRIPT_NAME="BBR VIP Optimizer"
SCRIPT_VERSION="2.7"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
SYSCTL_BACKUP="/etc/sysctl.conf.bak"
CRON_JOB_FILE="/etc/cron.d/bbr_vip_autoreset"

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1

# Color Codes
RED='\033[0;31m'
BOLD_RED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Header Display
show_header() {
    clear
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════╗"
    echo -e "║   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}   ║"
    echo -e "╚════════════════════════════════════════════════╝${NC}"
}

# Check Root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${BOLD_RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
}

# Clean line endings (for Windows compatibility)
clean_script() {
    sed -i 's/\r$//' "$0" 2>/dev/null
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
net.ipv4.tcp_ecn = 1
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
    else
        # Traditional resolv.conf
        cat << EOF > /etc/resolv.conf
nameserver $dns1
nameserver $dns2
EOF
    fi
}

# Firewall Configuration
configure_firewall() {
    echo -e "\n${YELLOW}Configuring firewall...${NC}"
    
    if command -v ufw &>/dev/null; then
        ufw disable
        echo -e "${GREEN}UFW firewall disabled.${NC}"
    fi
}

# Auto-Restart Services
enable_cron_job() {
    echo -e "\n${YELLOW}=== Enabling Auto-Restart ===${NC}"
    
    # Services to automatically restart
    services=("x-ui" "xray")
    
    # Default interval
    interval=15
    
    # Create cron job for each service
    for service in "${services[@]}"; do
        if systemctl is-active "$service" &>/dev/null; then
            echo "*/$interval * * * * root systemctl restart $service >/dev/null 2>&1" >> "$CRON_JOB_FILE"
            echo -e "${GREEN}Auto-restart enabled for $service every $interval minutes${NC}"
        else
            echo -e "${YELLOW}Service $service is not active, skipping...${NC}"
        fi
    done
    
    # Set permissions and reload cron
    if [ -f "$CRON_JOB_FILE" ]; then
        chmod 644 "$CRON_JOB_FILE"
        systemctl restart cron
        echo -e "\n${GREEN}Cron job successfully activated!${NC}"
    else
        echo -e "${RED}No active services found to auto-restart!${NC}"
    fi
}

# Manual Cron Job Configuration
manual_cron_job() {
    echo -e "\n${YELLOW}=== Manual Cron Job Configuration ===${NC}"
    
    read -p "Enter service name to auto-restart: " service_name
    read -p "Enter restart interval in minutes (default 15): " interval
    interval=${interval:-15}
    
    if ! systemctl is-active "$service_name" &>/dev/null; then
        echo -e "${RED}Error: Service '$service_name' is not active!${NC}"
        return 1
    fi
    
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
        echo -e "${RED}Error: Invalid interval!${NC}"
        return 1
    fi
    
    echo "*/$interval * * * * root systemctl restart $service_name >/dev/null 2>&1" >> "$CRON_JOB_FILE"
    chmod 644 "$CRON_JOB_FILE"
    systemctl restart cron
    
    echo -e "${GREEN}Manual cron job added for $service_name every $interval minutes!${NC}"
}

# MTU Configuration
configure_mtu() {
    local current_mtu=$(ip link show $INTERFACE | grep -oP 'mtu \K\d+')
    
    echo -e "\n${YELLOW}Current MTU: $current_mtu${NC}"
    read -p "Enter new MTU (68-9000): " new_mtu
    
    if [[ $new_mtu =~ ^[0-9]+$ && $new_mtu -ge 68 && $new_mtu -le 9000 ]]; then
        ip link set dev $INTERFACE mtu $new_mtu
        echo -e "${GREEN}MTU set to $new_mtu successfully!${NC}"
    else
        echo -e "${RED}Invalid MTU value!${NC}"
    fi
}

# Main Installation
install_optimizations() {
    show_header
    check_root
    select_interface
    
    # Backup original settings
    cp /etc/sysctl.conf "$SYSCTL_BACKUP"
    
    configure_bbr
    optimize_tcp
    configure_dns
    configure_firewall
    
    echo -e "\n${GREEN}Optimizations completed successfully!${NC}"
}

# Uninstallation
uninstall_optimizations() {
    show_header
    check_root
    
    echo -e "\n${YELLOW}=== Reverting optimizations ===${NC}"
    
    if [ -f "$SYSCTL_BACKUP" ]; then
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        rm -f /etc/sysctl.d/60-bbr-optimizations.conf
        sysctl -p
        echo -e "${GREEN}System settings restored.${NC}"
    fi
    
    if [ -f "$CRON_JOB_FILE" ]; then
        rm -f "$CRON_JOB_FILE"
        systemctl restart cron
        echo -e "${GREEN}Cron job removed.${NC}"
    fi
    
    echo -e "\n${GREEN}Uninstallation completed!${NC}"
}

# Status Check
check_status() {
    show_header
    
    echo -e "${BOLD}=== System Status ===${NC}"
    echo -e "\n${BOLD}Kernel:${NC} $(uname -r)"
    echo -e "${BOLD}BBR Status:${NC} $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
    echo -e "${BOLD}Queue Discipline:${NC} $(sysctl net.core.default_qdisc | awk '{print $3}')"
    echo -e "${BOLD}Interface MTU:${NC} $(ip link show $INTERFACE | grep -oP 'mtu \K\d+')"
    
    if [ -f "$CRON_JOB_FILE" ]; then
        echo -e "\n${BOLD}Auto-Restart Services:${NC}"
        grep -oP 'restart \K\w+' "$CRON_JOB_FILE" | while read service; do
            interval=$(grep "$service" "$CRON_JOB_FILE" | awk '{print $1}' | cut -d'/' -f2)
            echo "$service: every $interval minutes"
        done
    fi
}

# Main Menu
show_menu() {
    while true; do
        show_header
        echo -e "${BOLD}Main Menu:${NC}"
        echo "1. Install Optimizations"
        echo "2. Uninstall Optimizations"
        echo "3. Check System Status"
        echo "4. Configure MTU"
        echo "5. Configure DNS"
        echo "6. Enable Cron Job (Auto-Restart)"
        echo "7. Manual Cron Job Configuration"
        echo "8. Reboot System"
        echo -e "9. ${BOLD_RED}Exit${NC}"
        
        read -p "Select an option [1-9]: " choice
        
        case $choice in
            1) install_optimizations ;;
            2) uninstall_optimizations ;;
            3) check_status ;;
            4) configure_mtu ;;
            5) 
                read -p "Enter primary DNS: " dns1
                read -p "Enter secondary DNS: " dns2
                configure_dns "$dns1" "$dns2"
                ;;
            6) enable_cron_job ;;
            7) manual_cron_job ;;
            8) 
                read -p "Are you sure you want to reboot? (y/n): " confirm
                [[ "$confirm" =~ [yY] ]] && reboot
                ;;
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

# Clean script and run
clean_script
show_menu
