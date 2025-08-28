#!/bin/bash

# Global Configuration
SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="8.2"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/network_optimizer.conf"
LOG_FILE="/var/log/network_optimizer.log"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
DEFAULT_MTU=1420
CURRENT_MTU=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo $DEFAULT_MTU)
DNS_SERVERS=("1.1.1.1" "1.0.0.1")
CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')

# Initialize logging
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

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
    echo -e "${YELLOW}Interface: ${BOLD}$NETWORK_INTERFACE${NC}"
    echo -e "${YELLOW}Current MTU: ${BOLD}$CURRENT_MTU${NC}"
    echo -e "${YELLOW}Current DNS: ${BOLD}$CURRENT_DNS${NC}"

    # Show BBR Status
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$bbr_status" == "bbr" ]]; then
        echo -e "${YELLOW}BBR Status: ${GREEN}Enabled${NC}"
    else
        echo -e "${YELLOW}BBR Status: ${RED}Disabled${NC}"
    fi

    # Show Firewall Status
    if command -v ufw >/dev/null 2>&1; then
        local fw_status=$(ufw status | grep -o "active")
        echo -e "${YELLOW}Firewall Status: ${BOLD}$fw_status${NC}"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        local fw_status=$(firewall-cmd --state 2>&1)
        echo -e "${YELLOW}Firewall Status: ${BOLD}$fw_status${NC}"
    else
        echo -e "${YELLOW}Firewall Status: ${BOLD}Not detected${NC}"
    fi

    # Show ICMP Status
    local icmp_status=$(iptables -L INPUT -n 2>/dev/null | grep "icmp" | grep -o "DROP")
    if [ "$icmp_status" == "DROP" ]; then
        echo -e "${YELLOW}ICMP Ping: ${RED}Blocked${NC}"
    else
        echo -e "${YELLOW}ICMP Ping: ${GREEN}Allowed${NC}"
    fi

    # Show IPv6 Status
    local ipv6_status=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}')
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

# Validate IP Address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
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
    if [[ "$test_mtu" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}Testing ping with MTU=$test_mtu...${NC}"
        ping -M do -s $((test_mtu - 28)) -c 4 1.1.1.1
    else
        echo -e "${RED}Invalid MTU value!${NC}"
    fi
}

# Universal MTU Configuration
configure_mtu() {
    local new_mtu=$1
    local old_mtu=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo $DEFAULT_MTU)

    # Set temporary MTU
    if ! ip link set dev "$NETWORK_INTERFACE" mtu "$new_mtu"; then
        echo -e "${RED}Failed to set temporary MTU!${NC}"
        return 1
    fi

    # Test connectivity
    if ! _test_connectivity; then
        echo -e "${RED}Connectivity test failed! Rolling back MTU...${NC}"
        ip link set dev "$NETWORK_INTERFACE" mtu "$old_mtu"
        return 1
    fi

    # Apply permanent configuration
    if [[ -d /etc/netplan ]]; then
        local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -f "$netplan_file" ]; then
            cp "$netplan_file" "$netplan_file.backup.$(date +%Y%m%d_%H%M%S)"
            if grep -q "mtu:" "$netplan_file"; then
                sed -i "s/mtu:.*/mtu: $new_mtu/" "$netplan_file"
            else
                sed -i "/$NETWORK_INTERFACE:/a\      mtu: $new_mtu" "$netplan_file"
            fi
            netplan apply >/dev/null 2>&1
        fi
    elif [[ -f /etc/network/interfaces ]]; then
        cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)
        if grep -q "mtu" /etc/network/interfaces; then
            sed -i "s/mtu.*/mtu $new_mtu/" /etc/network/interfaces
        else
            sed -i "/iface $NETWORK_INTERFACE inet/a\    mtu $new_mtu" /etc/network/interfaces
        fi
        systemctl restart networking >/dev/null 2>&1 || true
    elif [[ -d /etc/sysconfig/network-scripts ]]; then
        local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-$NETWORK_INTERFACE"
        if [ -f "$ifcfg_file" ]; then
            cp "$ifcfg_file" "$ifcfg_file.backup.$(date +%Y%m%d_%H%M%S)"
            if grep -q "MTU=" "$ifcfg_file"; then
                sed -i "s/MTU=.*/MTU=$new_mtu/" "$ifcfg_file"
            else
                echo "MTU=$new_mtu" >> "$ifcfg_file"
            fi
            systemctl restart network >/dev/null 2>&1 || true
        fi
    fi

    CURRENT_MTU=$new_mtu
    save_config
    echo -e "${GREEN}MTU successfully set to $new_mtu${NC}"
    return 0
}

