#!/bin/bash

# =========================================================
# Ultimate Network Optimizer
# Version 9.7 - Fully English Menu & IPv6 DNS Support
# Author: Parham Pahlevan
# =========================================================

SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="9.7"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/network_optimizer.conf"
LOG_FILE="/var/log/network_optimizer.log"
BACKUP_DIR="/var/backups/network_optimizer"

NETWORK_INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
DEFAULT_MTU=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo 1500)
CURRENT_MTU=$DEFAULT_MTU
DNS_SERVERS=("1.1.1.1" "1.0.0.1")
CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')

DNS_SERVICES=( "systemd-resolved" "resolvconf" "dnsmasq" "unbound" "bind9" "named" "NetworkManager" )
declare -A DETECTED_SERVICES_STATUS

DISTRO="unknown"
DISTRO_VERSION=""

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

print_separator() { echo "-----------------------------------------------------"; }

check_requirements() {
    local missing=()
    for cmd in ip awk grep sed date; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing required commands: ${missing[*]}${NC}"
        exit 1
    fi
}

confirm_action() {
    local message="$1"
    echo -e "${RED}WARNING: $message${NC}"
    read -p "Are you sure? (yes/no): " confirm
    [[ "$confirm" == "yes" || "$confirm" == "y" ]]
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        DISTRO_VERSION=$VERSION_ID
    elif command -v lsb_release >/dev/null 2>&1; then
        DISTRO=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        DISTRO_VERSION=$(lsb_release -sr)
    else
        DISTRO="unknown"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOL
MTU=$CURRENT_MTU
DNS_SERVERS=(${DNS_SERVERS[@]})
NETWORK_INTERFACE=$NETWORK_INTERFACE
DISTRO=$DISTRO
DISTRO_VERSION=$DISTRO_VERSION
EOL
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
        CURRENT_MTU=$MTU
        DNS_SERVERS=(${DNS_SERVERS[@]})
    fi
}

show_header() {
    clear
    echo -e "${BLUE}${BOLD}====================================================="
    echo -e "   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}"
    echo -e "=====================================================${NC}"
    detect_distro
    echo -e "${YELLOW}Distribution: ${BOLD}$DISTRO $DISTRO_VERSION${NC}"
    echo -e "${YELLOW}Interface: ${BOLD}$NETWORK_INTERFACE${NC}"
    echo -e "${YELLOW}Current MTU: ${BOLD}$CURRENT_MTU${NC}"
    echo -e "${YELLOW}Current DNS: ${BOLD}$CURRENT_DNS${NC}"

    local bbr_status
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$bbr_status" == "bbr" ]]; then
        echo -e "${YELLOW}BBR Status: ${GREEN}Enabled${NC}"
    else
        echo -e "${YELLOW}BBR Status: ${RED}Disabled${NC}"
    fi

    if command -v ufw >/dev/null 2>&1; then
        local fw_status
        fw_status=$(ufw status | grep -o "active")
        echo -e "${YELLOW}Firewall Status: ${BOLD}${fw_status:-inactive}${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        local fw_status
        fw_status=$(firewall-cmd --state 2>/dev/null)
        echo -e "${YELLOW}Firewall Status: ${BOLD}${fw_status:-unknown}${NC}"
    else
        echo -e "${YELLOW}Firewall Status: ${BOLD}Not detected${NC}"
    fi

    local icmp_status
    icmp_status=$(iptables -L INPUT -n 2>/dev/null | grep "icmp" | grep -o "DROP")
    if [ "$icmp_status" == "DROP" ]; then
        echo -e "${YELLOW}ICMP Ping: ${RED}Blocked${NC}"
    else
        echo -e "${YELLOW}ICMP Ping: ${GREEN}Allowed${NC}"
    fi

    local ipv6_status
    ipv6_status=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}')
    if [ "$ipv6_status" == "1" ]; then
        echo -e "${YELLOW}IPv6: ${RED}Disabled${NC}"
    else
        echo -e "${YELLOW}IPv6: ${GREEN}Enabled${NC}"
    fi

    if ip link show vxlan100 >/dev/null 2>&1; then
        echo -e "${YELLOW}VXLAN Tunnel: ${GREEN}Active (vxlan100)${NC}"
    fi

    if command -v haproxy >/dev/null 2>&1; then
        if systemctl is-active --quiet haproxy 2>/dev/null; then
            echo -e "${YELLOW}HAProxy: ${GREEN}Active${NC}"
        else
            echo -e "${YELLOW}HAProxy: ${YELLOW}Installed (Not running)${NC}"
        fi
    fi
    echo
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
}

# Improved validation: accepts IPv4 and IPv6
validate_ip() {
    local ip=$1
    # IPv4
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    # IPv6 (basic support)
    if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] || \
       [[ $ip =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || \
       [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,6}:[0-9a-fA-F]{0,4}$ ]] || \
       [[ $ip == "::" ]] || [[ $ip == "::1" ]]; then
        return 0
    fi
    return 1
}

_test_connectivity() {
    ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1
}

