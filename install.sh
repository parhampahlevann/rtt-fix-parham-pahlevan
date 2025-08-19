#!/bin/bash
# Global Configuration
SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="8.7"  # نسخه به‌روزرسانی شده
AUTHOR="Parham Pahleven"
CONFIG_FILE="/etc/network_optimizer.conf"
LOG_FILE="/var/log/network_optimizer.log"
DEFAULT_MTU=1500

# پیدا کردن رابط شبکه به‌صورت پویا
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$NETWORK_INTERFACE" ]; then
    echo -e "\033[0;31mError: No default network interface detected! Please check your network configuration.\033[0m"
    exit 1
fi
CURRENT_MTU=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo $DEFAULT_MTU)
DNS_SERVERS=("1.1.1.1" "1.0.0.1")
CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')

# Initialize logging
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting $SCRIPT_NAME v$SCRIPT_VERSION" >> "$LOG_FILE"

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Check Dependencies
check_dependencies() {
    local deps=("ip" "ping" "iptables" "bc" "dig" "sysctl")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}Installing missing dependencies: ${missing_deps[*]}${NC}"
        apt-get update && apt-get install -y iproute2 iputils-ping iptables bc dnsutils procps || {
            echo -e "${RED}Failed to install dependencies!${NC}"
            exit 1
        }
    fi
}

# Save Configuration
save_config() {
    cat > "$CONFIG_FILE" <<EOL
# Network Optimizer Configuration
MTU=$CURRENT_MTU
DNS_SERVERS=(${DNS_SERVERS[@]})
NETWORK_INTERFACE=$NETWORK_INTERFACE
EOL
    chmod 600 "$CONFIG_FILE"
}

# Load Configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        CURRENT_MTU=${MTU:-1500}
        DNS_SERVERS=(${DNS_SERVERS[@]})
        NETWORK_INTERFACE=${NETWORK_INTERFACE:-$(ip route | grep default | awk '{print $5}' | head -n1)}
    fi
}

# Header Display
show_header() {
    clear
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════╗"
    echo -e "║           $SCRIPT_NAME ${SCRIPT_VERSION} - $AUTHOR           ║"
    echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Interface: ${BOLD}${NETWORK_INTERFACE:-Not detected}${NC}"
    echo -e "${YELLOW}Current MTU: ${BOLD}$CURRENT_MTU${NC}"
    echo -e "${YELLOW}Current DNS: ${BOLD}${CURRENT_DNS:-Not detected}${NC}"
    
    # Show BBR Status
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "Unknown")
    if [[ "$bbr_status" == "bbr" ]]; then
        echo -e "${YELLOW}BBR Status: ${GREEN}Enabled${NC}"
    else
        echo -e "${YELLOW}BBR Status: ${RED}Disabled ($bbr_status)${NC}"
    fi
    
    # Show Firewall Status
    if command -v ufw >/dev/null 2>&1; then
        local fw_status=$(ufw status | grep -o "active" || echo "inactive")
        echo -e "${YELLOW}Firewall Status: ${BOLD}$fw_status${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        local fw_status=$(firewall-cmd --state 2>/dev/null || echo "inactive")
        echo -e "${YELLOW}Firewall Status: ${BOLD}$fw_status${NC}"
    else
        echo -e "${YELLOW}Firewall Status: ${BOLD}Not detected${NC}"
    fi
    
    # Show ICMP Status
    local icmp_status=$(iptables -L INPUT -n 2>/dev/null | grep "icmp" | grep -o "DROP" || echo "ACCEPT")
    if [ "$icmp_status" == "DROP" ]; then
        echo -e "${YELLOW}ICMP Ping: ${RED}Blocked${NC}"
    else
        echo -e "${YELLOW}ICMP Ping: ${GREEN}Allowed${NC}"
    fi
    
    # Show IPv6 Status
    local ipv6_status=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}' || echo "0")
    if [ "$ipv6_status" == "1" ]; then
        echo -e "${YELLOW}IPv6: ${RED}Disabled${NC}"
    else
        echo -e "${YELLOW}IPv6: ${GREEN}Enabled${NC}"
    fi
    
    # Show Connection Status
    if _test_connectivity; then
        echo -e "${YELLOW}Internet: ${GREEN}Connected${NC}"
    else
        echo -e "${YELLOW}Internet: ${RED}Disconnected${NC}"
    fi
    echo
}

