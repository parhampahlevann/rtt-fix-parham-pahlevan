#!/bin/bash

# Global Configuration
SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="8.3"
AUTHOR="Parham Pahleven"
CONFIG_FILE="/etc/network_optimizer.conf"
LOG_FILE="/var/log/network_optimizer.log"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
DEFAULT_MTU=1500
CURRENT_MTU=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo $DEFAULT_MTU)
DNS_SERVERS=("1.1.1.1")
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
    local deps=("iproute2" "net-tools" "iptables" "bc" "resolvconf" "network-manager")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "${dep%% *}" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}Installing missing dependencies: ${missing_deps[*]}${NC}"
        apt-get update && apt-get install -y "${missing_deps[@]}" || {
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
EOL
}

# Load Configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        CURRENT_MTU=$MTU
        DNS_SERVERS=(${DNS_SERVERS[@]})
    fi
}

# Header Display
show_header() {
    clear
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════╗"
    echo -e "║   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}         ║"
    echo -e "╚════════════════════════════════════════════════╝${NC}"
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

# Universal MTU Configuration
configure_mtu() {
    local new_mtu=$1
    local old_mtu=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo $DEFAULT_MTU)

    if [[ ! "$new_mtu" =~ ^[0-9]+$ || $new_mtu -lt 68 || $new_mtu -gt 9000 ]]; then
        echo -e "${RED}Invalid MTU value! Must be between 68 and 9000.${NC}"
        return 1
    fi

    # Set temporary MTU
    if ! ip link set dev "$NETWORK_INTERFACE" mtu "$new_mtu" 2>/dev/null; then
        echo -e "${RED}Failed to set temporary MTU!${NC}"
        return 1
    fi

    # Test connectivity
    if ! _test_connectivity; then
        echo -e "${RED}Connectivity test failed! Rolling back MTU...${NC}"
        ip link set dev "$NETWORK_INTERFACE" mtu "$old_mtu" 2>/dev/null
        return 1
    fi

    # Apply permanent configuration
    if [[ -d /etc/netplan ]]; then
        local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -f "$netplan_file" ]; then
            sed -i "/$NETWORK_INTERFACE:/,/^[^[:space:]]/ s/mtu: .*/mtu: $new_mtu/" "$netplan_file" || \
                sed -i "/$NETWORK_INTERFACE:/a\      mtu: $new_mtu" "$netplan_file"
            netplan apply >/dev/null 2>&1 || echo -e "${RED}Failed to apply netplan!${NC}"
        fi
    elif [[ -f /etc/network/interfaces ]]; then
        grep -q "iface $NETWORK_INTERFACE" /etc/network/interfaces && \
            sed -i "/iface $NETWORK_INTERFACE/,/^$/ s/mtu .*/mtu $new_mtu/" /etc/network/interfaces || \
            echo "mtu $new_mtu" >> /etc/network/interfaces
        systemctl restart networking >/dev/null 2>&1 || echo -e "${RED}Failed to restart networking!${NC}"
    elif command -v nmcli >/dev/null 2>&1; then
        nmcli con mod "$NETWORK_INTERFACE" ipv4.mtu "$new_mtu" ipv6.mtu "$new_mtu" 2>/dev/null
        nmcli con up "$NETWORK_INTERFACE" >/dev/null 2>&1 || echo -e "${RED}Failed to apply NetworkManager settings!${NC}"
    fi

    CURRENT_MTU=$new_mtu
    save_config
    echo -e "${GREEN}MTU successfully set to $new_mtu${NC}"
    return 0
}