# Configure DNS - Fixed Version for edns interface
configure_dns() {
    echo -e "\n${YELLOW}Manual DNS Configuration${NC}"
    echo -e "${GREEN}Please enter DNS servers (space separated)${NC}"
    echo -e "${YELLOW}Example: 1.1.1.1 1.0.0.1${NC}"
    echo -e ""
    
    read -p "Enter DNS servers: " dns_input
    if [ -z "$dns_input" ]; then
        echo -e "${RED}No DNS servers entered!${NC}"
        return 1
    fi
    
    # Convert input to array
    local new_dns_servers=($dns_input)
    local valid_dns_servers=()
    
    # Validate DNS servers
    for dns in "${new_dns_servers[@]}"; do
        if validate_ip "$dns"; then
            valid_dns_servers+=("$dns")
        else
            echo -e "${RED}Invalid IP address: $dns${NC}"
        fi
    done
    
    if [ ${#valid_dns_servers[@]} -eq 0 ]; then
        echo -e "${RED}No valid DNS servers entered!${NC}"
        return 1
    fi
    
    # Remove immutable attribute if set
    chattr -i /etc/resolv.conf 2>/dev/null
    
    # Create new resolv.conf
    echo "# Generated by $SCRIPT_NAME" > /etc/resolv.conf
    echo "# Date: $(date)" >> /etc/resolv.conf
    echo "" >> /etc/resolv.conf
    
    for dns in "${valid_dns_servers[@]}"; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    
    # Try to make it immutable to prevent changes
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Additional method for systems with /etc/resolv.conf.head
    if [ -f /etc/resolv.conf.head ]; then
        echo "# Generated by $SCRIPT_NAME - $(date)" > /etc/resolv.conf.head
        for dns in "${valid_dns_servers[@]}"; do
            echo "nameserver $dns" >> /etc/resolv.conf.head
        done
    fi
    
    # Special handling for edns interface
    if [[ "$NETWORK_INTERFACE" == *"edns"* ]]; then
        echo -e "${YELLOW}Detected edns interface - applying special configuration...${NC}"
        
        # Create or update edns-specific configuration
        if [ -d /etc/edns ]; then
            echo "nameserver ${valid_dns_servers[0]}" > /etc/edns/resolv.conf
            [ ${#valid_dns_servers[@]} -gt 1 ] && echo "nameserver ${valid_dns_servers[1]}" >> /etc/edns/resolv.conf
        fi
        
        # Try to restart edns service if exists
        if systemctl list-unit-files | grep -q edns; then
            systemctl restart edns 2>/dev/null || true
        fi
    fi
    
    # Try NetworkManager method
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
        local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" ipv4.dns "$(printf "%s," "${valid_dns_servers[@]}" | sed 's/,$//')" 2>/dev/null
            nmcli con mod "$con_name" ipv4.ignore-auto-dns yes 2>/dev/null
            nmcli con down "$con_name" 2>/dev/null
            nmcli con up "$con_name" 2>/dev/null
        fi
    fi
    
    # Try systemd-resolved method
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        for dns in "${valid_dns_servers[@]}"; do
            resolvectl dns "$NETWORK_INTERFACE" "$dns" 2>/dev/null || true
        done
        systemctl restart systemd-resolved 2>/dev/null || true
    fi
    
    # Try netplan method
    if [ -d /etc/netplan ]; then
        local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -f "$netplan_file" ]; then
            cp "$netplan_file" "$netplan_file.backup.$(date +%Y%m%d_%H%M%S)"
            local dns_string=$(printf " [%s]" "${valid_dns_servers[@]}" | tr -d '\n' | sed 's/\[ /[/g;s/ \]/]/g;s/ /, /g')
            if grep -q "nameservers:" "$netplan_file"; then
                sed -i "/nameservers:/,/^[[:space:]]*[a-zA-Z]/ s/addresses:.*/addresses:$dns_string/" "$netplan_file"
            else
                sed -i "/$NETWORK_INTERFACE:/a\      nameservers:\n        addresses:$dns_string" "$netplan_file"
            fi
            netplan apply 2>/dev/null || true
        fi
    fi
    
    # Restart networking services
    systemctl restart NetworkManager 2>/dev/null || true
    systemctl restart networking 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    
    # Wait for changes to take effect
    sleep 3
    
    # Update configuration
    DNS_SERVERS=("${valid_dns_servers[@]}")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    
    echo -e "${GREEN}DNS servers updated successfully!${NC}"
    echo -e "${YELLOW}New DNS servers: ${BOLD}${valid_dns_servers[*]}${NC}"
    
    # Test DNS connectivity
    echo -e "${YELLOW}Testing DNS connectivity...${NC}"
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup google.com ${valid_dns_servers[0]} >/dev/null 2>&1; then
            echo -e "${GREEN}✓ DNS test successful!${NC}"
        else
            echo -e "${YELLOW}⚠ DNS test failed, checking alternative...${NC}"
            if [ ${#valid_dns_servers[@]} -gt 1 ] && nslookup google.com ${valid_dns_servers[1]} >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Secondary DNS test successful!${NC}"
            else
                echo -e "${RED}✗ DNS configuration may not be working properly${NC}"
            fi
        fi
    elif command -v dig >/dev/null 2>&1; then
        if dig +short google.com @${valid_dns_servers[0]} >/dev/null 2>&1; then
            echo -e "${GREEN}✓ DNS test successful!${NC}"
        else
            echo -e "${YELLOW}⚠ DNS test failed, checking alternative...${NC}"
            if [ ${#valid_dns_servers[@]} -gt 1 ] && dig +short google.com @${valid_dns_servers[1]} >/dev/null 2>&1; then
                echo -e "${GREEN}✓ Secondary DNS test successful!${NC}"
            else
                echo -e "${RED}✗ DNS configuration may not be working properly${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}⚠ DNS testing tools not available, skipping test${NC}"
    fi
    
    # Show current DNS configuration
    echo -e "\n${YELLOW}Current DNS configuration:${NC}"
    cat /etc/resolv.conf 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "Cannot read resolv.conf"
}

# Reset to default DNS
reset_dns() {
    echo -e "${YELLOW}Resetting to default DNS servers...${NC}"
    
    # Remove immutable attribute if set
    chattr -i /etc/resolv.conf 2>/dev/null
    
    # Reset resolv.conf
    cat > /etc/resolv.conf <<EOL
nameserver 8.8.8.8
nameserver 8.8.4.4
EOL
    
    # Special handling for edns interface
    if [[ "$NETWORK_INTERFACE" == *"edns"* ]]; then
        echo -e "${YELLOW}Resetting edns interface DNS...${NC}"
        if [ -f /etc/edns/resolv.conf ]; then
            cat > /etc/edns/resolv.conf <<EOL
nameserver 8.8.8.8
nameserver 8.8.4.4
EOL
        fi
        if systemctl list-unit-files | grep -q edns; then
            systemctl restart edns 2>/dev/null || true
        fi
    fi
    
    # Reset NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" ipv4.ignore-auto-dns no 2>/dev/null
            nmcli con mod "$con_name" ipv4.dns "" 2>/dev/null
            nmcli con down "$con_name" 2>/dev/null
            nmcli con up "$con_name" 2>/dev/null
        fi
    fi
    
    # Reset systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        resolvectl revert "$NETWORK_INTERFACE" 2>/dev/null || true
        systemctl restart systemd-resolved 2>/dev/null
    fi
    
    # Reset netplan
    if [ -d /etc/netplan ]; then
        local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -f "$netplan_file" ]; then
            sed -i '/nameservers:/,/^[[:space:]]*[a-zA-Z]/d' "$netplan_file"
            sed -i '/addresses:/d' "$netplan_file"
            netplan apply 2>/dev/null
        fi
    fi
    
    CURRENT_DNS="8.8.8.8 8.8.4.4"
    DNS_SERVERS=("8.8.8.8" "8.8.4.4")
    save_config
    
    # Restart network services
    systemctl restart NetworkManager 2>/dev/null || true
    systemctl restart networking 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    
    echo -e "${GREEN}DNS reset to default (Google DNS)${NC}"
}

# Show current DNS settings
show_dns() {
    echo -e "\n${YELLOW}Current DNS settings:${NC}"
    echo -e "----------------------------------------"
    cat /etc/resolv.conf 2>/dev/null || echo "Cannot read resolv.conf"
    echo -e "----------------------------------------"
    echo -e "${YELLOW}Configured DNS servers: ${BOLD}$CURRENT_DNS${NC}"
    
    # Show additional DNS info if available
    if command -v resolvectl >/dev/null 2>&1; then
        echo -e "\n${YELLOW}Systemd-resolved DNS:${NC}"
        resolvectl status 2>/dev/null | grep -A10 "DNS Servers" || true
    fi
    
    if command -v nmcli >/dev/null 2>&1; then
        echo -e "\n${YELLOW}NetworkManager DNS:${NC}"
        nmcli dev show 2>/dev/null | grep DNS || true
    fi
    
    # Show edns-specific DNS if applicable
    if [[ "$NETWORK_INTERFACE" == *"edns"* ]] && [ -f /etc/edns/resolv.conf ]; then
        echo -e "\n${YELLOW}edns interface DNS:${NC}"
        cat /etc/edns/resolv.conf
    fi
}

# Install BBR
install_bbr() {
    # Check if BBR is already enabled
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR is already enabled!${NC}"
        return 0
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
EOL

    # Apply settings
    sysctl -p >/dev/null 2>&1

    # Set default MTU and DNS
    configure_mtu 1420
    DNS_SERVERS=("1.1.1.1" "1.0.0.1")
    configure_dns

    # Verify BBR
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR successfully installed and configured${NC}"
        return 0
    else
        echo -e "${RED}Failed to enable BBR! Your kernel may not support BBR.${NC}"
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
            if ! [[ "$port" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Invalid port number!${NC}"
                return 1
            fi
            
            read -p "Enter protocol (tcp/udp, default is tcp): " protocol
            protocol=${protocol:-tcp}
            
            if command -v ufw >/dev/null 2>&1; then
                ufw allow $port/$protocol
                echo -e "${GREEN}Port $port/$protocol has been opened in UFW${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --add-port=$port/$protocol
                firewall-cmd --reload
                echo -e "${GREEN}Port $port/$protocol has been opened in firewalld${NC}"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
            fi
            ;;
        4)
            read -p "Enter port number to close (e.g., 22): " port
            if ! [[ "$port" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Invalid port number!${NC}"
                return 1
            fi
            
            read -p "Enter protocol (tcp/udp, default is tcp): " protocol
            protocol=${protocol:-tcp}
            
            if command -v ufw >/dev/null 2>&1; then
                ufw deny $port/$protocol
                echo -e "${GREEN}Port $port/$protocol has been closed in UFW${NC}"
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --remove-port=$port/$protocol
                firewall-cmd --reload
                echo -e "${GREEN}Port $port/$protocol has been closed in firewalld${NC}"
            else
                echo -e "${RED}No supported firewall detected!${NC}"
            fi
            ;;
        5)
            if command -v ufw >/dev/null 2>&1; then
                echo -e "\n${YELLOW}UFW Open Ports:${NC}"
                ufw status verbose
            elif command -v firewall-cmd >/dev/null 2>&1; then
                echo -e "\n${YELLOW}Firewalld Open Ports:${NC}"
                firewall-cmd --list-ports
                echo -e "\n${YELLOW}Firewalld Services:${NC}"
                firewall-cmd --list-services
            else
                echo -e "${RED}No supported firewall detected!${NC}"
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
            iptables -A INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
            echo -e "${GREEN}ICMP Ping is now BLOCKED! (No one can ping this server)${NC}"
            ;;
        2)
            iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
            echo -e "${GREEN}ICMP Ping is now ALLOWED! (Server is reachable via ping)${NC}"
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
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>/dev/null
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>/dev/null
            echo -e "${GREEN}IPv6 has been DISABLED!${NC}"
            ;;
        2)
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>/dev/null
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>/dev/null
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
            iptables -t nat -A POSTROUTING -d "$iran_ip" -j ACCEPT 2>/dev/null
            echo -e "${GREEN}Iran IP ($iran_ip) is now routed directly!${NC}"
            ;;
        2)
            read -p "Enter Foreign IP/CIDR (e.g., 8.8.8.8/32): " foreign_ip
            read -p "Enter Gateway/VPN IP (e.g., 10.8.0.1): " gateway_ip
            ip route add "$foreign_ip" via "$gateway_ip" 2>/dev/null
            echo -e "${GREEN}Foreign IP ($foreign_ip) is now routed via $gateway_ip!${NC}"
            ;;
        3)
            iptables -t nat -F 2>/dev/null
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
    echo -e "${YELLOW}Resetting network settings...${NC}"
    # Reset MTU to default
    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>/dev/null
    CURRENT_MTU=1500
    
    # Reset DNS to default
    reset_dns
    
    echo -e "${GREEN}Network settings have been reset to default!${NC}"
}

# Reset ALL Changes
reset_all() {
    echo -e "${YELLOW}Resetting ALL changes...${NC}"
    
    # Reset MTU
    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>/dev/null
    CURRENT_MTU=1500

    # Reset DNS
    reset_dns

    # Reset ICMP
    iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null

    # Reset IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>/dev/null

    # Reset IPTables
    iptables -t nat -F 2>/dev/null

    # Remove BBR settings
    sed -i '/net.core.default_qdisc=fq/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen=3/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_syncookies=1/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_tw_reuse=1/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fin_timeout=30/d' /etc/sysctl.conf
    sed -i '/net.ipv4.ip_local_port_range=1024 65000/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_max_syn_backlog=8192/d' /etc/sysctl.conf
    sed -i '/net.core.somaxconn=65535/d' /etc/sysctl.conf
    sed -i '/net.core.netdev_max_backlog=16384/d' /etc/sysctl.conf
    
    sysctl -p >/dev/null 2>&1

    # Remove config file
    rm -f "$CONFIG_FILE"

    echo -e "${GREEN}All changes have been reset to default!${NC}"
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
        echo -e "11) Show Current DNS"
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
                configure_dns
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
                show_dns
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
show_menu