# Check Root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
}

# Test Connectivity
_test_connectivity() {
    local target="1.1.1.1"
    if ping -c 2 -W 3 "$target" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Ping with Custom MTU
ping_mtu() {
    read -p "Enter MTU size to test (e.g., 1420): " test_mtu
    if [[ "$test_mtu" =~ ^[0-9]+$ && $test_mtu -ge 68 && $test_mtu -le 9000 ]]; then
        echo -e "${YELLOW}Testing ping with MTU=$test_mtu...${NC}"
        ping -M do -s $((test_mtu - 28)) -c 4 1.1.1.1 || echo -e "${RED}Ping failed!${NC}"
    else
        echo -e "${RED}Invalid MTU value! Must be between 68 and 9000.${NC}"
    fi
}

# Universal MTU Configuration - FIXED
configure_mtu() {
    local new_mtu=$1
    local old_mtu=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo $DEFAULT_MTU)

    # بررسی وجود رابط شبکه
    if [ -z "$NETWORK_INTERFACE" ] || ! ip link show "$NETWORK_INTERFACE" >/dev/null 2>&1; then
        echo -e "${RED}Error: Network interface '$NETWORK_INTERFACE' not found or invalid!${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid network interface '$NETWORK_INTERFACE'" >> "$LOG_FILE"
        return 1
    fi

    # بررسی معتبر بودن مقدار MTU
    if [[ ! "$new_mtu" =~ ^[0-9]+$ || $new_mtu -lt 68 || $new_mtu -gt 9000 ]]; then
        echo -e "${RED}Invalid MTU value! Must be between 68 and 9000.${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid MTU value '$new_mtu'" >> "$LOG_FILE"
        return 1
    fi

    echo -e "${YELLOW}Setting MTU to $new_mtu on $NETWORK_INTERFACE...${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Setting MTU to $new_mtu on $NETWORK_INTERFACE" >> "$LOG_FILE"

    # بررسی وضعیت رابط شبکه
    if ! ip link show "$NETWORK_INTERFACE" | grep -q "state UP"; then
        echo -e "${YELLOW}Bringing up network interface $NETWORK_INTERFACE...${NC}"
        if ! ip link set "$NETWORK_INTERFACE" up 2>/dev/null; then
            echo -e "${RED}Failed to bring up network interface!${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to bring up interface '$NETWORK_INTERFACE'" >> "$LOG_FILE"
            return 1
        fi
    fi

    # تنظیم MTU موقت
    if ! ip link set dev "$NETWORK_INTERFACE" mtu "$new_mtu" 2>/dev/null; then
        echo -e "${RED}Failed to set temporary MTU!${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to set MTU to $new_mtu on $NETWORK_INTERFACE" >> "$LOG_FILE"
        return 1
    fi

    # به‌روزرسانی فایل MTU در کرنل
    if ! echo "$new_mtu" > "/sys/class/net/$NETWORK_INTERFACE/mtu" 2>/dev/null; then
        echo -e "${YELLOW}Warning: Could not update MTU via sysfs${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: Failed to update MTU via sysfs" >> "$LOG_FILE"
    fi

    # تست اتصال
    echo -e "${YELLOW}Testing connectivity with new MTU...${NC}"
    sleep 2
    if ! _test_connectivity; then
        echo -e "${RED}Connectivity test failed! Rolling back MTU...${NC}"
        ip link set dev "$NETWORK_INTERFACE" mtu "$old_mtu" 2>/dev/null
        echo "$old_mtu" > "/sys/class/net/$NETWORK_INTERFACE/mtu" 2>/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Connectivity test failed, rolled back to MTU $old_mtu" >> "$LOG_FILE"
        return 1
    fi

    # اعمال تنظیمات دائمی
    echo -e "${YELLOW}Making MTU change permanent...${NC}"

    # Netplan (Ubuntu 18.04+)
    if [[ -d /etc/netplan ]] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        local netplan_file=$(ls /etc/netplan/*.yaml | head -n1)
        if grep -q "$NETWORK_INTERFACE" "$netplan_file"; then
            if grep -q "mtu:" "$netplan_file"; then
                sed -i "/$NETWORK_INTERFACE:/,/^[^[:space:]]/ s/mtu:.*/mtu: $new_mtu/" "$netplan_file"
            else
                sed -i "/$NETWORK_INTERFACE:/a\      mtu: $new_mtu" "$netplan_file"
            fi
            netplan apply >/dev/null 2>&1 && echo -e "${GREEN}Netplan configuration updated${NC}" || {
                echo -e "${RED}Failed to apply Netplan configuration${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to apply Netplan configuration" >> "$LOG_FILE"
            }
        fi
    fi

    # Network interfaces (Debian)
    elif [[ -f /etc/network/interfaces ]]; then
        if grep -q "$NETWORK_INTERFACE" /etc/network/interfaces; then
            if grep -q "mtu" /etc/network/interfaces; then
                sed -i "/iface $NETWORK_INTERFACE/,/^$/ s/mtu.*/mtu $new_mtu/" /etc/network/interfaces
            else
                sed -i "/iface $NETWORK_INTERFACE/ a\    mtu $new_mtu" /etc/network/interfaces
            fi
        fi
    fi

    # NetworkManager
    elif command -v nmcli >/dev/null 2>&1; then
        local connection_name=$(nmcli -t -f DEVICE,NAME con show | grep "^$NETWORK_INTERFACE:" | cut -d: -f2 | head -n1)
        if [ -n "$connection_name" ]; then
            nmcli connection modify "$connection_name" 802-3-ethernet.mtu "$new_mtu" 2>/dev/null
            nmcli connection up "$connection_name" >/dev/null 2>&1 || {
                echo -e "${RED}Failed to apply NetworkManager configuration${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to apply NetworkManager configuration" >> "$LOG_FILE"
            }
        fi
    fi

    CURRENT_MTU=$new_mtu
    save_config
    echo -e "${GREEN}MTU successfully set to $new_mtu and made permanent${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: MTU set to $new_mtu on $NETWORK_INTERFACE" >> "$LOG_FILE"
    return 0
}

# Update DNS Configuration
update_dns() {
    echo -e "${YELLOW}Setting DNS servers: ${DNS_SERVERS[*]}${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Setting DNS servers: ${DNS_SERVERS[*]}" >> "$LOG_FILE"
    
    local dns_configured=false
    local connection_name=""
    
    # Method 1: NetworkManager
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
        connection_name=$(nmcli -t -f DEVICE,NAME con show | grep "^$NETWORK_INTERFACE:" | cut -d: -f2 | head -n1)
        if [ -n "$connection_name" ]; then
            echo -e "${YELLOW}Configuring DNS via NetworkManager: $connection_name${NC}"
            nmcli con mod "$connection_name" ipv4.dns "$(echo ${DNS_SERVERS[@]} | tr ' ' ',')"
            nmcli con mod "$connection_name" ipv4.ignore-auto-dns yes
            nmcli con mod "$connection_name" ipv4.may-fail no
            nmcli con mod "$connection_name" ipv6.dns "$(echo ${DNS_SERVERS[@]} | tr ' ' ',')"
            nmcli con mod "$connection_name" ipv6.ignore-auto-dns yes
            nmcli con mod "$connection_name" ipv6.may-fail no
            nmcli con down "$connection_name" 2>/dev/null
            sleep 2
            nmcli con up "$connection_name" 2>/dev/null
            local nmcli_dns=$(nmcli -g ipv4.dns con show "$connection_name" 2>/dev/null)
            if [[ "$nmcli_dns" == *"${DNS_SERVERS[0]}"* ]]; then
                dns_configured=true
                echo -e "${GREEN}DNS set via NetworkManager${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: DNS set via NetworkManager" >> "$LOG_FILE"
            else
                echo -e "${RED}Failed to set DNS via NetworkManager${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to set DNS via NetworkManager" >> "$LOG_FILE"
            fi
        fi
    fi
    
    # Method 2: systemd-resolved
    if command -v systemctl >/dev/null 2>&1 && [ "$dns_configured" = false ]; then
        if systemctl is-active systemd-resolved >/dev/null 2>&1; then
            echo -e "${YELLOW}Configuring DNS via systemd-resolved...${NC}"
            cat > /etc/systemd/resolved.conf <<EOL
[Resolve]
DNS=${DNS_SERVERS[*]}
Domains=~.
DNSOverTLS=opportunistic
DNSSEC=allow-downgrade
Cache=yes
DNSStubListener=yes
EOL
            for dns in "${DNS_SERVERS[@]}"; do
                resolvectl dns "$NETWORK_INTERFACE" "$dns" 2>/dev/null || true
            done
            systemctl restart systemd-resolved
            resolvectl flush-caches
            local resolved_dns=$(resolvectl status | grep "DNS Servers" | head -n1 | awk '{print $3}' 2>/dev/null)
            if [[ "$resolved_dns" == *"${DNS_SERVERS[0]}"* ]]; then
                dns_configured=true
                echo -e "${GREEN}DNS set via systemd-resolved${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: DNS set via systemd-resolved" >> "$LOG_FILE"
            else
                echo -e "${RED}Failed to set DNS via systemd-resolved${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to set DNS via systemd-resolved" >> "$LOG_FILE"
            fi
        fi
    fi
    
    # Method 3: Traditional resolv.conf
    if [ "$dns_configured" = false ]; then
        echo -e "${YELLOW}Configuring DNS via /etc/resolv.conf...${NC}"
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
        cat > /etc/resolv.conf <<EOL
# Generated by $SCRIPT_NAME
$(for dns in "${DNS_SERVERS[@]}"; do echo "nameserver $dns"; done)
options rotate timeout:2 attempts:3
EOL
        chattr +i /etc/resolv.conf 2>/dev/null && \
        echo -e "${GREEN}resolv.conf made immutable${NC}" || \
        echo -e "${YELLOW}Warning: Could not make resolv.conf immutable${NC}"
        local resolv_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -n1)
        if [[ "$resolv_dns" == "${DNS_SERVERS[0]}" ]]; then
            dns_configured=true
            echo -e "${GREEN}DNS set via resolv.conf${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: DNS set via resolv.conf" >> "$LOG_FILE"
        else
            echo -e "${RED}Failed to set DNS via resolv.conf${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to set DNS via resolv.conf" >> "$LOG_FILE"
        fi
    fi
    
    # Method 4: resolvconf utility
    if command -v resolvconf >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring DNS via resolvconf...${NC}"
        cat > /etc/resolvconf/resolv.conf.d/base <<EOL
$(for dns in "${DNS_SERVERS[@]}"; do echo "nameserver $dns"; done)
EOL
        resolvconf -u
        local resolvconf_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -n1)
        if [[ "$resolvconf_dns" == "${DNS_SERVERS[0]}" ]]; then
            dns_configured=true
            echo -e "${GREEN}DNS set via resolvconf${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: DNS set via resolvconf" >> "$LOG_FILE"
        else
            echo -e "${RED}Failed to set DNS via resolvconf${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to set DNS via resolvconf" >> "$LOG_FILE"
        fi
    fi
    
    # Method 5: DHCP configuration
    if [ -f /etc/dhcp/dhclient.conf ]; then
        echo -e "${YELLOW}Configuring DHCP to prevent DNS overwrites...${NC}"
        sed -i '/supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
        echo "supersede domain-name-servers ${DNS_SERVERS[*]};" >> /etc/dhcp/dhclient.conf
        ifdown "$NETWORK_INTERFACE" 2>/dev/null && ifup "$NETWORK_INTERFACE" 2>/dev/null || \
        nmcli con down "$connection_name" 2>/dev/null && nmcli con up "$connection_name" 2>/dev/null || \
        ip link set "$NETWORK_INTERFACE" down && ip link set "$NETWORK_INTERFACE" up
    fi
    
    # Method 6: Disable NetworkManager DNS management
    if [ -d /etc/NetworkManager/conf.d ] && [ "$dns_configured" = true ]; then
        cat > /etc/NetworkManager/conf.d/90-dns-none.conf <<EOL