# Update DNS Configuration
update_dns() {
    local dns_configured=false

    # Check if NetworkManager is active
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring DNS via NetworkManager...${NC}"
        nmcli con mod "$NETWORK_INTERFACE" ipv4.dns "${DNS_SERVERS[*]}" 2>/dev/null
        nmcli con mod "$NETWORK_INTERFACE" ipv4.ignore-auto-dns yes 2>/dev/null
        nmcli con up "$NETWORK_INTERFACE" >/dev/null 2>&1 || {
            echo -e "${RED}Failed to apply NetworkManager DNS settings!${NC}"
        }
        dns_configured=true
        echo -e "${GREEN}DNS servers set via NetworkManager: ${DNS_SERVERS[*]}${NC}"
    fi

    # Check if systemd-resolved is active
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring DNS via systemd-resolved...${NC}"
        for dns in "${DNS_SERVERS[@]}"; do
            resolvectl set-dns "$NETWORK_INTERFACE" "$dns" 2>/dev/null || {
                echo -e "${YELLOW}Warning: Failed to set DNS $dns via resolvectl${NC}"
            }
        done
        resolvectl set-domain "$NETWORK_INTERFACE" "~." 2>/dev/null
        resolvectl flush-caches >/dev/null 2>&1
        dns_configured=true
        echo -e "${GREEN}DNS servers set via systemd-resolved: ${DNS_SERVERS[*]}${NC}"

        # Ensure systemd-resolved writes to resolv.conf
        if [ -f /etc/systemd/resolved.conf ]; then
            sed -i '/^DNS=/d' /etc/systemd/resolved.conf
            echo "DNS=${DNS_SERVERS[*]}" >> /etc/systemd/resolved.conf
            systemctl restart systemd-resolved >/dev/null 2>&1
        fi
    fi

    # Fallback to resolv.conf for older systems or if above methods fail
    if [ "$dns_configured" = false ]; then
        echo -e "${YELLOW}Configuring DNS via /etc/resolv.conf...${NC}"
        chattr -i /etc/resolv.conf 2>/dev/null
        echo "# Generated by $SCRIPT_NAME" > /etc/resolv.conf
        for dns in "${DNS_SERVERS[@]}"; do
            echo "nameserver $dns" >> /etc/resolv.conf
        done
        # Prevent DHCP from overwriting resolv.conf
        if command -v resolvconf >/dev/null 2>&1; then
            echo "nameserver ${DNS_SERVERS[*]}" > /etc/resolvconf/resolv.conf.d/base
            resolvconf -u >/dev/null 2>&1
        fi
        chattr +i /etc/resolv.conf 2>/dev/null || echo -e "${YELLOW}Warning: Could not make resolv.conf immutable${NC}"
    fi

    # Prevent DHCP from overwriting DNS
    if [ -f /etc/dhcp/dhclient.conf ]; then
        grep -q "supersede domain-name-servers" /etc/dhcp/dhclient.conf || \
            echo "supersede domain-name-servers ${DNS_SERVERS[*]};" >> /etc/dhcp/dhclient.conf
    fi

    CURRENT_DNS="${DNS_SERVERS[*]}"
    save_config
    echo -e "${GREEN}DNS servers updated successfully and made persistent${NC}"
}

# Install BBR
install_bbr() {
    # Check kernel version
    local kernel_version=$(uname -r | cut -d. -f1-2)
    if (( $(echo "$kernel_version < 4.9" | bc -l) )); then
        echo -e "${RED}Kernel version $kernel_version does not support BBR! Minimum required: 4.9${NC}"
        return 1
    fi

    # Apply BBR settings
    cat >> /etc/sysctl.conf <<EOL

# BBR Optimization
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

    sysctl -p >/dev/null 2>&1 || echo -e "${RED}Failed to apply sysctl settings!${NC}"

    # Set default MTU and DNS
    configure_mtu 1420
    DNS_SERVERS=("1.1.1.1")
    update_dns

    # Verify BBR
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR successfully installed and configured${NC}"
        return 0
    else
        echo -e "${RED}Failed to enable BBR! Current: $current_cc${NC}"
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
                ufw enable
                echo -e "${GREEN}UFW firewall has been enabled${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                systemctl start firewalld
                systemctl enable firewalld
                echo -e "${GREEN}Firewalld has been enabled${NC}"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
            fi
            ;;
        2)
            if command -v ufw >/dev/null 2>&1; then
                ufw disable
                echo -e "${GREEN}UFW firewall has been disabled${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                systemctl stop firewalld
                systemctl disable firewalld
                echo -e "${GREEN}Firewalld has been disabled${NC}"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
            fi
            ;;
        3)
            read -p "Enter port number to open (e.g., 22): " port
            read -p "Enter protocol (tcp/udp, default is tcp): " protocol
            protocol=${protocol:-tcp}
            
            if command -v ufw >/dev/null 2>&1; then
                ufw allow "$port/$protocol"
                echo -e "${GREEN}Port $port/$protocol has been opened in UFW${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --add-port="$port/$protocol"
                firewall-cmd --reload
                echo -e "${GREEN}Port $port/$protocol has been opened in firewalld${NC}"
            else
                iptables -A INPUT -p "#!/bin/bash

