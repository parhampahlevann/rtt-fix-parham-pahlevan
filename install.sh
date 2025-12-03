#!/bin/bash

# =========================================================
# Ultimate Network Optimizer
# Version 9.6 - VXLAN persistent + Cloudflare WARP (warp-cli)
# Author: Parham Pahlevan
# =========================================================

SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="9.6"
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

    if command -v warp-cli >/dev/null 2>&1; then
        if systemctl is-active --quiet warp-svc 2>/dev/null; then
            local warp_flag warp_ip
            warp_flag=$(curl -s --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^warp=/{print $2}')
            warp_ip=$(curl -s --max-time 2 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
            if [[ "$warp_flag" == "on" || "$warp_flag" == "plus" ]]; then
                echo -e "${YELLOW}Cloudflare WARP: ${GREEN}Active (${warp_flag}, IP: ${warp_ip})${NC}"
            else
                echo -e "${YELLOW}Cloudflare WARP: ${YELLOW}Installed (warp=${warp_flag:-off})${NC}"
            fi
        else
            echo -e "${YELLOW}Cloudflare WARP: ${RED}Installed (service stopped)${NC}"
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

validate_ip() {
    local ip=$1
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
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

detect_dns_services() {
    echo "Detecting DNS-related services..."; print_separator
    for svc in "${DNS_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            DETECTED_SERVICES_STATUS["$svc"]="active"
            echo -e "${YELLOW}$svc (active)${NC}"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            DETECTED_SERVICES_STATUS["$svc"]="enabled"
            echo -e "${YELLOW}$svc (enabled)${NC}"
        elif command -v "$svc" >/dev/null 2>&1; then
            DETECTED_SERVICES_STATUS["$svc"]="installed"
            echo -e "${YELLOW}$svc (installed)${NC}"
        fi
    done
}

disable_service() {
    local svc="$1"
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
}

set_resolv_conf() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<EOF
# Generated by $SCRIPT_NAME
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

update_resolv_conf() {
    local dns_servers=("$@")
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cp /etc/resolv.conf /etc/resolv.conf.backup."$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    cat > /etc/resolv.conf <<EOL
# Generated by $SCRIPT_NAME
# $(date)

EOL
    for d in "${dns_servers[@]}"; do
        echo "nameserver $d" >> /etc/resolv.conf
    done
    echo "options rotate timeout:1 attempts:2" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

manage_dns_services_enhanced() {
    detect_dns_services
    if [ ${#DETECTED_SERVICES_STATUS[@]} -eq 0 ]; then
        echo -e "${GREEN}No DNS services detected.${NC}"; return
    fi
    while true; do
        echo ""; print_separator
        echo "Detected DNS Services:"
        local i=1; declare -A service_list
        for s in "${!DETECTED_SERVICES_STATUS[@]}"; do
            echo "$i) $s (${DETECTED_SERVICES_STATUS[$s]})"
            service_list[$i]="$s"; ((i++))
        done
        local all=$i; echo "$all) All Services"
        local back=$((i+1)); echo "$back) Back"
        read -p "Select: " ch
        if [ "$ch" -eq "$all" ]; then
            for s in "${!DETECTED_SERVICES_STATUS[@]}"; do disable_service "$s"; done
            set_resolv_conf; break
        elif [ "$ch" -eq "$back" ]; then
            return
        elif [ -n "${service_list[$ch]}" ]; then
            local svc="${service_list[$ch]}"
            echo "1) Disable  2) Disable+Remove  3) Back"
            read -p "Action: " ac
            case $ac in
                1) disable_service "$svc" ;;
                2) disable_service "$svc"; if command -v apt-get >/dev/null 2>&1; then apt-get remove --purge -y "$svc"; fi ;;
                3) ;;
            esac
        fi
        read -p "Enter to continue..."; 
    done
}

configure_dns_safe() {
    local dns_servers=("$@")
    echo -e "${YELLOW}Configuring DNS...${NC}"
    manage_dns_services_enhanced
    update_resolv_conf "${dns_servers[@]}"
    if command -v nmcli >/dev/null 2>&1 && (systemctl is-active --quiet NetworkManager 2>/dev/null || pgrep NetworkManager >/dev/null); then
        local con_name
        con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" ipv4.dns "$(printf "%s;" "${dns_servers[@]}" | sed 's/;$//')"
            nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
            nmcli con down "$con_name" 2>/dev/null; nmcli con up "$con_name" 2>/dev/null
        fi
    fi
}

configure_dns() {
    echo -e "\n${YELLOW}Manual DNS Configuration${NC}"
    echo -e "${YELLOW}Example: 1.1.1.1 1.0.0.1 8.8.8.8${NC}"
    read -p "Enter DNS servers: " dns_input
    [ -z "$dns_input" ] && { echo -e "${RED}No DNS entered${NC}"; return 1; }
    local new_dns=($dns_input) valid=()
    for d in "${new_dns[@]}"; do
        if validate_ip "$d"; then valid+=("$d"); else echo -e "${RED}Invalid IP: $d${NC}"; fi
    done
    [ ${#valid[@]} -eq 0 ] && { echo -e "${RED}No valid DNS${NC}"; return 1; }
    configure_dns_safe "${valid[@]}"
    DNS_SERVERS=("${valid[@]}")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    echo -e "${GREEN}DNS updated: ${DNS_SERVERS[*]}${NC}"
}

reset_dns() {
    echo -e "${YELLOW}Resetting default DNS...${NC}"
    local default_dns=("8.8.8.8" "8.8.4.4")
    chattr -i /etc/resolv.conf 2>/dev/null || true
    local backup
    backup=$(ls -t /etc/resolv.conf.backup.* 2>/dev/null | head -n1)
    if [ -n "$backup" ]; then
        cp "$backup" /etc/resolv.conf
    else
        cat > /etc/resolv.conf <<EOL
# $SCRIPT_NAME reset
nameserver 8.8.8.8
nameserver 8.8.4.4
EOL
    fi
    if command -v nmcli >/dev/null 2>&1 && (systemctl is-active --quiet NetworkManager 2>/dev/null || pgrep NetworkManager >/dev/null); then
        local con_name
        con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        [ -n "$con_name" ] && {
            nmcli con mod "$con_name" ipv4.ignore-auto-dns no
            nmcli con mod "$con_name" ipv4.dns ""
            nmcli con down "$con_name" 2>/dev/null; nmcli con up "$con_name" 2>/dev/null
        }
    fi
    DNS_SERVERS=("${default_dns[@]}")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    echo -e "${GREEN}DNS reset to Google DNS${NC}"
}

show_dns() {
    echo -e "\n${YELLOW}Current DNS:${NC}"
    echo -e "${BOLD}/etc/resolv.conf:${NC}"
    grep -vE "^(#|$)" /etc/resolv.conf 2>/dev/null || echo "Cannot read"
    echo -e "----------------------------------------"
    echo -e "${BOLD}$NETWORK_INTERFACE DNS (nmcli):${NC}"
    command -v nmcli >/dev/null 2>&1 && nmcli dev show "$NETWORK_INTERFACE" 2>/dev/null | grep DNS || echo "No nmcli info"
    echo -e "----------------------------------------"
    echo -e "${YELLOW}Configured DNS: ${BOLD}$CURRENT_DNS${NC}"
}

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
    echo -e "${YELLOW}Changes: VXLAN persistent + warp-cli WARP${NC}"
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

manage_icmp() {
    echo -e "\n${YELLOW}ICMP Ping Management${NC}"
    echo -e "1) Block Ping"
    echo -e "2) Allow Ping"
    echo -e "3) Back"
    read -p "Choice [1-3]: " c
    case $c in
        1) iptables -A INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null ;;
        2) iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null ;;
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

configure_tcp_mux() {
    echo -e "${YELLOW}Configuring TCP MUX...${NC}"
    local mux_config="/etc/tcp_mux.conf"
    cat > "$mux_config" <<EOT
# TCP MUX Config
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
    sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216'
    sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216'
    sysctl -w net.core.rmem_max=33554432
    sysctl -w net.core.wmem_max=33554432
    sysctl -w net.ipv4.tcp_tw_reuse=1
    sysctl -w net.ipv4.tcp_fin_timeout=30
    sysctl -w net.ipv4.tcp_max_syn_backlog=16384
    sysctl -w net.core.somaxconn=32768
    echo -e "${GREEN}TCP MUX configured (${mux_config}).${NC}"
}

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

# ========== CLOUDFLARE WARP (warp-cli) ==========
check_warp_status() {
    echo -e "${YELLOW}Checking WARP status...${NC}"
    command -v warp-cli >/dev/null 2>&1 || { echo -e "${RED}warp-cli not installed${NC}"; return 1; }
    systemctl start warp-svc 2>/dev/null || true
    sleep 2
    warp-cli status 2>/dev/null || true
    local warp_flag ip
    warp_flag=$(curl -s --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^warp=/{print $2}')
    ip=$(curl -s --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    echo -e "warp=${warp_flag:-unknown}, ip=${ip:-unknown}"
}

install_warp_cloudflare() {
    echo -e "${YELLOW}Installing Cloudflare WARP (warp-cli)...${NC}"
    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${RED}Only Ubuntu/Debian (apt) auto install implemented.${NC}"
        return 1
    fi
    apt-get update -y
    apt-get install -y curl gnupg lsb-release
    curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" > /etc/apt/sources.list.d/cloudflare-warp.list
    apt-get update -y
    apt-get install -y cloudflare-warp
    systemctl enable --now warp-svc
    sleep 3
    warp-cli --accept-tos registration new 2>/dev/null || warp-cli registration new
    warp-cli set-mode warp+doh 2>/dev/null || true
    warp-cli connect || true
    sleep 4
    check_warp_status
}

warp_choose_endpoint() {
    command -v warp-cli >/dev/null 2>&1 || { echo -e "${RED}warp-cli not installed${NC}"; return 1; }
    echo -e "${YELLOW}Choose WARP endpoint:${NC}"
    echo "1) Default (auto)"
    echo "2) 162.159.192.1"
    echo "3) 162.159.192.8"
    echo "4) 162.159.193.5"
    echo "5) Custom IP"
    echo "6) Back"
    read -p "Choice [1-6]: " c
    local ep=""
    case $c in
        1) warp-cli clear-custom-endpoint 2>/dev/null || true ;;
        2) ep="162.159.192.1" ;;
        3) ep="162.159.192.8" ;;
        4) ep="162.159.193.5" ;;
        5) read -p "Enter IP: " ep; validate_ip "$ep" || { echo -e "${RED}Invalid IP${NC}"; return 1; } ;;
        6) return 0 ;;
        *) echo -e "${RED}Invalid${NC}"; return 1 ;;
    esac
    if [ -n "$ep" ]; then warp-cli set-custom-endpoint "$ep" 2>/dev/null || true; fi
    warp-cli disconnect 2>/dev/null || true
    sleep 2
    warp-cli connect || true
    sleep 3
    check_warp_status
}

