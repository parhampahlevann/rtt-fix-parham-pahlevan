#!/bin/bash

# Global Configuration
SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="8.5"  # Updated version for fixes
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
    else
        return 1
    fi
}

# Test DNS
_test_dns() {
    local dns=$1
    if command -v dig >/dev/null 2>&1; then
        dig +short google.com @"$dns" >/dev/null 2>&1 && return 0
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup google.com "$dns" >/dev/null 2>&1 && return 0
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
            netplan apply >/dev/null 2>&1 || {
                echo -e "${RED}Failed to apply Netplan configuration!${NC}"
                ip link set dev "$NETWORK_INTERFACE" mtu "$old_mtu"
                return 1
            }
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

# Update resolv.conf with new DNS servers (only if not using systemd-resolved)
update_resolv_conf() {
    local dns_servers=("$@")
    
    echo -e "${YELLOW}Updating /etc/resolv.conf...${NC}"
    
    # Backup existing resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.backup."$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # Create new resolv.conf
    cat > /etc/resolv.conf <<EOL
# Generated by $SCRIPT_NAME
# Date: $(date)
# Do not edit this file manually unless systemd-resolved is disabled

EOL
    
    # Add nameservers
    for dns in "${dns_servers[@]}"; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    
    # Add search domain and options
    echo "search ." >> /etc/resolv.conf
    echo "options rotate timeout:1 attempts:2" >> /etc/resolv.conf
    
    echo -e "${GREEN}/etc/resolv.conf updated successfully!${NC}"
}

# Configure DNS for edns0 interface
configure_edns_dns() {
    local dns_servers=("$@")
    
    echo -e "${YELLOW}Configuring edns0 interface DNS...${NC}"
    
    # Method 1: NetworkManager configuration
    if ip link show edns0 >/dev/null 2>&1 && command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
        local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show edns0 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" ipv4.dns "$(printf "%s;" "${dns_servers[@]}" | sed 's/;$//')"
            nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
            nmcli con down "$con_name" 2>/dev/null
            nmcli con up "$con_name" 2>/dev/null
            echo -e "${GREEN}NetworkManager updated for edns0${NC}"
        fi
    fi
    
    # Method 2: Systemd-networkd configuration
    if ip link show edns0 >/dev/null 2>&1 && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        local network_file="/etc/systemd/network/edns0.network"
        cat > "$network_file" <<EOL
[Match]
Name=edns0

[Network]
DHCP=no
DNS=$(printf "%s " "${dns_servers[@]}" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ')

[DHCP]
UseDNS=false
EOL
        systemctl restart systemd-networkd 2>/dev/null
        echo -e "${GREEN}systemd-networkd updated for edns0${NC}"
    fi
    
    # Method 3: DHCP client configuration
    if ip link show edns0 >/dev/null 2>&1 && command -v dhclient >/dev/null 2>&1; then
        dhclient -r edns0 2>/dev/null
        for dns in "${dns_servers[@]}"; do
            echo "supersede domain-name-servers $dns;" >> /etc/dhcp/dhclient.conf
        done
        dhclient -4 -pf /var/run/dhclient.edns0.pid -lf /var/lib/dhcp/dhclient.edns0.leases edns0 2>/dev/null
        echo -e "${GREEN}DHCP client updated for edns0${NC}"
    fi
    
    echo -e "${GREEN}edns0 interface DNS configured!${NC}"
}

# Comprehensive DNS Configuration
configure_dns() {
    echo -e "\n${YELLOW}Manual DNS Configuration${NC}"
    echo -e "${GREEN}Please enter DNS servers (space separated)${NC}"
    echo -e "${YELLOW}Example: 1.1.1.1 1.0.0.1 8.8.8.8${NC}"
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
    
    echo -e "${YELLOW}Configuring DNS servers: ${valid_dns_servers[*]}${NC}"
    
    # Backup current configurations
    local backup_dir="/etc/network_optimizer_backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # Handle systemd-resolved if active
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo -e "${YELLOW}Configuring systemd-resolved...${NC}"
        for iface in $(ip link | grep '^[0-9]' | awk '{print $2}' | sed 's/://' | grep -v '^lo$'); do
            for dns in "${valid_dns_servers[@]}"; do
                resolvectl set-dns "$iface" "$dns" 2>/dev/null
            done
        done
        resolvectl flush-caches 2>/dev/null
        systemctl restart systemd-resolved 2>/dev/null || {
            echo -e "${RED}Failed to restart systemd-resolved!${NC}"
            return 1
        }
        echo -e "${GREEN}systemd-resolved configured${NC}"
    else
        # Update /etc/resolv.conf if systemd-resolved is not used
        cp /etc/resolv.conf "$backup_dir/resolv.conf" 2>/dev/null || true
        update_resolv_conf "${valid_dns_servers[@]}"
    fi
    
    # Configure all interfaces
    local interfaces=($(ip link | grep '^[0-9]' | awk '{print $2}' | sed 's/://' | grep -v '^lo$'))
    for iface in "${interfaces[@]}"; do
        # NetworkManager configuration
        if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
            local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$iface" 2>/dev/null | cut -d: -f2)
            if [ -n "$con_name" ]; then
                cp /etc/NetworkManager/system-connections/"$con_name".nmconnection "$backup_dir/$con_name.nmconnection" 2>/dev/null || true
                nmcli con mod "$con_name" ipv4.dns "$(printf "%s;" "${valid_dns_servers[@]}" | sed 's/;$//')"
                nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
                nmcli con down "$con_name" 2>/dev/null
                nmcli con up "$con_name" 2>/dev/null || {
                    echo -e "${RED}Failed to apply NetworkManager settings for $iface!${NC}"
                    return 1
                }
                echo -e "${GREEN}NetworkManager updated for $iface${NC}"
            fi
        fi
        
        # Systemd-networkd configuration
        if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
            local network_file="/etc/systemd/network/$iface.network"
            cp "$network_file" "$backup_dir/$iface.network" 2>/dev/null || true
            cat > "$network_file" <<EOL
[Match]
Name=$iface

[Network]
DHCP=no
DNS=$(printf "%s " "${valid_dns_servers[@]}" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ')

[DHCP]
UseDNS=false
EOL
            systemctl restart systemd-networkd 2>/dev/null || {
                echo -e "${RED}Failed to restart systemd-networkd for $iface!${NC}"
                return 1
            }
            echo -e "${GREEN}systemd-networkd updated for $iface${NC}"
        fi
        
        # Netplan configuration (Ubuntu default)
        if [ -d /etc/netplan ]; then
            local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
            if [ -f "$netplan_file" ]; then
                cp "$netplan_file" "$backup_dir/netplan_$(basename "$netplan_file")"
                sed -i "/$iface:/,/^[[:space:]]*[^[:space:]]/ s/nameservers:.*/nameservers:\n        addresses: [$(printf "\"%s\", " "${valid_dns_servers[@]}" | sed 's/, $//')]/" "$netplan_file"
                if ! grep -A2 "$iface:" "$netplan_file" | grep -q "nameservers:"; then
                    sed -i "/$iface:/a\      nameservers:\n        addresses: [$(printf "\"%s\", " "${valid_dns_servers[@]}" | sed 's/, $//')]" "$netplan_file"
                fi
                netplan apply 2>/dev/null || {
                    echo -e "${RED}Failed to apply Netplan configuration for $iface!${NC}"
                    cp "$backup_dir/netplan_$(basename "$netplan_file")" "$netplan_file"
                    netplan apply 2>/dev/null
                    return 1
                }
                echo -e "${GREEN}Netplan updated for $iface${NC}"
            fi
        fi
        
        # Debian/Ubuntu interfaces
        if [ -f /etc/network/interfaces ]; then
            cp /etc/network/interfaces "$backup_dir/interfaces"
            sed -i "/iface $iface inet/,/^\s*$/ s/dns-nameservers.*/dns-nameservers $(echo ${valid_dns_servers[@]})/" /etc/network/interfaces
            if ! grep -A3 "iface $iface inet" /etc/network/interfaces | grep -q "dns-nameservers"; then
                sed -i "/iface $iface inet/a\    dns-nameservers $(echo ${valid_dns_servers[@]})" /etc/network/interfaces
            fi
            systemctl restart networking 2>/dev/null || true
            echo -e "${GREEN}/etc/network/interfaces updated for $iface${NC}"
        fi
        
        # CentOS/RHEL
        if [ -f /etc/sysconfig/network-scripts/ifcfg-$iface ]; then
            local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-$iface"
            cp "$ifcfg_file" "$backup_dir/ifcfg-$iface"
            sed -i '/DNS[0-9]=/d' "$ifcfg_file"
            sed -i '/PEERDNS=/d' "$ifcfg_file"
            echo "PEERDNS=no" >> "$ifcfg_file"
            for i in "${!valid_dns_servers[@]}"; do
                echo "DNS$((i+1))=${valid_dns_servers[$i]}" >> "$ifcfg_file"
            done
            systemctl restart network 2>/dev/null || true
            echo -e "${GREEN}CentOS/RHEL network scripts updated for $iface${NC}"
        fi
    done
    
    # Configure edns0 specifically
    if ip link show edns0 >/dev/null 2>&1; then
        configure_edns_dns "${valid_dns_servers[@]}"
    fi
    
    # Test DNS configuration
    echo -e "${YELLOW}Testing DNS configuration...${NC}"
    local test_passed=0
    for dns in "${valid_dns_servers[@]}"; do
        if _test_dns "$dns"; then
            echo -e "${GREEN}✓ DNS test successful for $dns${NC}"
            test_passed=1
        else
            echo -e "${YELLOW}⚠ DNS test failed for $dns${NC}"
        fi
    done
    
    if [ $test_passed -eq 0 ]; then
        echo -e "${RED}All DNS tests failed! Reverting changes...${NC}"
        # Rollback changes
        if [ -d /etc/netplan ]; then
            local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
            if [ -f "$backup_dir/netplan_$(basename "$netplan_file")" ]; then
                cp "$backup_dir/netplan_$(basename "$netplan_file")" "$netplan_file"
                netplan apply 2>/dev/null
            fi
        fi
        if [ -f "$backup_dir/resolv.conf" ]; then
            cp "$backup_dir/resolv.conf" /etc/resolv.conf
        fi
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            resolvectl revert 2>/dev/null
            systemctl restart systemd-resolved 2>/dev/null
        fi
        return 1
    fi
    
    # Update configuration
    DNS_SERVERS=("${valid_dns_servers[@]}")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    
    echo -e "${GREEN}DNS configuration completed successfully!${NC}"
    echo -e "${YELLOW}Configured DNS servers: ${BOLD}${valid_dns_servers[*]}${NC}"
}