[main]
dns=none
rc-manager=resolvconf
EOL
        systemctl restart NetworkManager 2>/dev/null || true
    fi
    
    CURRENT_DNS="${DNS_SERVERS[*]}"
    save_config
    
    # Verify DNS configuration
    echo -e "${YELLOW}Verifying DNS configuration...${NC}"
    sleep 3
    local current_dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    echo -e "${GREEN}Current DNS in resolv.conf: $current_dns${NC}"
    
    if timeout 5 dig +short google.com @${DNS_SERVERS[0]} >/dev/null 2>&1; then
        echo -e "${GREEN}✓ DNS resolution test successful${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: DNS resolution test passed" >> "$LOG_FILE"
    else
        echo -e "${RED}✗ DNS resolution test failed${NC}"
        echo -e "${YELLOW}Trying alternative DNS server...${NC}"
        if timeout 5 dig +short google.com @${DNS_SERVERS[1]} >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Alternative DNS server works${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Alternative DNS server test passed" >> "$LOG_FILE"
        else
            echo -e "${RED}✗ All DNS servers failed${NC}"
            echo -e "${YELLOW}Attempting to fix DNS configuration...${NC}"
            chattr -i /etc/resolv.conf 2>/dev/null || true
            cat > /etc/resolv.conf <<EOL
# Generated by $SCRIPT_NAME
$(for dns in "${DNS_SERVERS[@]}"; do echo "nameserver $dns"; done)
options rotate timeout:2 attempts:3
EOL
            chattr +i /etc/resolv.conf 2>/dev/null || true
            if timeout 5 dig +short google.com @${DNS_SERVERS[0]} >/dev/null 2>&1; then
                echo -e "${GREEN}✓ DNS resolution test successful after fix${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: DNS resolution fixed" >> "$LOG_FILE"
            else
                echo -e "${RED}✗ DNS resolution still failing${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: DNS resolution fix failed" >> "$LOG_FILE"
            fi
        fi
    fi
    
    if [ "$dns_configured" = true ]; then
        echo -e "${GREEN}DNS configuration completed successfully!${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: DNS configuration completed" >> "$LOG_FILE"
    else
        echo -e "${RED}Failed to configure DNS properly!${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to configure DNS" >> "$LOG_FILE"
    fi
}