warp_auto_optimize_endpoint() {
    command -v warp-cli >/dev/null 2>&1 || { echo -e "${RED}warp-cli not installed${NC}"; return 1; }
    echo -e "${YELLOW}Auto-select best endpoint by ping...${NC}"
    local eps=("162.159.192.1" "162.159.192.5" "162.159.192.8" "162.159.193.1" "162.159.193.5")
    if [ -f /etc/warp_endpoints.txt ]; then
        while IFS= read -r line; do
            line=$(echo "$line" | tr -d ' ')
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            eps+=("$line")
        done < /etc/warp_endpoints.txt
    fi
    local best="" best_rtt=99999
    for ip in "${eps[@]}"; do
        echo -ne "Ping $ip ... "
        local rtt
        rtt=$(ping -c 3 -W 1 "$ip" 2>/dev/null | awk -F'/' '/min\/avg\/max/ {print $5}' | cut -d. -f1)
        if [ -n "$rtt" ]; then
            echo "${rtt} ms"
            if [ "$rtt" -lt "$best_rtt" ]; then best_rtt=$rtt; best=$ip; fi
        else
            echo "timeout"
        fi
    done
    [ -z "$best" ] && { echo -e "${RED}No reachable endpoint${NC}"; return 1; }
    echo -e "${GREEN}Best endpoint: $best (${best_rtt} ms)${NC}"
    warp-cli set-custom-endpoint "$best" 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true
    sleep 2
    warp-cli connect || true
    sleep 3
    check_warp_status
}