# Reset to default DNS
reset_dns() {
    echo -e "${YELLOW}Resetting to default DNS servers...${NC}"
    
    local default_dns=("8.8.8.8" "8.8.4.4")
    
    # Enable and restart systemd-resolved if it was previously disabled
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl enable systemd-resolved 2>/dev/null
        systemctl start systemd-resolved 2>/dev/null
    fi
    
    # Reset systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        for iface in $(ip link | grep '^[0-9]' | awk '{print $2}' | sed 's/://' | grep -v '^lo$'); do
            resolvectl set-dns "$iface" "${default_dns[@]}" 2>/dev/null
        done
        resolvectl flush-caches 2>/dev/null
        systemctl restart systemd-resolved 2>/dev/null
        echo -e "${GREEN}systemd-resolved reset to default DNS${NC}"
    else
        # Update resolv.conf if systemd-resolved is not used
        update_resolv_conf "${default_dns[@]}"
    fi
    
    # Reset all interfaces
    local interfaces=($(ip link | grep '^[0-9]' | awk '{print $2}' | sed 's/://' | grep -v '^lo$'))
    for iface in "${interfaces[@]}"; do
        # NetworkManager
        if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
            local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$iface" 2>/dev/null | cut -d: -f2)
            if [ -n "$con_name" ]; then
                nmcli con mod "$con_name" ipv4.ignore-auto-dns no
                nmcli con mod "$con_name" ipv4.dns ""
                nmcli con down "$con_name" 2>/dev/null
                nmcli con up "$con_name" 2>/dev/null
                echo -e "${GREEN}NetworkManager reset for $iface${NC}"
            fi
        fi
        
        # Systemd-networkd
        if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
            local network_file="/etc/systemd/network/$iface.network"
            if [ -f "$network_file" ]; then
                sed -i '/DNS=/d' "$network_file"
                sed -i '/UseDNS=/d' "$network_file"
                systemctl restart systemd-networkd 2>/dev/null
                echo -e "${GREEN}systemd-networkd reset for $iface${NC}"
            fi
        fi
        
        # Netplan
        if [ -d /etc/netplan ]; then
            local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
            if [ -f "$netplan_file" ]; then
                cp "$netplan_file" "$netplan_file.backup.$(date +%Y%m%d_%H%M%S)"
                sed -i "/$iface:/,/^[[:space:]]*[^[:space:]]/ s/nameservers:.*/nameservers:\n        addresses: [$(printf "\"%s\", " "${default_dns[@]}" | sed 's/, $//')]/" "$netplan_file"
                netplan apply 2>/dev/null
                echo -e "${GREEN}Netplan reset for $iface${NC}"
            fi
        fi
        
        # Debian/Ubuntu interfaces
        if [ -f /etc/network/interfaces ]; then
            cp /etc/network/interfaces /etc/network/interfaces.backup."$(date +%Y%m%d_%H%M%S)"
            sed -i "/iface $iface inet/,/^\s*$/ s/dns-nameservers.*/dns-nameservers $(echo ${default_dns[@]})/" /etc/network/interfaces
            systemctl restart networking 2>/dev/null || true
            echo -e "${GREEN}/etc/network/interfaces reset for $iface${NC}"
        fi
        
        # CentOS/RHEL
        if [ -f /etc/sysconfig/network-scripts/ifcfg-$iface ]; then
            local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-$iface"
            sed -i '/DNS[0-9]=/d' "$ifcfg_file"
            sed -i '/PEERDNS=/d' "$ifcfg_file"
            echo "PEERDNS=yes" >> "$ifcfg_file"
            systemctl restart network 2>/dev/null || true
            echo -e "${GREEN}CentOS/RHEL network scripts reset for $iface${NC}"
        fi
    done
    
    # Reset edns0
    if ip link show edns0 >/dev/null 2>&1; then
        configure_edns_dns "${default_dns[@]}"
    fi
    
    # Update configuration
    DNS_SERVERS=("${default_dns[@]}")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    
    echo -e "${GREEN}DNS reset to default (Google DNS: ${default_dns[*]})${NC}"
}