# Install BBR
install_bbr() {
    local kernel_version=$(uname -r | cut -d. -f1-2)
    if (( $(echo "$kernel_version < 4.9" | bc -l) )); then
        echo -e "${RED}Kernel version $kernel_version does not support BBR! Minimum required: 4.9${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Kernel version $kernel_version does not support BBR" >> "$LOG_FILE"
        return 1
    fi
    
    echo -e "${YELLOW}Installing and configuring BBR...${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing BBR" >> "$LOG_FILE"
    
    cat >> /etc/sysctl.conf <<EOL
# BBR Optimization - Added by $SCRIPT_NAME
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.ip_local_port_range=1024 65000
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
EOL
    
    if sysctl -p >/dev/null 2>&1; then
        echo -e "${GREEN}Sysctl settings applied successfully${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Sysctl settings applied" >> "$LOG_FILE"
    else
        echo -e "${RED}Failed to apply some sysctl settings${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to apply sysctl settings" >> "$LOG_FILE"
    fi
    
    configure_mtu 1420
    DNS_SERVERS=("1.1.1.1" "1.0.0.1")
    update_dns
    
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}✓ BBR successfully installed and configured${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: BBR installed and configured" >> "$LOG_FILE"
        return 0
    else
        echo -e "${RED}✗ Failed to enable BBR! Current: $current_cc${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to enable BBR, current: $current_cc" >> "$LOG_FILE"
        return 1
    fi
}