# Global Configuration
SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="8.3"
AUTHOR="Parham Pahleven"
CONFIG_FILE="/etc/network_optimizer.conf"
LOG_FILE="/var/log/network_optimizer.log"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
DEFAULT_MTU=1500
CURRENT_MTU=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo $DEFAULT_MTU)
DNS_SERVERS=("1.1.1.1")
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
    local deps=("iproute2" "net-tools" "iptables" "bc" "resolvconf" "network-manager")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "${dep%% *}" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}Installing missing dependencies: ${missing_deps[*]}${NC}"
        apt-get update && apt-get install -y "${missing_deps[@]}" || {
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
EOL
}

# Load Configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        CURRENT_MTU=$MTU
        DNS_SERVERS=(${DNS_SERVERS[@]})
    fi
}

# Header Display
show_header() {
    clear
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════╗"
    echo -e "║   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}         ║"
    echo -e "╚════════════════════════════════════════════════╝${NC}"
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

# Universal MTU Configuration
configure_mtu() {
    local new_mtu=$1
    local old_mtu=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo $DEFAULT_MTU)

    if [[ ! "$new_mtu" =~ ^[0-9]+$ || $new_mtu -lt 68 || $new_mtu -gt 9000 ]]; then
        echo -e "${RED}Invalid MTU value! Must be between 68 and 9000.${NC}"
        return 1
    fi

    # Set temporary MTU
    if ! ip link set dev "$NETWORK_INTERFACE" mtu "$new_mtu" 2>/dev/null; then
        echo -e "${RED}Failed to set temporary MTU!${NC}"
        return 1
    fi

    # Test connectivity
    if ! _test_connectivity; then
        echo -e "${RED}Connectivity test failed! Rolling back MTU...${NC}"
        ip link set dev "$NETWORK_INTERFACE" mtu "$old_mtu" 2>/dev/null
        return 1
    fi

    # Apply permanent configuration
    if [[ -d /etc/netplan ]]; then
        local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -f "$netplan_file" ]; then
            sed -i "/$NETWORK_INTERFACE:/,/^[^[:space:]]/ s/mtu: .*/mtu: $new_mtu/" "$netplan_file" || \
                sed -i "/$NETWORK_INTERFACE:/a\      mtu: $new_mtu" "$netplan_file"
            netplan apply >/dev/null 2>&1 || echo -e "${RED}Failed to apply netplan!${NC}"
        fi
    elif [[ -f /etc/network/interfaces ]]; then
        grep -q "iface $NETWORK_INTERFACE" /etc/network/interfaces && \
            sed -i "/iface $NETWORK_INTERFACE/,/^$/ s/mtu .*/mtu $new_mtu/" /etc/network/interfaces || \
            echo "mtu $new_mtu" >> /etc/network/interfaces
        systemctl restart networking >/dev/null 2>&1 || echo -e "${RED}Failed to restart networking!${NC}"
    elif command -v nmcli >/dev/null 2>&1; then
        nmcli con mod "$NETWORK_INTERFACE" ipv4.mtu "$new_mtu" ipv6.mtu "$new_mtu" 2>/dev/null
        nmcli con up "$NETWORK_INTERFACE" >/dev/null 2>&1 || echo -e "${RED}Failed to apply NetworkManager settings!${NC}"
    fi

    CURRENT_MTU=$new_mtu
    save_config
    echo -e "${GREEN}MTU successfully set to $new_mtu${NC}"
    return 0
}