warp_split_tunnel_menu() {
    command -v warp-cli >/dev/null 2>&1 || { echo -e "${RED}warp-cli not installed${NC}"; return 1; }
    while true; do
        echo -e "\n${YELLOW}WARP Split-Tunnel (excluded routes)${NC}"
        echo "1) Exclude private ranges (LAN)"
        echo "2) Add custom CIDR to exclude"
        echo "3) Remove excluded CIDR"
        echo "4) List excluded routes"
        echo "5) Back"
        read -p "Choice [1-5]: " c
        case $c in
            1)
                for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 100.64.0.0/10; do
                    warp-cli add-excluded-route "$cidr" 2>/dev/null || true
                done
                echo -e "${GREEN}LAN ranges excluded from WARP.${NC}"
                ;;
            2)
                read -p "CIDR to exclude: " cidr
                [ -z "$cidr" ] && continue
                warp-cli add-excluded-route "$cidr" 2>/dev/null || true
                echo -e "${GREEN}Added: $cidr${NC}"
                ;;
            3)
                read -p "CIDR to remove: " cidr
                [ -z "$cidr" ] && continue
                warp-cli remove-excluded-route "$cidr" 2>/dev/null || true
                echo -e "${GREEN}Removed: $cidr (if existed)${NC}"
                ;;
            4)
                warp-cli list-excluded-routes 2>/dev/null || echo "No data"
                ;;
            5) return 0 ;;
        esac
        read -p "Enter to continue..."
    done
}