# Show current DNS settings
show_dns() {
    echo -e "\n${YELLOW}Current DNS settings:${NC}"
    echo -e "----------------------------------------"
    
    # Show resolv.conf
    echo -e "${BOLD}/etc/resolv.conf:${NC}"
    cat /etc/resolv.conf 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "Cannot read resolv.conf"
    echo -e "----------------------------------------"
    
    # Show interface-specific configurations
    local interfaces=($(ip link | grep '^[0-9]' | awk '{print $2}' | sed 's/://' | grep -v '^lo$'))
    for iface in "${interfaces[@]}"; do
        echo -e "${BOLD}$iface DNS Configuration:${NC}"
        
        # NetworkManager
        if command -v nmcli >/dev/null 2>&1; then
            nmcli dev show "$iface" 2>/dev/null | grep DNS || echo "No NetworkManager DNS settings"
        fi
        
        # Systemd-networkd
        if [ -f /etc/systemd/network/$iface.network ]; then
            grep DNS /etc/systemd/network/$iface.network 2>/dev/null || echo "No systemd-networkd DNS settings"
        fi
        
        # Netplan
        if [ -d /etc/netplan ]; then
            local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
            if [ -f "$netplan_file" ]; then
                grep -A3 "$iface:.*nameservers" "$netplan_file" 2>/dev/null || echo "No Netplan DNS settings"
            fi
        fi
        
        # Debian/Ubuntu interfaces
        if [ -f /etc/network/interfaces ]; then
            grep -A3 "iface $iface inet" /etc/network/interfaces | grep dns-nameservers 2>/dev/null || echo "No interfaces DNS settings"
        fi
        
        # CentOS/RHEL
        if [ -f /etc/sysconfig/network-scripts/ifcfg-$iface ]; then
            grep DNS /etc/sysconfig/network-scripts/ifcfg-$iface 2>/dev/null || echo "No CentOS/RHEL DNS settings"
        fi
        
        # systemd-resolved
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            resolvectl status "$iface" 2>/dev/null | grep -A5 "DNS Servers" || echo "No systemd-resolved DNS settings"
        fi
        echo -e "----------------------------------------"
    done
    
    echo -e "${YELLOW}Configured DNS servers: ${BOLD}$CURRENT_DNS${NC}"
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
        echo -e "5) Manage ICMP Ping"
        echo -e "6) Manage IPv6"
        echo -e "7) Setup IPTable Tunnel"
        echo -e "8) Ping MTU Size Test"
        echo -e "9) Reset ALL Changes"
        echo -e "10) Show Current DNS"
        echo -e "11) Exit"
        
        read -p "Enter your choice [1-11]: " choice
        
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
                manage_icmp
                ;;
            6)
                manage_ipv6
                ;;
            7)
                manage_tunnel
                ;;
            8)
                ping_mtu
                ;;
            9)
                reset_all
                ;;
            10)
                show_dns
                ;;
            11)
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