# Update DNS Configuration
update_dns() {
    local dns_configured=false

    # Check if NetworkManager is active
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring DNS via NetworkManager...${NC}"
        nmcli con mod "$NETWORK_INTERFACE" ipv4.dns "${DNS_SERVERS[*]}" 2>/dev/null
        nmcli con mod "$NETWORK_INTERFACE" ipv4.ignore-auto-dns yes 2>/dev/null
        nmcli con up "$NETWORK_INTERFACE" >/dev/null 2>&1 || {
            echo -e "${RED}Failed to apply NetworkManager DNS settings!${NC}"
        }
        dns_configured=true
        echo -e "${GREEN}DNS servers set via NetworkManager: ${DNS_SERVERS[*]}${NC}"
    fi

    # Check if systemd-resolved is active
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring DNS via systemd-resolved...${NC}"
        for dns in "${DNS_SERVERS[@]}"; do
            resolvectl set-dns "$NETWORK_INTERFACE" "$dns" 2>/dev/null || {
                echo -e "${YELLOW}Warning: Failed to set DNS $dns via resolvectl${NC}"
            }
        done
        resolvectl set-domain "$NETWORK_INTERFACE" "~." 2>/dev/null
        resolvectl flush-caches >/dev/null 2>&1
        dns_configured=true
        echo -e "${GREEN}DNS servers set via systemd-resolved: ${DNS_SERVERS[*]}${NC}"

        # Ensure systemd-resolved writes to resolv.conf
        if [ -f /etc/systemd/resolved.conf ]; then
            sed -i '/^DNS=/d' /etc/systemd/resolved.conf
            echo "DNS=${DNS_SERVERS[*]}" >> /etc/systemd/resolved.conf
            systemctl restart systemd-resolved >/dev/null 2>&1
        fi
    fi

    # Fallback to resolv.conf for older systems or if above methods fail
    if [ "$dns_configured" = false ]; then
        echo -e "${YELLOW}Configuring DNS via /etc/resolv.conf...${NC}"
        chattr -i /etc/resolv.conf 2>/dev/null
        echo "# Generated by $SCRIPT_NAME" > /etc/resolv.conf
        for dns in "${DNS_SERVERS[@]}"; do
            echo "nameserver $dns" >> /etc/resolv.conf
        done
        # Prevent DHCP from overwriting resolv.conf
        if command -v resolvconf >/dev/null 2>&1; then
            echo "nameserver ${DNS_SERVERS[*]}" > /etc/resolvconf/resolv.conf.d/base
            resolvconf -u >/dev/null 2>&1
        fi
        chattr +i /etc/resolv.conf 2>/dev/null || echo -e "${YELLOW}Warning: Could not make resolv.conf immutable${NC}"
    fi

    # Prevent DHCP from overwriting DNS
    if [ -f /etc/dhcp/dhclient.conf ]; then
        grep -q "supersede domain-name-servers" /etc/dhcp/dhclient.conf || \
            echo "supersede domain-name-servers ${DNS_SERVERS[*]};" >> /etc/dhcp/dhclient.conf
    fi

    CURRENT_DNS="${DNS_SERVERS[*]}"
    save_config
    echo -e "${GREEN}DNS servers updated successfully and made persistent${NC}"
}