# Firewall Management
manage_firewall() {
    echo -e "\n${YELLOW}Firewall Management${NC}"
    echo -e "1) Enable Firewall"
    echo -e "2) Disable Firewall"
    echo -e "3) Open Port"
    echo -e "4) Close Port"
    echo -e "5) List Open Ports"
    echo -e "6) Back to Main Menu"
    
    read -p "Enter your choice [1-6]: " fw_choice
    
    case $fw_choice in
        1)
            if command -v ufw >/dev/null 2>&1; then
                ufw --force enable
                echo -e "${GREEN}UFW firewall has been enabled${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: UFW firewall enabled" >> "$LOG_FILE"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                systemctl start firewalld
                systemctl enable firewalld
                echo -e "${GREEN}Firewalld has been enabled${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Firewalld enabled" >> "$LOG_FILE"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: No supported firewall detected" >> "$LOG_FILE"
            fi
            ;;
        2)
            if command -v ufw >/dev/null 2>&1; then
                ufw disable
                echo -e "${GREEN}UFW firewall has been disabled${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: UFW firewall disabled" >> "$LOG_FILE"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                systemctl stop firewalld
                systemctl disable firewalld
                echo -e "${GREEN}Firewalld has been disabled${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Firewalld disabled" >> "$LOG_FILE"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: No supported firewall detected" >> "$LOG_FILE"
            fi
            ;;
        3)
            read -p "Enter port number to open (e.g., 22): " port
            read -p "Enter protocol (tcp/udp, default is tcp): " protocol
            protocol=${protocol:-tcp}
            
            if [[ ! "$port" =~ ^[0-9]+$ || $port -lt 1 || $port -gt 65535 ]]; then
                echo -e "${RED}Invalid port number!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid port number $port" >> "$LOG_FILE"
            elif [[ ! "$protocol" =~ ^(tcp|udp)$ ]]; then
                echo -e "${RED}Invalid protocol!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid protocol $protocol" >> "$LOG_FILE"
            else
                if command -v ufw >/dev/null 2>&1; then
                    ufw allow "$port/$protocol"
                    echo -e "${GREEN}Port $port/$protocol opened${NC}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Port $port/$protocol opened via ufw" >> "$LOG_FILE"
                elif command -v firewall-cmd >/dev/null 2>&1; then
                    firewall-cmd --permanent --add-port="$port/$protocol"
                    firewall-cmd --reload
                    echo -e "${GREEN}Port $port/$protocol opened${NC}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Port $port/$protocol opened via firewalld" >> "$LOG_FILE"
                else
                    iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT
                    echo -e "${GREEN}Port $port/$protocol opened via iptables${NC}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Port $port/$protocol opened via iptables" >> "$LOG_FILE"
                fi
            fi
            ;;
        4)
            read -p "Enter port number to close (e.g., 22): " port
            read -p "Enter protocol (tcp/udp, default is tcp): " protocol
            protocol=${protocol:-tcp}
            
            if [[ ! "$port" =~ ^[0-9]+$ || $port -lt 1 || $port -gt 65535 ]]; then
                echo -e "${RED}Invalid port number!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid port number $port" >> "$LOG_FILE"
            elif [[ ! "$protocol" =~ ^(tcp|udp)$ ]]; then
                echo -e "${RED}Invalid protocol!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid protocol $protocol" >> "$LOG_FILE"
            else
                if command -v ufw >/dev/null 2>&1; then
                    ufw delete allow "$port/$protocol"
                    echo -e "${GREEN}Port $port/$protocol closed${NC}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Port $port/$protocol closed via ufw" >> "$LOG_FILE"
                elif command -v firewall-cmd >/dev/null 2>&1; then
                    firewall-cmd --permanent --remove-port="$port/$protocol"
                    firewall-cmd --reload
                    echo -e "${GREEN}Port $port/$protocol closed${NC}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Port $port/$protocol closed via firewalld" >> "$LOG_FILE"
                else
                    iptables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null
                    echo -e "${GREEN}Port $port/$protocol closed via iptables${NC}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Port $port/$protocol closed via iptables" >> "$LOG_FILE"
                fi
            fi
            ;;
        5)
            if command -v ufw >/dev/null 2>&1; then
                ufw status verbose
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Info: Listed open ports via ufw" >> "$LOG_FILE"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --list-ports
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Info: Listed open ports via firewalld" >> "$LOG_FILE"
            else
                iptables -L INPUT -n --line-numbers | grep ACCEPT
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Info: Listed open ports via iptables" >> "$LOG_FILE"
            fi
            ;;
        6)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid firewall management option $fw_choice" >> "$LOG_FILE"
            ;;
    esac
    
    read -p "Press [Enter] to continue..."
    manage_firewall
}