ping_mtu() {
    read -p "Enter MTU size to test (e.g., 1420): " test_mtu
    if [[ "$test_mtu" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}Testing ping with MTU=$test_mtu...${NC}"
        ping -M do -s $((test_mtu - 28)) -c 4 1.1.1.1
    else
        echo -e "${RED}Invalid MTU value!${NC}"
    fi
}

speed_test() {
    echo -e "\n${YELLOW}Running Network Speed Test...${NC}"
    print_separator
    echo -e "${BLUE}Testing Latency...${NC}"
    local targets=("8.8.8.8" "1.1.1.1" "4.2.2.4")
    for t in "${targets[@]}"; do
        echo -n "Ping $t: "
        ping -c 2 -W 2 "$t" 2>/dev/null | awk -F'/' '/min\/avg\/max/ {print $5" ms"}' || echo "Timeout"
    done
    if command -v dig >/dev/null 2>&1; then
        echo -e "\n${BLUE}Testing DNS Resolution Speed...${NC}"
        local dns=("8.8.8.8" "1.1.1.1" "208.67.222.222")
        for d in "${dns[@]}"; do
            echo -n "DNS $d: "
            dig google.com @"$d" +stats +time=1 2>/dev/null | awk '/Query time/ {print $4" ms"}' || echo "Failed"
        done
    fi
    echo -e "\n${BLUE}Testing Download Speed...${NC}"
    if command -v curl >/dev/null 2>&1; then
        local urls=("http://speedtest.ftp.otenet.gr/files/test1Mb.db" "http://ipv4.download.thinkbroadband.com/1MB.zip")
        for u in "${urls[@]}"; do
            echo -n "Testing $u: "
            local speed
            speed=$(curl -o /dev/null -w "%{speed_download}" -s "$u" 2>/dev/null)
            if [ -n "$speed" ]; then
                local mbps
                mbps=$(echo "scale=2; $speed / 125000" | bc 2>/dev/null || echo "0")
                echo "${mbps} Mbps"
                break
            else
                echo "Failed"
            fi
        done
    else
        echo -e "${YELLOW}Curl not available${NC}"
    fi
    echo -e "\n${BLUE}Interface Statistics:${NC}"
    grep "$NETWORK_INTERFACE" /proc/net/dev | awk '{print "Received: "$2" bytes, Transmitted: "$10" bytes"}'
    print_separator
    echo -e "${GREEN}Speed test completed!${NC}"
}

configure_mtu() {
    local new_mtu=$1
    local old_mtu
    old_mtu=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo $DEFAULT_MTU)
    if [[ ! "$new_mtu" =~ ^[0-9]+$ ]] || [ "$new_mtu" -lt 576 ] || [ "$new_mtu" -gt 9000 ]; then
        echo -e "${RED}Invalid MTU (576-9000).${NC}"; return 1
    fi
    if ! ip link set dev "$NETWORK_INTERFACE" mtu "$new_mtu"; then
        echo -e "${RED}Failed to set temporary MTU!${NC}"; return 1
    fi
    if ! _test_connectivity; then
        echo -e "${RED}Connectivity failed, rollback MTU...${NC}"
        ip link set dev "$NETWORK_INTERFACE" mtu "$old_mtu"
        return 1
    fi
    local config_applied=false

    if [[ -d /etc/netplan ]] && command -v netplan >/dev/null 2>&1; then
        local f
        f=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -f "$f" ]; then
            cp "$f" "$f.backup.$(date +%Y%m%d_%H%M%S)"
            if grep -q "mtu:" "$f"; then
                sed -i "s/mtu:.*/mtu: $new_mtu/" "$f"
            else
                sed -i "/$NETWORK_INTERFACE:/a\      mtu: $new_mtu" "$f"
            fi
            netplan apply >/dev/null 2>&1 && config_applied=true
        fi
    fi

    if [ "$config_applied" = false ] && command -v nmcli >/dev/null 2>&1 && (systemctl is-active --quiet NetworkManager 2>/dev/null || pgrep NetworkManager >/dev/null); then
        local con_name
        con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" 802-3-ethernet.mtu "$new_mtu" 2>/dev/null || true
            nmcli con down "$con_name" 2>/dev/null; nmcli con up "$con_name" 2>/dev/null
            config_applied=true
        fi
    fi

    if [ "$config_applied" = false ] && [[ -f /etc/network/interfaces ]]; then
        cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)
        if grep -q "mtu" /etc/network/interfaces; then
            sed -i "s/mtu.*/mtu $new_mtu/" /etc/network/interfaces
        else
            sed -i "/iface $NETWORK_INTERFACE inet/a\    mtu $new_mtu" /etc/network/interfaces
        fi
        systemctl restart networking >/dev/null 2>&1 && config_applied=true
    fi

    if [ "$config_applied" = false ]; then
        echo -e "${YELLOW}Permanent MTU not set, only runtime.${NC}"
    fi

    CURRENT_MTU=$new_mtu
    save_config
    echo -e "${GREEN}MTU set to $new_mtu${NC}"
}

# ================== DNS Configuration (supports IPv4 & IPv6) ==================
configure_dns() {
    echo -e "\n${YELLOW}DNS Configuration (supports IPv4 and IPv6)${NC}"
    print_separator

    echo -e "${YELLOW}Resetting current DNS configuration...${NC}"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf

    echo -e "${BLUE}Enter the DNS servers you want to use (IPv4 or IPv6):${NC}"
    read -p "Primary DNS: " dns1

    if ! validate_ip "$dns1"; then
        echo -e "${RED}Invalid IP address!${NC}"
        return 1
    fi

    read -p "Secondary DNS (optional, press Enter to skip): " dns2

    DNS_SERVERS=("$dns1")
    if [ -n "$dns2" ]; then
        if validate_ip "$dns2"; then
            DNS_SERVERS+=("$dns2")
        else
            echo -e "${RED}Invalid secondary DNS IP, ignoring it.${NC}"
        fi
    fi

    echo -e "\n${YELLOW}Writing /etc/resolv.conf ...${NC}"
    cat > /etc/resolv.conf <<EOF
# Generated by $SCRIPT_NAME
# $(date)
EOF

    for dns in "${DNS_SERVERS[@]}"; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done

    cat >> /etc/resolv.conf <<EOF
options rotate timeout:2 attempts:3
options single-request-reopen
EOF

    chattr +i /etc/resolv.conf 2>/dev/null || \
        echo -e "${YELLOW}Warning: could not set resolv.conf immutable (chattr +i).${NC}"

    CURRENT_DNS=$(printf "%s " "${DNS_SERVERS[@]}")
    save_config

    echo -e "\n${GREEN}DNS updated successfully.${NC}"
    echo -e "${GREEN}Current DNS servers: ${DNS_SERVERS[*]}${NC}"
    echo -e "${GREEN}Configuration will persist across reboots.${NC}"
}
# ======================================================================

reset_dns() {
    echo -e "${YELLOW}Resetting DNS to default...${NC}"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    cat > /etc/resolv.conf <<EOF
# $SCRIPT_NAME - Default DNS
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    
    DNS_SERVERS=("8.8.8.8" "8.8.4.4")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    
    echo -e "${GREEN}DNS reset to default (Google DNS)${NC}"
}