# Install BBR
install_bbr() {
    # Check kernel version
    local kernel_version=$(uname -r | cut -d. -f1-2)
    if (( $(echo "$kernel_version < 4.9" | bc -l) )); then
        echo -e "${RED}Kernel version $kernel_version does not support BBR! Minimum required: 4.9${NC}"
        return 1
    fi

    # Apply BBR settings
    cat >> /etc/sysctl.conf <<EOL

# BBR Optimization
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

    sysctl -p >/dev/null 2>&1 || echo -e "${RED}Failed to apply sysctl settings!${NC}"

    # Set default MTU and DNS
    configure_mtu 1420
    DNS_SERVERS=("1.1.1.1")
    update_dns

    # Verify BBR
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR successfully installed and configured${NC}"
        return 0
    else
        echo -e "${RED}Failed to enable BBR! Current: $current_cc${NC}"
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
                ufw enable
                echo -e "${GREEN}UFW firewall has been enabled${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                systemctl start firewalld
                systemctl enable firewalld
                echo -e "${GREEN}Firewalld has been enabled${NC}"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
            fi
            ;;
        2)
            if command -v ufw >/dev/null 2>&1; then
                ufw disable
                echo -e "${GREEN}UFW firewall has been disabled${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                systemctl stop firewalld
                systemctl disable firewalld
                echo -e "${GREEN}Firewalld has been disabled${NC}"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
            fi
            ;;
        3)
            read -p "Enter port number to open (e.g., 22): " port
            read -p "Enter protocol (tcp/udp, default is tcp): " protocol
            protocol=${protocol:-tcp}
            
            if command -v ufw >/dev/null 2>&1; then
                ufw allow "$port/$protocol"
                echo -e "${GREEN}Port $port/$protocol has been opened in UFW${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --add-port="$port/$protocol"
                firewall-cmd --reload
                echo -e "${GREEN}Port $port/$protocol has been opened in firewalld${NC}"
            else
                iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT
                echo -e "${GREEN}Port $port/$protocol has been opened in iptables${NC}"
            fi
            ;;
        4)
            read -p "Enter port number to close (e.g., 22): " port
            read -p "Enter protocol (tcp/udp, default is tcp): " protocol
            protocol=${protocol:-tcp}
            
            if command -v ufw >/dev/null 2>&1; then
                ufw deny "$port/$protocol"
                echo -e "${GREEN}Port $port/$protocol has been closed in UFW${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --remove-port="$port/$protocol"
                firewall-cmd --reload
                echo -e "${GREEN}Port $port/$protocol has been closed in firewalld${NC}"
            else
                iptables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null
                echo -e "${GREEN}Port $port/$protocol has been closed in iptables${NC}"
            fi
            ;;
        5)
            if command -v ufw >/dev/null 2>&1; then
                echo -e "\n${YELLOW}UFW Open Ports:${NC}"
                ufw status verbose
            elif command -v firewall-cmd >/dev/null 2>&1; then
                echo -e "\n${YELLOW}Firewalld Open Ports:${NC}"
                firewall-cmd --list-ports
            else
                echo -e "\n${YELLOW}iptables Open Ports:${NC}"
                iptables -L INPUT -n --line-numbers | grep ACCEPT
            fi
            ;;
        6)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            ;;
    esac
    
    read -p "Press [Enter] to continue..."
    manage_firewall
}

# ICMP Ping Management
manage_icmp() {
    echo -e "\n${YELLOW}ICMP Ping Management${NC}"
    echo -e "1) Block ICMP Ping (Disable Ping)"
    echo -e "2) Allow ICMP Ping (Enable Ping)"
    echo -e "3) Back to Main Menu"
    
    read -p "Enter your choice [1-3]: " icmp_choice
    
    case $icmp_choice in
        1)
            iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
            echo -e "${GREEN}ICMP Ping is now BLOCKED!${NC}"
            ;;
        2)
            iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
            echo -e "${GREEN}ICMP Ping is now ALLOWED!${NC}"
            ;;
        3)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            ;;
    esac
    
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
            echo -e "${GREEN}IPv6 has been DISABLED!${NC}"
            ;;
        2)
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
            sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
            echo -e "${GREEN}IPv6 has been ENABLED!${NC}"
            ;;
        3)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
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
            read -p "Enter Iran IP/CIDR (e.g., 192.168.1.0/24 or 1.1.1.1): " iran_ip
            iptables -t nat -A POSTROUTING -d "$iran_ip" -j ACCEPT
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            echo -e "${GREEN}Iran IP ($iran_ip) is now routed directly!${NC}"
            ;;
        2)
            read -p "Enter Foreign IP/CIDR (e.g., 1.1.1.1/32): " foreign_ip
            read -p "Enter Gateway/VPN IP (e.g., 10.8.0.1): " gateway_ip
            ip route add "$foreign_ip" via "$gateway_ip" 2>/dev/null || \
                echo -e "${RED}Failed to add route!${NC}"
            echo -e "${GREEN}Foreign IP ($foreign_ip) is now routed via $gateway_ip!${NC}"
            ;;
        3)
            iptables -t nat -F
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            echo -e "${GREEN}IPTable rules have been reset!${NC}"
            ;;
        4)
            return
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            ;;
    esac
    
    read -p "Press [Enter] to continue..."
    manage_tunnel
}