remove_warp() {
    if ! confirm_action "Remove Cloudflare WARP (warp-cli)?"; then return; fi
    if command -v warp-cli >/dev/null 2>&1; then
        warp-cli disconnect 2>/dev/null || true
        warp-cli registration delete 2>/dev/null || true
    fi
    systemctl disable --now warp-svc 2>/dev/null || true
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove --purge -y cloudflare-warp 2>/dev/null || true
    fi
    echo -e "${GREEN}WARP removed.${NC}"
}

manage_warp() {
    while true; do
        echo -e "\n${YELLOW}Cloudflare WARP Management${NC}"
        echo "1) Install/Reinstall WARP (warp-cli)"
        echo "2) Check WARP Status"
        echo "3) Restart warp-svc"
        echo "4) Stop warp-svc"
        echo "5) Choose Custom Endpoint (IP)"
        echo "6) Auto-select Best Endpoint (ping)"
        echo "7) Configure Split Tunnel"
        echo "8) Remove WARP"
        echo "9) View warp-svc Logs"
        echo "10) Back"
        read -p "Choice [1-10]: " w
        case $w in
            1) install_warp_cloudflare ;;
            2) check_warp_status ;;
            3) systemctl restart warp-svc 2>/dev/null || echo "restart failed"; sleep 2; check_warp_status ;;
            4) systemctl stop warp-svc 2>/dev/null || echo "stop failed" ;;
            5) warp_choose_endpoint ;;
            6) warp_auto_optimize_endpoint ;;
            7) warp_split_tunnel_menu ;;
            8) remove_warp ;;
            9) journalctl -u warp-svc --no-pager -n 30 2>/dev/null || echo "no logs" ;;
            10) return ;;
        esac
        read -p "Enter to continue..."
    done
}

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
    remove_warp
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
        echo "1) Install BBR Optimization"
        echo "2) Configure MTU"
        echo "3) Configure DNS"
        echo "4) Firewall Management"
        echo "5) Manage ICMP Ping"
        echo "6) Manage IPv6"
        echo "7) Setup IPTable Tunnel"
        echo "8) Ping MTU Size Test"
        echo "9) Reset ALL Changes"
        echo "10) Show Current DNS"
        echo "11) Network Speed Test"
        echo "12) Backup Configuration"
        echo "13) Restore Backup"
        echo "14) Check for Updates"
        echo "15) TCP MUX Configuration"
        echo "16) Reboot System"
        echo "17) Find Best MTU Size"
        echo "18) Setup Iran VXLAN Tunnel"
        echo "19) Setup Kharej VXLAN Tunnel"
        echo "20) Delete VXLAN Tunnel"
        echo "21) Install HAProxy & All Ports"
        echo "22) Cloudflare WARP Management"
        echo "23) Exit"
        read -p "Enter your choice [1-23]: " choice
        case $choice in
            1)  install_bbr ;;
            2)  echo -e "Current MTU: $CURRENT_MTU"; read -p "New MTU: " m; [[ "$m" =~ ^[0-9]+$ ]] && configure_mtu "$m" || echo "invalid" ;;
            3)  configure_dns ;;
            4)  manage_firewall ;;
            5)  manage_icmp ;;
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
            22) manage_warp ;;
            23) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
            *)  echo -e "${RED}Invalid option!${NC}" ;;
        esac
        read -p "Press [Enter] to continue..."
    done
}

check_requirements
check_root
show_menu