show_dns() {
    echo -e "\n${YELLOW}Current DNS Configuration:${NC}"
    print_separator
    echo -e "${BOLD}/etc/resolv.conf:${NC}"
    if [ -f /etc/resolv.conf ]; then
        cat /etc/resolv.conf | while read line; do
            echo "  $line"
        done
    else
        echo "  ${RED}File not found${NC}"
    fi
    
    print_separator
    echo -e "${BOLD}DNS Service Status:${NC}"
    local services=("systemd-resolved" "NetworkManager" "dnsmasq" "unbound" "bind9")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "  $svc: ${GREEN}Active${NC}"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            echo "  $svc: ${YELLOW}Enabled (not running)${NC}"
        else
            echo "  $svc: ${RED}Inactive${NC}"
        fi
    done
    
    print_separator
    echo -e "${BOLD}Configured DNS Servers:${NC}"
    for dns in "${DNS_SERVERS[@]}"; do
        echo "  $dns"
    done
}

# ========== BBR ==========
install_bbr() {
    echo -e "${YELLOW}Installing BBR...${NC}"
    print_separator
    local cc
    cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR already enabled${NC}"; return 0
    fi
    sysctl -w net.ipv4.tcp_keepalive_time=300
    sysctl -w net.ipv4.tcp_keepalive_intvl=60
    sysctl -w net.ipv4.tcp_keepalive_probes=10
    sysctl -w net.core.somaxconn=65535
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192
    sysctl -w net.core.netdev_max_backlog=5000
    sysctl -w net.ipv4.tcp_max_tw_buckets=200000
    sysctl -w net.core.default_qdisc=fq_codel
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || {
        modprobe tcp_bbr 2>/dev/null; sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true; }
    sysctl -w net.ipv4.tcp_low_latency=1
    sysctl -w net.ipv4.tcp_window_scaling=1
    sysctl -w net.ipv4.tcp_sack=1
    sysctl -w net.ipv4.tcp_ecn=1
    sysctl -w net.ipv4.tcp_moderate_rcvbuf=1
    sysctl -w net.ipv4.tcp_fastopen=3
    sysctl -w net.ipv4.tcp_mtu_probing=1
    sysctl -w net.ipv4.tcp_base_mss=1024
    sysctl -w net.ipv4.tcp_rmem='4096 87380 8388608'
    sysctl -w net.ipv4.tcp_wmem='4096 16384 8388608'
    sysctl -w net.core.rmem_max=16777216
    sysctl -w net.core.wmem_max=16777216
    cp /etc/sysctl.conf /etc/sysctl.conf.backup."$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    cat <<EOT >> /etc/sysctl.conf

# BBR Optimization - Added by $SCRIPT_NAME
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
net.ipv4.tcp_ecn=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 16384 8388608
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOT
    sysctl -p >/dev/null 2>&1
    cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    [[ "$cc" == "bbr" ]] && echo -e "${GREEN}BBR enabled.${NC}" || echo -e "${YELLOW}BBR not active, but tuning applied.${NC}"
}

uninstall_bbr() {
    echo -e "${YELLOW}Uninstalling BBR and restoring previous settings...${NC}"
    print_separator

    local backup
    backup=$(ls -1t /etc/sysctl.conf.backup.* 2>/dev/null | head -n1)

    if [ -n "$backup" ]; then
        echo -e "${YELLOW}Restoring backup file: $backup${NC}"
        cp "$backup" /etc/sysctl.conf
    else
        if grep -q "# BBR Optimization - Added by $SCRIPT_NAME" /etc/sysctl.conf 2>/dev/null; then
            sed -i "/# BBR Optimization - Added by $SCRIPT_NAME/,/net.core.wmem_max=16777216/d" /etc/sysctl.conf
            echo -e "${YELLOW}Removed BBR block from /etc/sysctl.conf${NC}"
        else
            echo -e "${YELLOW}No BBR backup or block found in /etc/sysctl.conf${NC}"
        fi
    fi

    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -p >/dev/null 2>&1 || true

    local cc
    cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "${GREEN}Current congestion control: ${cc}${NC}"
    echo -e "${GREEN}BBR uninstall / rollback completed.${NC}"
}
# ===============================================================