# Reset Network Settings
reset_network() {
    # Reset MTU
    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>/dev/null
    CURRENT_MTU=1500

    # Reset DNS
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
        nmcli con mod "$NETWORK_INTERFACE" ipv4.dns "1.1.1.1" 2>/dev/null
        nmcli con mod "$NETWORK_INTERFACE" ipv4.ignore-auto-dns no 2>/dev/null
        nmcli con up "$NETWORK_INTERFACE" >/dev/null 2>&1
    elif systemctl is-active systemd-resolved >/dev/null 2>&1; then
        resolvectl set-dns "$NETWORK_INTERFACE" 1.1.1.1 2>/dev/null
        resolvectl flush-caches >/dev/null 2>&1
        if [ -f /etc/systemd/resolved.conf ]; then
            sed -i '/^DNS=/d' /etc/systemd/resolved.conf
            echo "DNS=1.1.1.1" >> /etc/systemd/resolved.conf
            systemctl restart systemd-resolved >/dev/null 2>&1
        fi
    else
        chattr -i /etc/resolv.conf 2>/dev/null
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        if command -v resolvconf >/dev/null 2>&1; then
            echo "nameserver 1.1.1.1" > /etc/resolvconf/resolv.conf.d/base
            resolvconf -u >/dev/null 2>&1
        fi
    fi

    # Reset DHCP DNS settings
    if [ -f /etc/dhcp/dhclient.conf ]; then
        sed -i '/supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
    fi

    CURRENT_DNS="1.1.1.1"

    # Apply changes
    if [[ -d /etc/netplan ]]; then
        local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        [ -f "$netplan_file" ] && sed -i "/mtu:/d" "$netplan_file" && netplan apply
    elif [[ -f /etc/network/interfaces ]]; then
        sed -i "/mtu/d" /etc/network/interfaces
        systemctl restart networking >/dev/null 2>&1
    elif command -v nmcli >/dev/null 2>&1; then
        nmcli con mod "$NETWORK_INTERFACE" ipv4.mtu 1500 ipv6.mtu 1500 2>/dev/null
        nmcli con up "$NETWORK_INTERFACE" >/dev/null 2>&1
    fi

    echo -e "${GREEN}Network settings have been reset!${NC}"
}

# Reset ALL Changes
reset_all() {
    reset_network

    # Reset ICMP
    iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null

    # Reset IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf

    # Reset IPTables
    iptables -t nat -F
    iptables-save > /etc/iptables/rules.v4 2>/dev/null

    # Remove BBR
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
    sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_mtu_probing/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    # Remove config file
    rm -f "$CONFIG_FILE"

    echo -e "${GREEN}All changes have been reset to default!${NC}"
}

# Reboot System
reboot_system() {
    echo -e "${YELLOW}Are you sure you want to reboot the system now? (y/n)${NC}"
    read -p "Enter your choice: " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Rebooting system...${NC}"
        reboot
    else
        echo -e "${YELLOW}Reboot cancelled.${NC}"
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
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
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
    exit 1
fi
show_menu
