#!/bin/bash
# BBR VIP Optimizer Pro - Complete Optimized Version
# Auto-enables VIP mode with BBR and configures MTU on all interfaces

SCRIPT_NAME="BBR VIP Optimizer Pro"
SCRIPT_VERSION="7.0"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
BACKUP_DIR="/etc/bbr_vip_backups"
SYSCTL_BACKUP="$BACKUP_DIR/sysctl.conf.bak"
RESOLV_BACKUP="$BACKUP_DIR/resolv.conf.bak"
NETWORK_BACKUP="$BACKUP_DIR/network_configs.tar.gz"

# Network Configuration
PREFERRED_INTERFACES=("ens160" "eth0" "enp0s3" "enp0s8")
NETWORK_INTERFACE=""
ALL_INTERFACES=()
VIP_MODE=true  # Auto-enable VIP mode by default
VIP_SUBNET=""
VIP_GATEWAY=""
DEFAULT_MTU=1420
CURRENT_MTU=""
DNS_SERVERS=("1.1.1.1" "8.8.8.8")
CURRENT_DNS=""

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Initialize logging
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ==================== CORE FUNCTIONS ==================== #

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root!${NC}"
        exit 1
    fi
}

init_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    chmod 600 "$BACKUP_DIR"
}

detect_interfaces() {
    ALL_INTERFACES=()
    for iface in "${PREFERRED_INTERFACES[@]}"; do
        if ip link show "$iface" >/dev/null 2>&1; then
            ALL_INTERFACES+=("$iface")
        fi
    done
    
    if [ ${#ALL_INTERFACES[@]} -eq 0 ]; then
        ALL_INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
    fi
    
    if [ ${#ALL_INTERFACES[@]} -gt 0 ]; then
        NETWORK_INTERFACE="${ALL_INTERFACES[0]}"
        CURRENT_MTU=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo $DEFAULT_MTU)
    fi
    
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
}

backup_network_configs() {
    echo -e "${YELLOW}Creating comprehensive backup of network settings...${NC}"
    init_backup_dir
    
    cp /etc/sysctl.conf "$SYSCTL_BACKUP"
    cp /etc/resolv.conf "$RESOLV_BACKUP"
    
    if [ -d /etc/netplan ]; then
        tar -czf "$NETWORK_BACKUP" /etc/netplan/ 2>/dev/null
    elif [ -f /etc/network/interfaces ]; then
        cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak"
    fi
    
    if command -v nmcli &>/dev/null; then
        nmcli -f NAME,UUID con show | awk 'NR>1 {print $2}' | while read uuid; do
            nmcli con show "$uuid" > "$BACKUP_DIR/nm_$uuid.bak"
        done
    fi
    
    echo -e "${GREEN}Full network configuration backed up to $BACKUP_DIR${NC}"
}

# ==================== AUTO CONFIGURATION FUNCTIONS ==================== #

enable_bbr_with_vip() {
    echo -e "${YELLOW}Enabling BBR with AUTO VIP mode...${NC}"
    
    backup_network_configs
    
    {
        echo "# BBR Configuration with VIP Mode - DO NOT EDIT"
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
        echo "net.ipv4.tcp_fastopen=3"
        echo "net.ipv4.tcp_tw_reuse=1"
        echo "net.ipv4.tcp_fin_timeout=30"
        echo "net.ipv4.tcp_keepalive_time=1200"
        echo "net.ipv4.ip_local_port_range=1024 65000"
        echo "net.ipv4.tcp_max_syn_backlog=8192"
        echo "net.ipv4.tcp_max_tw_buckets=5000"
        echo "net.core.somaxconn=65535"
        echo "net.core.netdev_max_backlog=16384"
        echo "net.ipv4.tcp_slow_start_after_idle=0"
        echo "net.ipv4.tcp_mtu_probing=1"
        echo "net.ipv4.tcp_rfc1337=1"
        
        # VIP Mode Optimizations (auto-enabled)
        echo "# VIP Optimizations"
        echo "net.ipv4.tcp_window_scaling=1"
        echo "net.ipv4.tcp_timestamps=1"
        echo "net.ipv4.tcp_sack=1"
        echo "net.ipv4.tcp_dsack=1"
        echo "net.ipv4.tcp_fack=1"
        echo "net.ipv4.tcp_adv_win_scale=1"
        echo "net.ipv4.tcp_app_win=31"
        echo "net.ipv4.tcp_low_latency=1"
    } > /etc/sysctl.d/60-bbr.conf

    sysctl -p /etc/sysctl.d/60-bbr.conf >/dev/null 2>&1
    
    for iface in "${ALL_INTERFACES[@]}"; do
        tc qdisc replace dev "$iface" root fq 2>/dev/null
    done
    
    if ! grep -q "60-bbr.conf" /etc/rc.local 2>/dev/null; then
        [ -f /etc/rc.local ] || echo -e "#!/bin/bash\nexit 0" > /etc/rc.local
        sed -i "/^exit 0/i sysctl -p /etc/sysctl.d/60-bbr.conf" /etc/rc.local
        chmod +x /etc/rc.local
    fi
    
    echo -e "${GREEN}BBR with VIP mode enabled successfully!${NC}"
}

set_mtu_all_interfaces() {
    local mtu=$1
    
    backup_network_configs
    
    echo -e "${YELLOW}Configuring MTU $mtu on all interfaces...${NC}"
    
    for iface in "${ALL_INTERFACES[@]}"; do
        # Temporary change
        ip link set dev "$iface" mtu "$mtu"
        
        # Persistent changes
        if [ -f /etc/network/interfaces ]; then
            sed -i "/iface $iface inet/,/^$/ { /mtu /d }" /etc/network/interfaces
            sed -i "/iface $iface inet/a\    mtu $mtu" /etc/network/interfaces
        elif command -v nmcli &>/dev/null; then
            nmcli con mod "$(nmcli -t -f DEVICE,NAME con show | grep "$iface" | cut -d: -f2)" 802-3-ethernet.mtu "$mtu"
            nmcli con up "$(nmcli -t -f DEVICE,NAME con show | grep "$iface" | cut -d: -f2)"
        elif [ -d /etc/netplan ]; then
            for yaml in /etc/netplan/*.yaml; do
                if grep -q "$iface:" "$yaml"; then
                    sed -i "/$iface:/,/^ *[^ ]/ { /mtu:/d }" "$yaml"
                    sed -i "/$iface:/a\      mtu: $mtu" "$yaml"
                fi
            done
            netplan apply
        fi
        
        # Verify MTU was set
        current_mtu=$(cat /sys/class/net/"$iface"/mtu 2>/dev/null)
        if [ "$current_mtu" -eq "$mtu" ]; then
            echo -e "${GREEN}Successfully set MTU $mtu on $iface${NC}"
        else
            echo -e "${RED}Failed to set MTU $mtu on $iface${NC}"
        fi
    done
    
    # Add to rc.local for persistence
    [ -f /etc/rc.local ] || echo -e "#!/bin/bash\nexit 0" > /etc/rc.local
    for iface in "${ALL_INTERFACES[@]}"; do
        if ! grep -q "ip link set dev $iface mtu $mtu" /etc/rc.local; then
            sed -i "/^exit 0/i ip link set dev $iface mtu $mtu" /etc/rc.local
        fi
    done
    chmod +x /etc/rc.local
    
    echo -e "${GREEN}MTU $mtu configured on ALL interfaces!${NC}"
}

# ==================== RESTORATION FUNCTIONS ==================== #

restore_backups() {
    echo -e "${YELLOW}Restoring original network configuration...${NC}"
    
    if [ -f "$SYSCTL_BACKUP" ]; then
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        rm -f /etc/sysctl.d/60-bbr.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    if [ -f "$RESOLV_BACKUP" ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
        cp "$RESOLV_BACKUP" /etc/resolv.conf
    fi
    
    if [ -f "$NETWORK_BACKUP" ]; then
        if [ -d /etc/netplan ]; then
            rm -f /etc/netplan/*
            tar -xzf "$NETWORK_BACKUP" -C /etc/
        elif [ -f "$BACKUP_DIR/interfaces.bak" ]; then
            cp "$BACKUP_DIR/interfaces.bak" /etc/network/interfaces
        fi
    fi
    
    if command -v nmcli &>/dev/null; then
        find "$BACKUP_DIR" -name "nm_*.bak" | while read backup; do
            uuid=$(basename "$backup" | cut -d_ -f2 | cut -d. -f1)
            nmcli con del "$uuid"
            nmcli con add < "$backup"
        done
    fi
    
    [ -f /etc/rc.local ] && sed -i '/60-bbr.conf/d;/mtu /d' /etc/rc.local
    
    if systemctl is-active --quiet NetworkManager; then
        systemctl restart NetworkManager
    else
        systemctl restart networking
    fi
    
    echo -e "${GREEN}All settings restored to original configuration!${NC}"
}

# ==================== STATUS MONITORING ==================== #

show_status() {
    clear
    echo -e "${BLUE}${BOLD}=== $SCRIPT_NAME $SCRIPT_VERSION ===${NC}"
    echo -e "${CYAN}=== Current Network Status ===${NC}"
    
    # BBR Status
    echo -e "\n${YELLOW}BBR Status:${NC}"
    local congestion=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    echo -e " Congestion Control: ${BOLD}$congestion${NC}"
    echo -e " Queue Discipline: ${BOLD}$qdisc${NC}"
    echo -e " VIP Mode: ${GREEN}Enabled${NC}"
    
    # Interface Status
    echo -e "\n${YELLOW}Network Interfaces:${NC}"
    for iface in "${ALL_INTERFACES[@]}"; do
        local mtu=$(cat /sys/class/net/"$iface"/mtu 2>/dev/null || echo "Unknown")
        local state=$(ip -o link show "$iface" | awk '{print $9}')
        local ip=$(ip -o -4 addr show "$iface" | awk '{print $4}' | cut -d/ -f1 || echo "None")
        echo -e " ${BOLD}$iface${NC}:"
        echo -e "   State: $state"
        echo -e "   IP: $ip"
        echo -e "   MTU: $mtu"
    done
    
    # DNS Status
    echo -e "\n${YELLOW}DNS Status:${NC}"
    if [ -f /etc/resolv.conf ]; then
        grep nameserver /etc/resolv.conf | while read line; do
            local dns=$(echo "$line" | awk '{print $2}')
            echo -e " $line" $(ping -c1 -W1 "$dns" &>/dev/null && echo -e "${GREEN}(Reachable)${NC}" || echo -e "${RED}(Unreachable)${NC}")
        done
    else
        echo -e " ${RED}No resolv.conf found${NC}"
    fi
    
    read -p $'\nPress Enter to continue...'
}

# ==================== MAIN MENU ==================== #

show_menu() {
    while true; do
        clear
        echo -e "${BLUE}${BOLD}$SCRIPT_NAME $SCRIPT_VERSION${NC}"
        echo -e "${YELLOW}Main Menu:${NC}"
        echo -e "1) Enable BBR with VIP Mode (Auto)"
        echo -e "2) Set MTU on ALL Interfaces"
        echo -e "3) Configure DNS Servers"
        echo -e "4) Show Current Status"
        echo -e "5) Restore Original Settings"
        echo -e "6) Exit"
        
        read -p "Please select an option: " choice
        
        case $choice in
            1) enable_bbr_with_vip ;;
            2)
                echo -n "Enter MTU value [recommended 1420]: "
                read mtu
                set_mtu_all_interfaces "$mtu"
                ;;
            3)
                echo -n "Enter DNS servers (space separated): "
                read -a dns_servers
                configure_dns_persistent "${dns_servers[@]}"
                ;;
            4) show_status ;;
            5) restore_backups ;;
            6) exit 0 ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

# ==================== INITIALIZATION ==================== #

check_root
init_backup_dir
detect_interfaces
show_menu