# ICMP Ping Management
manage_icmp() {
    echo -e "\n${YELLOW}ICMP Ping Management${NC}"
    echo -e "1) Block ICMP Ping"
    echo -e "2) Allow ICMP Ping"
    echo -e "3) Back to Main Menu"
    
    read -p "Enter your choice [1-3]: " icmp_choice
    
    case $icmp_choice in
        1)
            iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
            echo -e "${GREEN}ICMP Ping blocked${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: ICMP Ping blocked" >> "$LOG_FILE"
            ;;
        2)
            iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
            echo -e "${GREEN}ICMP Ping allowed${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: ICMP Ping allowed" >> "$LOG_FILE"
            ;;
        3)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid ICMP option $icmp_choice" >> "$LOG_FILE"
            ;;
    esac
    
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
    
    read -p "Press [Enter] to continue..."
    manage_icmp
}

# IPv6 Management
manage_ipv6() {
    echo -e "\n${YELLOW}IPv6 Management${NC}"
    echo -e "1) Disable IPv6"
    echo -e "2) Enable IPv6"
    echo -e "3) Back to Main Menu"
    
    read -p "Enter your choice [1-3]: " ipv6_choice
    
    case $ipv6_choice in
        1)
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
            echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
            echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
            echo -e "${GREEN}IPv6 disabled${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: IPv6 disabled" >> "$LOG_FILE"
            ;;
        2)
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
            sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
            echo -e "${GREEN}IPv6 enabled${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: IPv6 enabled" >> "$LOG_FILE"
            ;;
        3)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid IPv6 option $ipv6_choice" >> "$LOG_FILE"
            ;;
    esac
    
    read -p "Press [Enter] to continue..."
    manage_ipv6
}