create_backup() {
    local ts backup_file
    ts=$(date +%Y%m%d_%H%M%S)
    backup_file="$BACKUP_DIR/network_backup_$ts.tar.gz"
    echo -e "${YELLOW}Creating backup...${NC}"
    local items=()
    [ -f /etc/resolv.conf ] && items+=("/etc/resolv.conf")
    [ -f /etc/sysctl.conf ] && items+=("/etc/sysctl.conf")
    [ -f /etc/network/interfaces ] && items+=("/etc/network/interfaces")
    [ -f "$CONFIG_FILE" ] && items+=("$CONFIG_FILE")
    [ -d /etc/netplan ] && items+=("/etc/netplan")
    [ -d /etc/sysconfig/network-scripts ] && items+=("/etc/sysconfig/network-scripts")
    [ ${#items[@]} -eq 0 ] && { echo -e "${RED}Nothing to backup${NC}"; return 1; }
    tar -czf "$backup_file" "${items[@]}" 2>/dev/null
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$BACKUP_DIR/iptables_$ts.rules"
    echo -e "${GREEN}Backup: $backup_file${NC}"
}

restore_backup() {
    [ ! -d "$BACKUP_DIR" ] && { echo -e "${RED}No backup dir${NC}"; return 1; }
    local list=() i=1
    for f in "$BACKUP_DIR"/*.tar.gz; do
        [ -f "$f" ] || continue
        echo "$i) $(basename "$f")"; list[$i]="$f"; ((i++))
    done
    [ ${#list[@]} -eq 0 ] && { echo -e "${RED}No backups${NC}"; return 1; }
    read -p "Select backup: " n
    local sel="${list[$n]}"; [ -z "$sel" ] && { echo -e "${RED}Invalid${NC}"; return 1; }
    echo -e "${YELLOW}Restoring $sel...${NC}"
    tar -xzf "$sel" -C / 2>/dev/null
    local rules="${sel%.tar.gz}.rules"
    [ -f "$rules" ] && command -v iptables-restore >/dev/null 2>&1 && iptables-restore < "$rules"
    echo -e "${GREEN}Restore done.${NC}"
}

self_update() {
    echo -e "${YELLOW}Local version: $SCRIPT_VERSION${NC}"
    echo -e "${YELLOW}Changes: VXLAN persistent${NC}"
}

manage_firewall() {
    echo -e "\n${YELLOW}Firewall Management${NC}"
    echo -e "1) Enable Firewall"
    echo -e "2) Disable Firewall"
    echo -e "3) Open Port"
    echo -e "4) Close Port"
    echo -e "5) List Open Ports"
    echo -e "6) Back"
    read -p "Choice [1-6]: " fw
    case $fw in
        1)
            if command -v ufw >/dev/null 2>&1; then ufw enable
            elif command -v firewall-cmd >/dev/null 2>&1; then systemctl enable --now firewalld; fi
            ;;
        2)
            if command -v ufw >/dev/null 2>&1; then ufw disable
            elif command -v firewall-cmd >/dev/null 2>&1; then systemctl disable --now firewalld; fi
            ;;
        3)
            read -p "Port: " port; read -p "Protocol (tcp/udp): " proto; proto=${proto:-tcp}
            if command -v ufw >/dev/null 2>&1; then ufw allow "$port"/"$proto"
            elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port="$port"/"$proto"; firewall-cmd --reload; fi
            ;;
        4)
            read -p "Port: " port; read -p "Protocol (tcp/udp): " proto; proto=${proto:-tcp}
            if command -v ufw >/dev/null 2>&1; then ufw deny "$port"/"$proto"
            elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --remove-port="$port"/"$proto"; firewall-cmd --reload; fi
            ;;
        5)
            if command -v ufw >/dev/null 2>&1; then ufw status verbose
            elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --list-all; fi
            ;;
    esac
    read -p "Enter to continue..."
}

manage_ipv6() {
    echo -e "\n${YELLOW}IPv6 Management${NC}"
    echo -e "1) Disable IPv6"
    echo -e "2) Enable IPv6"
    echo -e "3) Back"
    read -p "Choice [1-3]: " c
    case $c in
        1) sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1; sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 ;;
        2) sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1; sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 ;;
    esac
    read -p "Enter to continue..."
}

manage_tunnel() {
    echo -e "\n${YELLOW}IPTable Tunnel${NC}"
    echo -e "1) Route Iranian IP directly"
    echo -e "2) Route Foreign IP via Gateway"
    echo -e "3) Reset NAT"
    echo -e "4) Back"
    read -p "Choice [1-4]: " c
    case $c in
        1) read -p "Iran IP/CIDR: " iran; iptables -t nat -A POSTROUTING -d "$iran" -j ACCEPT ;;
        2) read -p "Foreign CIDR: " f; read -p "Gateway IP: " g; ip route add "$f" via "$g" ;;
        3) iptables -t nat -F ;;
    esac
    read -p "Enter to continue..."
}

# ==============================================================
# TCP MUX Configuration (Enhanced)
# ==============================================================
configure_tcp_mux() {
    echo -e "${YELLOW}Configuring TCP MUX with advanced stability & performance settings...${NC}"
    
    local mux_config="/etc/tcp_mux.conf"
    cat > "$mux_config" <<EOT
# TCP MUX Config - Advanced
remote_addr = "0.0.0.0:3080"
transport = "tcpmux"
token = "your_token"
connection_pool = 8
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
heartbeat = 40
channel_size = 2048
mux_con = 8
EOT

    echo -e "${BLUE}Applying advanced sysctl settings for low latency and high throughput...${NC}"
    
    sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null
    sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null
    sysctl -w net.core.rmem_max=33554432 >/dev/null
    sysctl -w net.core.wmem_max=33554432 >/dev/null
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null
    sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null
    sysctl -w net.ipv4.tcp_max_syn_backlog=16384 >/dev/null
    sysctl -w net.core.somaxconn=32768 >/dev/null
    sysctl -w net.core.netdev_max_backlog=10000 >/dev/null
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null
    sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null
    sysctl -w net.ipv4.tcp_keepalive_time=300 >/dev/null
    sysctl -w net.ipv4.tcp_keepalive_intvl=60 >/dev/null
    sysctl -w net.ipv4.tcp_keepalive_probes=10 >/dev/null
    
    sysctl -w net.core.rmem_default=262144 >/dev/null
    sysctl -w net.core.wmem_default=262144 >/dev/null
    
    echo -e "${GREEN}TCP MUX configured with performance optimizations.${NC}"
    echo -e "${YELLOW}Note: Some settings may require reboot to take full effect.${NC}"
}
# ==============================================================

system_reboot() {
    if ! confirm_action "Reboot system now?"; then echo -e "${YELLOW}Cancelled.${NC}"; return; fi
    save_config; create_backup
    echo -e "${RED}Rebooting in 3s...${NC}"; sleep 3; reboot
}

find_best_mtu() {
    echo -e "${YELLOW}Finding best MTU (1280-1500)...${NC}"
    local target="8.8.8.8" best_mtu=1500 best_time=99999
    for mtu in {1280..1500..20}; do
        local payload=$((mtu-28))
        echo -ne "MTU $mtu: "
        if ping -M do -s "$payload" -c 2 -W 2 "$target" >/tmp/mtu_test 2>&1; then
            local avg
            avg=$(awk -F'/' '/min\/avg\/max/ {print $5}' /tmp/mtu_test | cut -d. -f1)
            [ -z "$avg" ] && { echo "OK"; continue; }
            echo "${avg} ms"
            if [ "$avg" -lt "$best_time" ]; then best_time=$avg; best_mtu=$mtu; fi
        else
            echo "Failed"
        fi
    done
    rm -f /tmp/mtu_test
    if [ "$best_time" -eq 99999 ]; then echo -e "${RED}No stable MTU found${NC}"; return; fi
    echo -e "${GREEN}Best MTU: $best_mtu (${best_time} ms)${NC}"
    read -p "Apply this MTU? (y/n): " a
    [[ "$a" =~ ^[Yy]$ ]] && configure_mtu "$best_mtu"
}

# ========== VXLAN PERSISTENT ==========
create_vxlan_persistent_service() {
    local role="$1" remote_ip="$2" iface="$3"
    local vx_if="vxlan100" ipv4 ipv6
    if [ "$role" = "iran" ]; then
        ipv4="10.123.1.1/30"; ipv6="fd11:1ceb:1d11::1/64"
    else
        ipv4="10.123.1.2/30"; ipv6="fd11:1ceb:1d11::2/64"
    fi

    cat > /etc/vxlan100.conf <<EOF
ROLE=$role
IFACE=$iface
REMOTE_IP=$remote_ip
VXLAN_IF=$vx_if
LOCAL_IPV4=$ipv4
LOCAL_IPV6=$ipv6
EOF

    mkdir -p /usr/local/sbin

    cat > /usr/local/sbin/vxlan100-up <<'EOF'
#!/bin/bash
set -e
[ -f /etc/vxlan100.conf ] || exit 0
. /etc/vxlan100.conf
ip link del "$VXLAN_IF" 2>/dev/null || true
ip link add "$VXLAN_IF" type vxlan id 100 dev "$IFACE" remote "$REMOTE_IP" dstport 4789
ip addr add "$LOCAL_IPV4" dev "$VXLAN_IF" 2>/dev/null || true
ip -6 addr add "$LOCAL_IPV6" dev "$VXLAN_IF" 2>/dev/null || true
ip link set "$VXLAN_IF" up
EOF

    cat > /usr/local/sbin/vxlan100-down <<'EOF'
#!/bin/bash
ip link set vxlan100 down 2>/dev/null || true
ip link del vxlan100 2>/dev/null || true
EOF

    chmod +x /usr/local/sbin/vxlan100-up /usr/local/sbin/vxlan100-down

    cat > /etc/systemd/system/vxlan100.service <<EOF
[Unit]
Description=Persistent VXLAN 100 tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vxlan100-up
ExecStop=/usr/local/sbin/vxlan100-down

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now vxlan100.service
    systemctl is-active --quiet vxlan100.service && \
        echo -e "${GREEN}VXLAN100 persistent via systemd.${NC}" || \
        echo -e "${RED}vxlan100.service failed, check status.${NC}"
}

setup_iran_tunnel() {
    echo -e "${YELLOW}Setup IRAN VXLAN (local=10.123.1.1)...${NC}"
    read -p "Remote (kharej) IP: " REMOTE_IP
    [ -z "$REMOTE_IP" ] && { echo -e "${RED}Remote IP empty${NC}"; return; }
    local IFACE
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    [ -z "$IFACE" ] && { echo -e "${RED}No default iface${NC}"; return; }
    ip link del vxlan100 2>/dev/null || true
    ip link add vxlan100 type vxlan id 100 dev "$IFACE" remote "$REMOTE_IP" dstport 4789
    ip addr add 10.123.1.1/30 dev vxlan100 2>/dev/null || true
    ip -6 addr add fd11:1ceb:1d11::1/64 dev vxlan100 2>/dev/null || true
    ip link set vxlan100 up
    echo -e "${GREEN}IRAN VXLAN up (local 10.123.1.1).${NC}"
    create_vxlan_persistent_service "iran" "$REMOTE_IP" "$IFACE"
}

setup_kharej_tunnel() {
    echo -e "${YELLOW}Setup KHAREJ VXLAN (local=10.123.1.2)...${NC}"
    read -p "Remote (iran) IP: " REMOTE_IP
    [ -z "$REMOTE_IP" ] && { echo -e "${RED}Remote IP empty${NC}"; return; }
    local IFACE
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    [ -z "$IFACE" ] && { echo -e "${RED}No default iface${NC}"; return; }
    ip link del vxlan100 2>/dev/null || true
    ip link add vxlan100 type vxlan id 100 dev "$IFACE" remote "$REMOTE_IP" dstport 4789
    ip addr add 10.123.1.2/30 dev vxlan100 2>/dev/null || true
    ip -6 addr add fd11:1ceb:1d11::2/64 dev vxlan100 2>/dev/null || true
    ip link set vxlan100 up
    echo -e "${GREEN}KHAREJ VXLAN up (local 10.123.1.2).${NC}"
    create_vxlan_persistent_service "kharej" "$REMOTE_IP" "$IFACE"
}

delete_vxlan_tunnel() {
    if ! confirm_action "Delete VXLAN100 & systemd service?"; then return; fi
    ip link set vxlan100 down 2>/dev/null || true
    ip link del vxlan100 2>/dev/null || true
    systemctl disable --now vxlan100.service 2>/dev/null || true
    rm -f /etc/systemd/system/vxlan100.service /usr/local/sbin/vxlan100-up /usr/local/sbin/vxlan100-down /etc/vxlan100.conf
    systemctl daemon-reload
    echo -e "${GREEN}VXLAN100 removed.${NC}"
}

# ========== HAProxy ==========
install_haproxy_all_ports() {
    echo -e "${YELLOW}Installing HAProxy...${NC}"
    if ! command -v haproxy >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y haproxy
        else
            echo -e "${RED}Only apt-based HAProxy install implemented.${NC}"; return 1
        fi
    fi
    [ -f /etc/haproxy/haproxy.cfg ] && cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.$(date +%Y%m%d_%H%M%S)
    cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend de
    bind :::443
    mode tcp
    default_backend de
backend de
    mode tcp
    server myloc 10.123.1.2:443

frontend de2
    bind :::23902
    mode tcp
    default_backend de2
backend de2
    mode tcp
    server myloc 10.123.1.2:23902

frontend de3
    bind :::8081
    mode tcp
    default_backend de3
backend de3
    mode tcp
    server myloc 10.123.1.2:8081

frontend de4
    bind :::8080
    mode tcp
    default_backend de4
backend de4
    mode tcp
    server myloc 10.123.1.2:8080

frontend de5
    bind :::80
    mode tcp
    default_backend de5
backend de5
    mode tcp
    server myloc 10.123.1.2:80

frontend de6
    bind :::8443
    mode tcp
    default_backend de6
backend de6
    mode tcp
    server myloc 10.123.1.2:8443

frontend de7
    bind :::1080
    mode tcp
    default_backend de7
backend de7
    mode tcp
    server myloc 10.123.1.2:1080
EOF
    haproxy -c -f /etc/haproxy/haproxy.cfg || { echo -e "${RED}HAProxy config error${NC}"; return 1; }
    systemctl enable --now haproxy
    echo -e "${GREEN}HAProxy installed & started.${NC}"
}

# ========== New features ==========

# 1. GitHub Fixer
github_fixer() {
    echo -e "${YELLOW}Adding GitHub raw CDN to /etc/hosts...${NC}"
    local entry="185.199.108.133 raw.githubusercontent.com"
    if grep -q "raw.githubusercontent.com" /etc/hosts; then
        echo -e "${YELLOW}Entry already exists. Updating...${NC}"
        sed -i '/raw.githubusercontent.com/d' /etc/hosts
    fi
    echo "$entry" >> /etc/hosts
    echo -e "${GREEN}GitHub fix applied.${NC}"
}

# 2. Uninstall HAProxy complete
uninstall_haproxy_full() {
    if ! confirm_action "Uninstall HAProxy completely?"; then return; fi
    echo -e "${YELLOW}Stopping and removing HAProxy...${NC}"
    systemctl stop haproxy 2>/dev/null
    systemctl disable haproxy 2>/dev/null
    apt purge -y haproxy 2>/dev/null
    apt autoremove -y 2>/dev/null
    echo -e "${GREEN}HAProxy completely removed.${NC}"
}

# 3. Timezone fix to Asia/Tehran
timezone_fixer() {
    echo -e "${YELLOW}Setting timezone to Asia/Tehran...${NC}"
    timedatectl set-timezone Asia/Tehran 2>/dev/null || {
        echo -e "${RED}timedatectl not available, trying manual...${NC}"
        ln -sf /usr/share/zoneinfo/Asia/Tehran /etc/localtime
    }
    echo -e "${GREEN}Timezone set to $(timedatectl | grep "Time zone" | awk '{print $3}')${NC}"
}

# 4. BBR + fq_codel with advanced settings
bbr_fq_codel() {
    echo -e "${YELLOW}Applying BBR + fq_codel with advanced sysctl and limits...${NC}"
    
    modprobe nf_conntrack 2>/dev/null
    echo 1012144 | tee /sys/module/nf_conntrack/parameters/hashsize >/dev/null
    
    sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" >/dev/null
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" >/dev/null
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null
    sysctl -w net.netfilter.nf_conntrack_max=4048576 >/dev/null
    echo 65535 | tee /proc/sys/net/netfilter/nf_conntrack_expect_max >/dev/null
    sysctl -w net.ipv4.ip_local_port_range="10240 65535" >/dev/null
    sysctl -w net.core.somaxconn=65535 >/dev/null
    sysctl -w net.core.rmem_max=268435456 >/dev/null
    sysctl -w net.core.wmem_max=268435456 >/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
    sysctl -w net.ipv4.tcp_max_syn_backlog=65535 >/dev/null
    sysctl -w net.ipv4.tcp_mem="2097152 3145728 4194304" >/dev/null
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null
    
    echo -e "* soft nofile 2048576\n* hard nofile 2048576\nroot soft nofile 2048576\nroot hard nofile 2048576" | tee -a /etc/security/limits.conf >/dev/null
    sysctl -w fs.file-max=2048576 >/dev/null
    
    echo -e "${GREEN}BBR+fq_codel applied.${NC}"
}

# 5. Nameserver Fixer (reset DNS)
nameserver_fixer() {
    echo -e "${YELLOW}Resetting DNS to 1.1.1.1 and 8.8.8.8...${NC}"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}DNS reset.${NC}"
}

# 6. IPv6 Disable full
ipv6_disable_full() {
    echo -e "${YELLOW}Disabling IPv6 completely...${NC}"
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null
    
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}IPv6 disabled.${NC}"
}

# 7. System Lock Fixer
system_lock_fixer() {
    echo -e "${YELLOW}Fixing dpkg locks...${NC}"
    rm -f /var/lib/dpkg/lock*
    rm -f /var/cache/apt/archives/lock
    dpkg --configure -a
    echo -e "${GREEN}Locks cleared and dpkg reconfigured.${NC}"
}

# ==============================================================
# CPU Optimizer (separate script integrated)
# ==============================================================
cpu_optimizer() {
    # Internal functions for CPU Optimizer
    get_interface() {
        echo $(ip -4 route show default | awk '{print $5}' | head -1)
    }

    backup_files() {
        if [[ ! -f /etc/sysctl.conf.backup ]]; then
            cp /etc/sysctl.conf /etc/sysctl.conf.backup
            echo -e "${GREEN}Backup created: /etc/sysctl.conf.backup${NC}"
        fi
        if [[ ! -f /etc/resolv.conf.backup ]]; then
            cp /etc/resolv.conf /etc/resolv.conf.backup
            echo -e "${GREEN}Backup created: /etc/resolv.conf.backup${NC}"
        fi
    }

    restore_backups() {
        if [[ -f /etc/sysctl.conf.backup ]]; then
            cp /etc/sysctl.conf.backup /etc/sysctl.conf
            echo -e "${GREEN}Restored sysctl.conf from backup${NC}"
        fi
        if [[ -f /etc/resolv.conf.backup ]]; then
            cp /etc/resolv.conf.backup /etc/resolv.conf
            echo -e "${GREEN}Restored resolv.conf from backup${NC}"
        fi
    }

    install_prerequisites() {
        echo -e "${YELLOW}Installing prerequisites...${NC}"
        apt-get update
        apt-get install -y ethtool irqbalance nano curl wget
        echo -e "${GREEN}Prerequisites installed${NC}"
    }

    step1() {
        echo -e "${YELLOW}Step 1: Disabling TSO/GSO/GRO...${NC}"
        local IF=$(get_interface)
        if [[ -n "$IF" ]]; then
            ethtool -K $IF tso off gso off gro off
            echo -e "${GREEN}TSO/GSO/GRO disabled on $IF${NC}"
            if ! grep -q "ethtool -K $IF" /etc/rc.local; then
                sed -i '/exit 0/d' /etc/rc.local 2>/dev/null
                echo "ethtool -K $IF tso off gso off gro off" >> /etc/rc.local
                echo "exit 0" >> /etc/rc.local
                chmod +x /etc/rc.local
            fi
        else
            echo -e "${RED}Failed to detect network interface${NC}"
        fi
    }

    step2() {
        echo -e "${YELLOW}Step 2: Setting txqueuelen to 2500...${NC}"
        local IF=$(get_interface)
        if [[ -n "$IF" ]]; then
            ip link set dev $IF txqueuelen 2500
            echo -e "${GREEN}txqueuelen set to 2500 on $IF${NC}"
            if ! grep -q "ip link set dev $IF txqueuelen" /etc/rc.local; then
                sed -i '/exit 0/d' /etc/rc.local 2>/dev/null
                echo "ip link set dev $IF txqueuelen 2500" >> /etc/rc.local
                echo "exit 0" >> /etc/rc.local
                chmod +x /etc/rc.local
            fi
        else
            echo -e "${RED}Failed to detect network interface${NC}"
        fi
    }

    step3() {
        echo -e "${YELLOW}Step 3: Configuring irqbalance...${NC}"
        apt-get install -y irqbalance
        systemctl enable irqbalance
        systemctl start irqbalance
        echo -e "${GREEN}irqbalance configured and started${NC}"
    }

    step4() {
        echo -e "${YELLOW}Step 4: Applying HTB qdisc configuration...${NC}"
        local IF=$(get_interface)
        if [[ -n "$IF" ]]; then
            tc qdisc del dev $IF root 2>/dev/null
            tc qdisc add dev $IF root handle 1: htb default 20
            tc class add dev $IF parent 1: classid 1:1 htb rate 1gbit ceil 1gbit
            tc class add dev $IF parent 1:1 classid 1:10 htb rate 200mbit ceil 1gbit prio 1
            tc class add dev $IF parent 1:1 classid 1:20 htb rate 800mbit ceil 1gbit prio 2
            tc qdisc add dev $IF parent 1:10 handle 10: fq_codel limit 1000
            tc qdisc add dev $IF parent 1:20 handle 20: netem delay 15ms limit 10000
            tc filter add dev $IF parent 1: protocol ip prio 1 u32 match ip dport 22 0xffff flowid 1:10
            tc filter add dev $IF parent 1: protocol ip prio 1 u32 match ip sport 22 0xffff flowid 1:10
            tc filter add dev $IF parent 1: protocol ip prio 2 u32 match ip protocol 1 0xff flowid 1:10
            echo -e "${GREEN}HTB qdisc configuration applied${NC}"
        else
            echo -e "${RED}Failed to detect network interface${NC}"
        fi
    }

    step5() {
        echo -e "${YELLOW}Step 5: Applying Cake qdisc configuration...${NC}"
        local IF=$(get_interface)
        if [[ -n "$IF" ]]; then
            tc qdisc del dev $IF root 2>/dev/null
            tc qdisc add dev $IF root cake bandwidth 1Gbit besteffort ack-filter nat
            echo -e "${GREEN}Cake qdisc configuration applied${NC}"
        else
            echo -e "${RED}Failed to detect network interface${NC}"
        fi
    }

    step6() {
        echo -e "${YELLOW}Step 6: Applying sysctl configuration...${NC}"
        cat > /etc/sysctl.conf << 'EOF'
# System Optimization Settings
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
vm.swappiness = 5
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 65536
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1

# Network Core Settings
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.dev_weight = 64
net.core.default_qdisc = fq
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.optmem_max = 65536

# IPv4 Settings
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 1024 65535

# TCP Memory Settings
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_rmem = 8192 262144 8388608
net.ipv4.tcp_wmem = 8192 262144 8388608
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# TCP Optimization
net.ipv4.tcp_congestion_control = cubic
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_min_snd_mss = 536
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_early_retrans = 1
net.ipv4.tcp_recovery = 1
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_thin_dpio = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fin_timeout = 15

# TCP Keepalive Settings
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_keepalive_intvl = 15

# TCP Backlog Settings
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_max_orphans = 32768

# TCP Retry Settings
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_abort_on_overflow = 0

# Security Settings
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
        sysctl -p
        echo -e "${GREEN}sysctl configuration applied${NC}"
    }

    advanced_optimization() {
        echo -e "${YELLOW}Applying advanced server optimization...${NC}"
        cat >> /etc/sysctl.conf << 'EOF'

# Advanced Optimization Settings
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_tw_buckets = 200000
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 16384 8388608
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
EOF
        sysctl -p
        echo -e "${GREEN}Advanced optimization applied${NC}"
    }

    change_dns() {
        echo -e "${YELLOW}Changing DNS servers...${NC}"
        echo "Select DNS provider:"
        echo "1) Google DNS (8.8.8.8, 8.8.4.4)"
        echo "2) Cloudflare DNS (1.1.1.1, 1.0.0.1)"
        echo "3) OpenDNS (208.67.222.222, 208.67.220.220)"
        echo "4) Custom DNS"
        read -p "Choose option (1-4): " dns_choice
        case $dns_choice in
            1)
                echo "nameserver 8.8.8.8" > /etc/resolv.conf
                echo "nameserver 8.8.4.4" >> /etc/resolv.conf
                ;;
            2)
                echo "nameserver 1.1.1.1" > /etc/resolv.conf
                echo "nameserver 1.0.0.1" >> /etc/resolv.conf
                ;;
            3)
                echo "nameserver 208.67.222.222" > /etc/resolv.conf
                echo "nameserver 208.67.220.220" >> /etc/resolv.conf
                ;;
            4)
                read -p "Enter primary DNS: " dns1
                read -p "Enter secondary DNS: " dns2
                echo "nameserver $dns1" > /etc/resolv.conf
                echo "nameserver $dns2" >> /etc/resolv.conf
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                return
                ;;
        esac
        if [[ -f /etc/resolvconf/resolv.conf.d/head ]]; then
            cat /etc/resolv.conf > /etc/resolvconf/resolv.conf.d/head
            resolvconf -u
        fi
        echo -e "${GREEN}DNS changed successfully${NC}"
    }

    change_mtu() {
        echo -e "${YELLOW}Changing MTU...${NC}"
        local IF=$(get_interface)
        if [[ -n "$IF" ]]; then
            read -p "Enter MTU value (default: 1500): " mtu_value
            mtu_value=${mtu_value:-1500}
            ip link set dev $IF mtu $mtu_value
            echo -e "${GREEN}MTU changed to $mtu_value on $IF${NC}"
            if ! grep -q "ip link set dev $IF mtu" /etc/rc.local; then
                sed -i '/exit 0/d' /etc/rc.local 2>/dev/null
                echo "ip link set dev $IF mtu $mtu_value" >> /etc/rc.local
                echo "exit 0" >> /etc/rc.local
                chmod +x /etc/rc.local
            fi
        else
            echo -e "${RED}Failed to detect network interface${NC}"
        fi
    }

    uninstall_changes() {
        echo -e "${YELLOW}Uninstalling all changes...${NC}"
        restore_backups
        local IF=$(get_interface)
        if [[ -n "$IF" ]]; then
            tc qdisc del dev $IF root 2>/dev/null
            ethtool -K $IF tso on gso on gro on 2>/dev/null
            ip link set dev $IF txqueuelen 1000
        fi
        if [[ -f /etc/rc.local ]]; then
            > /etc/rc.local
            echo "#!/bin/bash" > /etc/rc.local
            echo "exit 0" >> /etc/rc.local
        fi
        systemctl stop irqbalance
        systemctl disable irqbalance
        echo -e "${GREEN}All changes uninstalled${NC}"
        echo -e "${YELLOW}Reboot recommended for complete reset${NC}"
    }

    full_installation() {
        echo -e "${BLUE}Starting full optimization installation...${NC}"
        backup_files
        install_prerequisites
        step1
        step2
        step3
        step4
        step5
        step6
        advanced_optimization
        echo -e "${GREEN}Full optimization completed successfully${NC}"
    }

    # Internal menu for CPU Optimizer
    while true; do
        clear
        echo -e "${BLUE}================================${NC}"
        echo -e "${GREEN}    CPU & Network Optimizer    ${NC}"
        echo -e "${BLUE}================================${NC}"
        echo -e "${YELLOW}Available options:${NC}"
        echo -e "${GREEN}1)${NC} Full installation (all optimizations)"
        echo -e "${GREEN}2)${NC} Uninstall all changes"
        echo -e "${GREEN}3)${NC} Reboot server"
        echo -e "${GREEN}4)${NC} Change DNS"
        echo -e "${GREEN}5)${NC} Change MTU"
        echo -e "${GREEN}6)${NC} Advanced optimization only"
        echo -e "${GREEN}7)${NC} Exit to main menu"
        echo -e "${BLUE}================================${NC}"
        read -p "Choose an option (1-7): " choice
        case $choice in
            1) full_installation; read -p "Press Enter to continue..." ;;
            2) uninstall_changes; read -p "Press Enter to continue..." ;;
            3) echo -e "${YELLOW}Rebooting server...${NC}"; reboot ;;
            4) change_dns; read -p "Press Enter to continue..." ;;
            5) change_mtu; read -p "Press Enter to continue..." ;;
            6) backup_files; advanced_optimization; read -p "Press Enter to continue..." ;;
            7) echo -e "${GREEN}Returning to main menu...${NC}"; return 0 ;;
            *) echo -e "${RED}Invalid option${NC}"; read -p "Press Enter to continue..." ;;
        esac
    done
}
# ==============================================================

reset_all() {
    if ! confirm_action "Reset ALL changes to default?"; then return; fi
    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>/dev/null
    CURRENT_MTU=1500
    reset_dns
    iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    iptables -t nat -F 2>/dev/null
    sed -i '/# BBR Optimization - Added by /,/net.core.wmem_max=16777216/d' /etc/sysctl.conf 2>/dev/null
    sed -i '/# TCP MUX Config/,/mux_con/d' /etc/sysctl.conf 2>/dev/null
    delete_vxlan_tunnel
    command -v haproxy >/dev/null 2>&1 && { systemctl disable --now haproxy 2>/dev/null || true; }
    rm -f "$CONFIG_FILE" /etc/tcp_mux.conf
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}All reset to default.${NC}"
}

show_menu() {
    load_config
    detect_distro
    while true; do
        show_header
        echo -e "${BOLD}Main Menu:${NC}"
        echo " 1) Install BBR Optimization"
        echo " 2) Configure MTU"
        echo " 3) Configure DNS (IPv4 & IPv6)"
        echo " 4) Firewall Management"
        echo " 5) CPU Optimizer (Full server optimization)"
        echo " 6) Manage IPv6"
        echo " 7) Setup IPTable Tunnel"
        echo " 8) Ping MTU Size Test"
        echo " 9) Reset ALL Changes"
        echo "10) Show Current DNS"
        echo "11) Network Speed Test"
        echo "12) Backup Configuration"
        echo "13) Restore Backup"
        echo "14) Check for Updates"
        echo "15) TCP MUX Configuration (Enhanced)"
        echo "16) Reboot System"
        echo "17) Find Best MTU Size"
        echo "18) Setup Iran VXLAN Tunnel"
        echo "19) Setup Kharej VXLAN Tunnel"
        echo "20) Delete VXLAN Tunnel"
        echo "21) Install HAProxy & All Ports"
        echo "24) GitHub Fixer (add raw.githubusercontent.com)"
        echo "25) Uninstall HAProxy (complete removal)"
        echo "26) WhatsApp Timezone Fixer (set to Asia/Tehran)"
        echo "27) BBR + fq_codel (advanced settings)"
        echo "28) Nameserver Fixer (1.1.1.1 & 8.8.8.8)"
        echo "29) Uninstall BBR"
        echo "30) Exit"
        echo "31) IPv6 Fixer (disable IPv6 permanently)"
        read -p "Enter your choice [1-31]: " choice
        case $choice in
            1)  install_bbr ;;
            2)  echo -e "Current MTU: $CURRENT_MTU"; read -p "New MTU: " m; [[ "$m" =~ ^[0-9]+$ ]] && configure_mtu "$m" || echo "invalid" ;;
            3)  configure_dns ;;
            4)  manage_firewall ;;
            5)  cpu_optimizer ;;
            6)  manage_ipv6 ;;
            7)  manage_tunnel ;;
            8)  ping_mtu ;;
            9)  reset_all ;;
            10) show_dns ;;
            11) speed_test ;;
            12) create_backup ;;
            13) restore_backup ;;
            14) self_update ;;
            15) configure_tcp_mux ;;
            16) system_reboot ;;
            17) find_best_mtu ;;
            18) setup_iran_tunnel ;;
            19) setup_kharej_tunnel ;;
            20) delete_vxlan_tunnel ;;
            21) install_haproxy_all_ports ;;
            24) github_fixer ;;
            25) uninstall_haproxy_full ;;
            26) timezone_fixer ;;
            27) bbr_fq_codel ;;
            28) nameserver_fixer ;;
            29) uninstall_bbr ;;
            30) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
            31) ipv6_disable_full ;;
            *)  echo -e "${RED}Invalid option!${NC}" ;;
        esac
        read -p "Press [Enter] to continue..."
    done
}

check_requirements
check_root
show_menu