# IPTable Tunnel Setup
manage_tunnel() {
    echo -e "\n${YELLOW}IPTable Tunnel Setup${NC}"
    echo -e "1) Route Iranian IPs directly"
    echo -e "2) Route Foreign IPs via VPN/Gateway"
    echo -e "3) Reset IPTable Rules"
    echo -e "4) Back to Main Menu"
    
    read -p "Enter your choice [1-4]: " tunnel_choice
    
    case $tunnel_choice in
        1)
            read -p "Enter Iran IP/CIDR (e.g., 192.168.1.0/24): " iran_ip
            if [[ "$iran_ip" =~ ^[0-9./]+$ ]]; then
                iptables -t nat -A POSTROUTING -d "$iran_ip" -j ACCEPT
                echo -e "${GREEN}Route added for $iran_ip${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Route added for $iran_ip" >> "$LOG_FILE"
            else
                echo -e "${RED}Invalid IP/CIDR!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid IP/CIDR $iran_ip" >> "$LOG_FILE"
            fi
            ;;
        2)
            read -p "Enter Foreign IP/CIDR (e.g., 1.1.1.1/32): " foreign_ip
            read -p "Enter Gateway IP (e.g., 10.8.0.1): " gateway_ip
            if [[ "$foreign_ip" =~ ^[0-9./]+$ && "$gateway_ip" =~ ^[0-9.]+$ ]]; then
                ip route add "$foreign_ip" via "$gateway_ip" 2>/dev/null && \
                echo -e "${GREEN}Route added: $foreign_ip via $gateway_ip${NC}" || \
                echo -e "${RED}Failed to add route!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Info: Route add attempt for $foreign_ip via $gateway_ip" >> "$LOG_FILE"
            else
                echo -e "${RED}Invalid IP/CIDR or Gateway!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid IP/CIDR $foreign_ip or Gateway $gateway_ip" >> "$LOG_FILE"
            fi
            ;;
        3)
            iptables -t nat -F
            echo -e "${GREEN}IPTables rules reset${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: IPTables rules reset" >> "$LOG_FILE"
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid tunnel option $tunnel_choice" >> "$LOG_FILE"
            ;;
    esac
    
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
    
    read -p "Press [Enter] to continue..."
    manage_tunnel
}

# Reset Network Settings
reset_network() {
    echo -e "${YELLOW}Resetting network settings...${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Resetting network settings" >> "$LOG_FILE"
    
    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>/dev/null
    echo "1500" > "/sys/class/net/$NETWORK_INTERFACE/mtu" 2>/dev/null
    CURRENT_MTU=1500
    
    local connection_name=""
    if command -v nmcli >/dev/null 2>&1; then
        connection_name=$(nmcli -t -f DEVICE,NAME con show | grep "^$NETWORK_INTERFACE:" | cut -d: -f2 | head -n1)
        if [ -n "$connection_name" ]; then
            nmcli con mod "$connection_name" ipv4.ignore-auto-dns no
            nmcli con mod "$connection_name" ipv6.ignore-auto-dns no
            nmcli con mod "$connection_name" ipv4.dns ""
            nmcli con mod "$connection_name" ipv6.dns ""
            nmcli con down "$connection_name" 2>/dev/null
            nmcli con up "$connection_name" 2>/dev/null
        fi
    fi
    
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        cat > /etc/systemd/resolved.conf <<EOL
[Resolve]
#DNS=
#Domains=
#DNSOverTLS=no
#DNSSEC=no
Cache=yes
DNSStubListener=yes
EOL
        systemctl restart systemd-resolved
        resolvectl flush-caches
    fi
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<EOL
# Generated by $SCRIPT_NAME
nameserver 1.1.1.1
nameserver 1.0.0.1
options rotate
EOL
    
    rm -f /etc/NetworkManager/conf.d/90-dns-none.conf 2>/dev/null
    systemctl restart NetworkManager 2>/dev/null || true
    
    if [ -f /etc/dhcp/dhclient.conf ]; then
        sed -i '/supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
    fi
    
    CURRENT_DNS="1.1.1.1 1.0.0.1"
    save_config
    
    echo -e "${GREEN}Network settings reset to default!${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: Network settings reset" >> "$LOG_FILE"
}

# Reset ALL Changes
reset_all() {
    echo -e "${YELLOW}Resetting ALL changes...${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Resetting all changes" >> "$LOG_FILE"
    
    reset_network
    
    iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
    
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
    
    iptables -t nat -F
    iptables -F
    
    sed -i '/# BBR Optimization/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc=fq/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_syncookies/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_tw_reuse/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fin_timeout/d' /etc/sysctl.conf
    sed -i '/net.ipv4.ip_local_port_range/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_syn_backlog/d' /etc/sysctl.conf
    sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
    sed -i '/net.core.netdev_max_backlog/d' /etc/sysctl.conf
    sed -i '/net.ipv4 tcp_slow_start_after_idle/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_mtu_probing/d' /etc/sysctl.conf
    
    sysctl -p >/dev/null 2>&1
    
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
    
    rm -f "$CONFIG_FILE" 2>/dev/null
    
    echo -e "${GREEN}All changes have been completely reset!${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Success: All changes reset" >> "$LOG_FILE"
}

# Reboot System
reboot_system() {
    echo -e "${YELLOW}Are you sure you want to reboot the system now? (y/n)${NC}"
    read -p "Enter your choice: " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Rebooting system...${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] System reboot initiated" >> "$LOG_FILE"
        reboot
    else
        echo -e "${YELLOW}Reboot cancelled.${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reboot cancelled" >> "$LOG_FILE"
    fi
}

# Main Menu
show_menu() {
    load_config
    while true; do
        show_header
        echo -e "${BOLD}Main Menu:${NC}"
        echo -e "1) Install BBR Optimization"
        echo -e "2) Configure MTU"
        echo -e "3) Configure DNS"
        echo -e "4) Firewall Management"
        echo -e "5) Reset Network Settings"
        echo -e "6) Manage ICMP Ping"
        echo -e "7) Manage IPv6"
        echo -e "8) Setup IPTable Tunnel"
        echo -e "9) Ping MTU Size Test"
        echo -e "10) Reset ALL Changes"
        echo -e "11) Reboot System"
        echo -e "12) Exit"
        
        read -p "Enter your choice [1-12]: " choice
        
        case $choice in
            1)
                install_bbr
                ;;
            2)
                echo -e "\nCurrent MTU: $CURRENT_MTU"
                read -p "Enter new MTU value (recommended 1420): " new_mtu
                if [[ "$new_mtu" =~ ^[0-9]+$ ]]; then
                    configure_mtu "$new_mtu"
                else
                    echo -e "${RED}Invalid MTU value!${NC}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid MTU value $new_mtu" >> "$LOG_FILE"
                fi
                ;;
            3)
                echo -e "\nCurrent DNS: $CURRENT_DNS"
                read -p "Enter new DNS servers (space separated, default 1.1.1.1): " new_dns
                DNS_SERVERS=(${new_dns:-1.1.1.1})
                update_dns
                ;;
            4)
                manage_firewall
                ;;
            5)
                reset_network
                ;;
            6)
                manage_icmp
                ;;
            7)
                manage_ipv6
                ;;
            8)
                manage_tunnel
                ;;
            9)
                ping_mtu
                ;;
            10)
                reset_all
                ;;
            11)
                reboot_system
                ;;
            12)
                echo -e "${GREEN}Exiting...${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Script exited" >> "$LOG_FILE"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid menu option $choice" >> "$LOG_FILE"
                ;;
        esac
        
        read -p "Press [Enter] to continue..."
    done
}

# Main Execution
check_root
check_dependencies
if [ -z "$NETWORK_INTERFACE" ]; then
    echo -e "${RED}No default network interface detected! Please check your network configuration.${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: No default network interface detected" >> "$LOG_FILE"
    exit 1
fi
show_menu
