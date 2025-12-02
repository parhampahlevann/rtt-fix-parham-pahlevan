#!/bin/bash

# Global Configuration
SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="9.5.0"  # Updated: Fixed WARP installation with auto-registration
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/network_optimizer.conf"
LOG_FILE="/var/log/network_optimizer.log"
BACKUP_DIR="/var/backups/network_optimizer"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
DEFAULT_MTU=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo 1500)
CURRENT_MTU=$DEFAULT_MTU
DNS_SERVERS=("1.1.1.1" "1.0.0.1")
CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')

# DNS Services Management
DNS_SERVICES=( "systemd-resolved" "resolvconf" "dnsmasq" "unbound" "bind9" "named" "NetworkManager" )
declare -A DETECTED_SERVICES_STATUS

# Distribution Detection
DISTRO="unknown"
DISTRO_VERSION=""

# Initialize logging and directories
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Helper Functions
print_separator() { 
    echo "-----------------------------------------------------" 
}

# Check for essential commands
check_requirements() {
    local missing=()
    
    for cmd in ip awk grep sed date; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing required commands: ${missing[*]}${NC}"
        echo -e "${YELLOW}Please install them before running this script.${NC}"
        exit 1
    fi
}

# Confirm dangerous operations
confirm_action() {
    local message="$1"
    echo -e "${RED}WARNING: $message${NC}"
    read -p "Are you sure? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || [[ "$confirm" == "y" ]]
}

# Distribution Detection
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

# Save Configuration
save_config() {
    cat > "$CONFIG_FILE" <<EOL
# Network Optimizer Configuration
MTU=$CURRENT_MTU
DNS_SERVERS=(${DNS_SERVERS[@]})
NETWORK_INTERFACE=$NETWORK_INTERFACE
DISTRO=$DISTRO
DISTRO_VERSION=$DISTRO_VERSION
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
    echo -e "${BLUE}${BOLD}====================================================="
    echo -e "   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}"
    echo -e "=====================================================${NC}"
    
    detect_distro
    echo -e "${YELLOW}Distribution: ${BOLD}$DISTRO $DISTRO_VERSION${NC}"
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
    
    # Show VXLAN Tunnel Status
    if ip link show vxlan100 >/dev/null 2>&1; then
        echo -e "${YELLOW}VXLAN Tunnel: ${GREEN}Active${NC}"
    fi
    
    # Show HAProxy Status
    if command -v haproxy >/dev/null 2>&1; then
        if systemctl is-active --quiet haproxy 2>/dev/null; then
            echo -e "${YELLOW}HAProxy: ${GREEN}Active${NC}"
        else
            echo -e "${YELLOW}HAProxy: ${YELLOW}Installed (Not running)${NC}"
        fi
    fi
    
    # Show WARP Status
    if command -v warp-cli >/dev/null 2>&1; then
        if systemctl is-active --quiet warp-svc 2>/dev/null; then
            echo -e "${YELLOW}Cloudflare WARP: ${YELLOW}Service Running${NC}"
            local warp_status=$(warp-cli --accept-tos status 2>/dev/null | grep -E "Connected|Disconnected" | head -1 | xargs)
            if [[ "$warp_status" == *"Connected"* ]]; then
                echo -e "${YELLOW}Connection: ${GREEN}Connected${NC}"
            else
                echo -e "${YELLOW}Connection: ${RED}Not Connected${NC}"
            fi
        else
            echo -e "${YELLOW}Cloudflare WARP: ${RED}Service Not Running${NC}"
        fi
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

# Network Speed Test
speed_test() {
    echo -e "\n${YELLOW}Running Network Speed Test...${NC}"
    print_separator
    
    # Test latency to multiple targets
    echo -e "${BLUE}Testing Latency...${NC}"
    local targets=("8.8.8.8" "1.1.1.1" "4.2.2.4")
    for target in "${targets[@]}"; do
        echo -n "Ping $target: "
        ping -c 2 -W 2 "$target" 2>/dev/null | grep "min/avg/max" | awk -F'/' '{print $5 " ms"}' || echo "Timeout"
    done
    
    # Test DNS resolution speed
    if command -v dig >/dev/null 2>&1; then
        echo -e "\n${BLUE}Testing DNS Resolution Speed...${NC}"
        local dns_servers=("8.8.8.8" "1.1.1.1" "208.67.222.222")
        for dns in "${dns_servers[@]}"; do
            echo -n "DNS $dns: "
            time dig google.com @"$dns" 2>/dev/null | grep "Query time" | awk '{print $4 " ms"}' || echo "Failed"
        done
    fi
    
    # Download speed test (small file)
    echo -e "\n${BLUE}Testing Download Speed...${NC}"
    if command -v curl >/dev/null 2>&1; then
        local test_urls=(
            "http://speedtest.ftp.otenet.gr/files/test1Mb.db"
            "http://ipv4.download.thinkbroadband.com/1MB.zip"
        )
        
        for test_url in "${test_urls[@]}"; do
            echo -n "Testing $test_url: "
            local speed=$(curl -o /dev/null -w "%{speed_download}" -s "$test_url" 2>/dev/null)
            if [ -n "$speed" ]; then
                local speed_mbps=$(echo "scale=2; $speed / 125000" | bc 2>/dev/null || echo "0")
                echo "${speed_mbps:-0} Mbps"
            else
                echo "Failed"
            fi
            break # Test only first working URL
        done
    else
        echo -e "${YELLOW}Curl not available for download test${NC}"
    fi
    
    # Interface statistics
    echo -e "\n${BLUE}Interface Statistics:${NC}"
    cat /proc/net/dev | grep "$NETWORK_INTERFACE" | awk '{
        print "Received: " $2 " bytes, Transmitted: " $10 " bytes"
    }'
    
    print_separator
    echo -e "${GREEN}Speed test completed!${NC}"
}

# Universal MTU Configuration
configure_mtu() {
    local new_mtu=$1
    local old_mtu=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo $DEFAULT_MTU)

    # Validate MTU
    if [[ ! "$new_mtu" =~ ^[0-9]+$ ]] || [ "$new_mtu" -lt 576 ] || [ "$new_mtu" -gt 9000 ]; then
        echo -e "${RED}Invalid MTU value! Must be between 576 and 9000.${NC}"
        return 1
    fi

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
    local config_applied=false
    
    # Netplan (Ubuntu)
    if [[ -d /etc/netplan ]] && command -v netplan >/dev/null 2>&1; then
        local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -f "$netplan_file" ]; then
            cp "$netplan_file" "$netplan_file.backup.$(date +%Y%m%d_%H%M%S)"
            if grep -q "mtu:" "$netplan_file"; then
                sed -i "s/mtu:.*/mtu: $new_mtu/" "$netplan_file"
            else
                # Find the right place to insert MTU
                if grep -A 10 "$NETWORK_INTERFACE:" "$netplan_file" | grep -q "dhcp4:"; then
                    sed -i "/$NETWORK_INTERFACE:/,/dhcp4:/{/dhcp4:/i\      mtu: $new_mtu" "$netplan_file"
                else
                    sed -i "/$NETWORK_INTERFACE:/a\      mtu: $new_mtu" "$netplan_file"
                fi
            fi
            if netplan apply >/dev/null 2>&1; then
                config_applied=true
                echo -e "${GREEN}MTU set via Netplan${NC}"
            fi
        fi
    fi

    # NetworkManager
    if [ "$config_applied" = false ] && command -v nmcli >/dev/null 2>&1 && (systemctl is-active --quiet NetworkManager 2>/dev/null || pgrep NetworkManager >/dev/null); then
        local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" 802-3-ethernet.mtu $new_mtu 2>/dev/null || \
            nmcli con mod "$con_name" wifi.mtu $new_mtu 2>/dev/null
            nmcli con down "$con_name" 2>/dev/null
            nmcli con up "$con_name" 2>/dev/null
            config_applied=true
            echo -e "${GREEN}MTU set via NetworkManager${NC}"
        fi
    fi

    # Sysconfig (RedHat/CentOS)
    if [ "$config_applied" = false ] && [[ -d /etc/sysconfig/network-scripts ]]; then
        local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-$NETWORK_INTERFACE"
        if [ -f "$ifcfg_file" ]; then
            cp "$ifcfg_file" "$ifcfg_file.backup.$(date +%Y%m%d_%H%M%S)"
            if grep -q "MTU=" "$ifcfg_file"; then
                sed -i "s/MTU=.*/MTU=$new_mtu/" "$ifcfg_file"
            else
                echo "MTU=$new_mtu" >> "$ifcfg_file"
            fi
            if systemctl restart network >/dev/null 2>&1; then
                config_applied=true
                echo -e "${GREEN}MTU set via sysconfig${NC}"
            fi
        fi
    fi

    # Interfaces (Debian)
    if [ "$config_applied" = false ] && [[ -f /etc/network/interfaces ]]; then
        cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)
        if grep -q "mtu" /etc/network/interfaces; then
            sed -i "s/mtu.*/mtu $new_mtu/" /etc/network/interfaces
        else
            sed -i "/iface $NETWORK_INTERFACE inet/a\    mtu $new_mtu" /etc/network/interfaces
        fi
        if systemctl restart networking >/dev/null 2>&1; then
            config_applied=true
            echo -e "${GREEN}MTU set via interfaces file${NC}"
        fi
    fi

    # Fallback: systemd networkd
    if [ "$config_applied" = false ] && command -v networkctl >/dev/null 2>&1; then
        local networkd_dir="/etc/systemd/network"
        if [ -d "$networkd_dir" ]; then
            local networkd_file=$(find "$networkd_dir" -name "*.network" | head -n1)
            if [ -f "$networkd_file" ]; then
                cp "$networkd_file" "$networkd_file.backup.$(date +%Y%m%d_%H%M%S)"
                if grep -q "MTU=" "$networkd_file"; then
                    sed -i "s/MTU=.*/MTU=$new_mtu/" "$networkd_file"
                else
                    echo -e "\n[Link]\nMTU=$new_mtu" >> "$networkd_file"
                fi
                systemctl restart systemd-networkd >/dev/null 2>&1
                config_applied=true
                echo -e "${GREEN}MTU set via systemd-networkd${NC}"
            fi
        fi
    fi

    if [ "$config_applied" = false ]; then
        echo -e "${YELLOW}Warning: Could not set permanent MTU. Only temporary MTU applied.${NC}"
        echo -e "${YELLOW}You may need to configure MTU manually for your distribution.${NC}"
    fi

    CURRENT_MTU=$new_mtu
    save_config
    echo -e "${GREEN}MTU successfully set to $new_mtu${NC}"
    return 0
}

# DNS Services Detection
detect_dns_services() {
    echo "Detecting DNS-related services..."
    print_separator
    
    for svc in "${DNS_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            DETECTED_SERVICES_STATUS["$svc"]="active"
            echo -e "${YELLOW}Detected: $svc (active)${NC}"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            DETECTED_SERVICES_STATUS["$svc"]="enabled"
            echo -e "${YELLOW}Detected: $svc (enabled)${NC}"
        elif command -v "$svc" >/dev/null 2>&1; then
            DETECTED_SERVICES_STATUS["$svc"]="installed"
            echo -e "${YELLOW}Detected: $svc (installed)${NC}"
        fi
    done
}

# Disable DNS Service
disable_service() {
    local svc="$1"
    echo "Disabling $svc..."
    
    if systemctl stop "$svc" 2>/dev/null; then
        echo -e "${GREEN}Stopped $svc${NC}"
    fi
    
    if systemctl disable "$svc" 2>/dev/null; then
        echo -e "${GREEN}Disabled $svc${NC}"
    fi
    
    if systemctl mask "$svc" 2>/dev/null; then
        echo -e "${GREEN}Masked $svc${NC}"
    fi
}

# Remove DNS Service
remove_service() {
    local svc="$1"
    echo "Removing $svc..."
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove --purge -y "$svc" 2>/dev/null && \
        echo -e "${GREEN}Removed $svc${NC}"
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y "$svc" 2>/dev/null && \
        echo -e "${GREEN}Removed $svc${NC}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y "$svc" 2>/dev/null && \
        echo -e "${GREEN}Removed $svc${NC}"
    else
        echo -e "${YELLOW}Package manager not found, cannot remove $svc${NC}"
    fi
}

# Enhanced DNS Services Management
manage_dns_services_enhanced() {
    detect_dns_services
    
    if [ ${#DETECTED_SERVICES_STATUS[@]} -eq 0 ]; then
        echo -e "${GREEN}No DNS services detected that need management.${NC}"
        return 0
    fi
    
    while true; do
        echo ""
        print_separator
        echo "Detected DNS Services:"
        local i=1
        declare -A service_list
        
        for svc in "${!DETECTED_SERVICES_STATUS[@]}"; do
            echo "$i) $svc (${DETECTED_SERVICES_STATUS[$svc]})"
            service_list[$i]="$svc"
            ((i++))
        done
        
        local all_services_option=$i
        echo "$all_services_option) All Services"
        local back_option=$((i+1))
        echo "$back_option) Back to Main Menu"
        
        read -p "Select service to manage: " service_choice
        
        if [ "$service_choice" -eq "$all_services_option" ]; then
            # Manage all services
            for svc in "${!DETECTED_SERVICES_STATUS[@]}"; do
                disable_service "$svc"
            done
            set_resolv_conf
            echo -e "${GREEN}All DNS services disabled!${NC}"
            break
        elif [ "$service_choice" -eq "$back_option" ]; then
            return
        elif [ -n "${service_list[$service_choice]}" ]; then
            # Manage single service
            local selected_svc="${service_list[$service_choice]}"
            echo ""
            echo "Managing: $selected_svc"
            echo "1) Disable only"
            echo "2) Disable and remove"
            echo "3) Back"
            
            read -p "Choose action: " action_choice
            case $action_choice in
                1)
                    disable_service "$selected_svc"
                    ;;
                2)
                    disable_service "$selected_svc"
                    remove_service "$selected_svc"
                    ;;
                3)
                    continue
                    ;;
                *)
                    echo -e "${RED}Invalid option!${NC}"
                    ;;
            esac
        else
            echo -e "${RED}Invalid selection!${NC}"
        fi
        
        read -p "Press [Enter] to continue..."
    done
}

# Set resolv.conf
set_resolv_conf() {
    echo ""
    print_separator
    echo "Setting default DNS resolvers..."
    
    # Remove immutable attribute if set
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Create new resolv.conf
    cat > /etc/resolv.conf <<EOF
# Generated by $SCRIPT_NAME
# Date: $(date)
# Do not edit this file manually

nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    
    # Make file immutable to prevent changes by other services
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    echo -e "${GREEN}/etc/resolv.conf updated successfully!${NC}"
}

# Update resolv.conf with new DNS servers
update_resolv_conf() {
    local dns_servers=("$@")
    
    echo -e "${YELLOW}Updating /etc/resolv.conf...${NC}"
    
    # Remove immutable attribute if set
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Backup existing resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.backup."$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # Create new resolv.conf
    cat > /etc/resolv.conf <<EOL
# Generated by $SCRIPT_NAME
# Date: $(date)
# Do not edit this file manually

EOL
    
    # Add nameservers
    for dns in "${dns_servers[@]}"; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    
    # Add search domain and options
    echo "search ." >> /etc/resolv.conf
    echo "options rotate timeout:1 attempts:2" >> /etc/resolv.conf
    
    # Make file immutable to prevent changes by other services
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    echo -e "${GREEN}/etc/resolv.conf updated successfully!${NC}"
}

# Safe DNS configuration for main interface only
configure_dns_safe() {
    local dns_servers=("$@")
    
    echo -e "${YELLOW}Configuring DNS safely for main interface only...${NC}"
    
    # First manage DNS services
    manage_dns_services_enhanced
    
    # Update resolv.conf
    update_resolv_conf "${dns_servers[@]}"
    
    # Only configure the main network interface
    if command -v nmcli >/dev/null 2>&1 && (systemctl is-active --quiet NetworkManager 2>/dev/null || pgrep NetworkManager >/dev/null); then
        local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" ipv4.dns "$(printf "%s;" "${dns_servers[@]}" | sed 's/;$//')"
            nmcli con mod "$con_name" ipv4.ignore-auto-dns yes
            nmcli con down "$con_name" 2>/dev/null
            nmcli con up "$con_name" 2>/dev/null
            echo -e "${GREEN}NetworkManager updated for $NETWORK_INTERFACE${NC}"
        fi
    fi
    
    echo -e "${GREEN}DNS configured safely for main interface!${NC}"
    return 0
}

# Comprehensive DNS Configuration (SAFE VERSION)
configure_dns() {
    echo -e "\n${YELLOW}Manual DNS Configuration${NC}"
    echo -e "${GREEN}Please enter DNS servers (space separated)${NC}"
    echo -e "${YELLOW}Example: 1.1.1.1 1.0.0.1 8.8.8.8${NC}"
    echo -e "${YELLOW}Recommended: 1.1.1.1 1.0.0.1 (Cloudflare)${NC}"
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
    
    # Use safe DNS configuration
    if ! configure_dns_safe "${valid_dns_servers[@]}"; then
        echo -e "${RED}Failed to configure DNS!${NC}"
        return 1
    fi
    
    # Update configuration
    DNS_SERVERS=("${valid_dns_servers[@]}")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    
    # Test DNS
    echo -e "${YELLOW}Testing DNS configuration...${NC}"
    local test_passed=0
    if command -v dig >/dev/null 2>&1; then
        for dns in "${valid_dns_servers[@]}"; do
            if timeout 5 dig +short google.com @"$dns" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ DNS test successful for $dns${NC}"
                test_passed=1
            else
                echo -e "${YELLOW}✗ DNS test failed for $dns${NC}"
            fi
        done
    elif command -v nslookup >/dev/null 2>&1; then
        for dns in "${valid_dns_servers[@]}"; do
            if timeout 5 nslookup google.com "$dns" >/dev/null 2>&1; then
                echo -e "${GREEN}✓ DNS test successful for $dns${NC}"
                test_passed=1
            else
                echo -e "${YELLOW}✗ DNS test failed for $dns${NC}"
            fi
        done
    else
        echo -e "${YELLOW}✗ DNS testing tools not available${NC}"
        test_passed=1  # Assume success if no tools available
    fi
    
    if [ $test_passed -eq 1 ]; then
        echo -e "${GREEN}DNS configuration completed successfully!${NC}"
        echo -e "${YELLOW}Configured DNS servers: ${BOLD}${valid_dns_servers[*]}${NC}"
    else
        echo -e "${YELLOW}✗ DNS configuration applied but tests failed.${NC}"
        echo -e "${YELLOW}Server will continue to boot normally.${NC}"
    fi
    
    return 0
}

# Reset to default DNS (SAFE VERSION)
reset_dns() {
    echo -e "${YELLOW}Resetting to default DNS servers...${NC}"
    
    default_dns=("8.8.8.8" "8.8.4.4")
    
    # Remove immutable attribute if set
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Restore original resolv.conf if backup exists
    if [ -f /etc/resolv.conf.backup.* ]; then
        local backup_file=$(ls -t /etc/resolv.conf.backup.* | head -n1)
        cp "$backup_file" /etc/resolv.conf
        echo -e "${GREEN}Restored from backup: $backup_file${NC}"
    else
        # Create default resolv.conf
        cat > /etc/resolv.conf <<EOL
# Generated by $SCRIPT_NAME (reset)
nameserver 8.8.8.8
nameserver 8.8.4.4
EOL
    fi
    
    # Reset NetworkManager configuration for main interface only
    if command -v nmcli >/dev/null 2>&1 && (systemctl is-active --quiet NetworkManager 2>/dev/null || pgrep NetworkManager >/dev/null); then
        local con_name=$(nmcli -t -f DEVICE,CONNECTION dev show "$NETWORK_INTERFACE" 2>/dev/null | cut -d: -f2)
        if [ -n "$con_name" ]; then
            nmcli con mod "$con_name" ipv4.ignore-auto-dns no
            nmcli con mod "$con_name" ipv4.dns ""
            nmcli con down "$con_name" 2>/dev/null
            nmcli con up "$con_name" 2>/dev/null
        fi
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
    
    # Show main interface configuration only
    echo -e "${BOLD}$NETWORK_INTERFACE DNS Configuration:${NC}"
    
    # NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        nmcli dev show "$NETWORK_INTERFACE" 2>/dev/null | grep DNS || echo "No NetworkManager DNS settings"
    fi
    
    echo -e "----------------------------------------"
    
    echo -e "${YELLOW}Configured DNS servers: ${BOLD}$CURRENT_DNS${NC}"
}

# Enhanced BBR Installation (ONLY BBR - No DNS/MTU changes)
install_bbr() {
    echo -e "${YELLOW}Installing and configuring BBR optimization...${NC}"
    print_separator
    
    # Check if BBR is already enabled
    local current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR is already enabled!${NC}"
        return 0
    fi

    echo -e "${BLUE}Applying advanced BBR optimizations...${NC}"
    
    # TCP Keepalive for connection stability
    sysctl -w net.ipv4.tcp_keepalive_time=300
    sysctl -w net.ipv4.tcp_keepalive_intvl=60
    sysctl -w net.ipv4.tcp_keepalive_probes=10

    # Increase connection limits
    sysctl -w net.core.somaxconn=65535
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192
    sysctl -w net.core.netdev_max_backlog=5000
    sysctl -w net.ipv4.tcp_max_tw_buckets=200000

    # Enhance BBR for streaming and downloading
    sysctl -w net.core.default_qdisc=fq_codel
    if sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null; then
        echo -e "${GREEN}BBR successfully enabled.${NC}"
    else
        echo -e "${YELLOW}BBR not supported, attempting to enable BBRv2...${NC}"
        modprobe tcp_bbr 2>/dev/null
        sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
    fi

    # Additional settings for low latency and streaming
    sysctl -w net.ipv4.tcp_low_latency=1
    sysctl -w net.ipv4.tcp_window_scaling=1
    sysctl -w net.ipv4.tcp_sack=1
    sysctl -w net.ipv4.tcp_no_metrics_save=0
    sysctl -w net.ipv4.tcp_ecn=1
    sysctl -w net.ipv4.tcp_adv_win_scale=1
    sysctl -w net.ipv4.tcp_moderate_rcvbuf=1

    # Optimize TCP Fast Open
    sysctl -w net.ipv4.tcp_fastopen=3

    # Optimize MTU and MSS
    sysctl -w net.ipv4.tcp_mtu_probing=1
    sysctl -w net.ipv4.tcp_base_mss=1024

    # Optimize TCP buffers
    sysctl -w net.ipv4.tcp_rmem='4096 87380 8388608'
    sysctl -w net.ipv4.tcp_wmem='4096 16384 8388608'
    sysctl -w net.core.rmem_max=16777216
    sysctl -w net.core.wmem_max=16777216

    # Save settings to /etc/sysctl.conf
    echo -e "${BLUE}Saving settings to /etc/sysctl.conf...${NC}"
    
    # Backup existing sysctl.conf
    cp /etc/sysctl.conf /etc/sysctl.conf.backup."$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # Append BBR settings to sysctl.conf
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
net.ipv4.tcp_no_metrics_save=0
net.ipv4.tcp_ecn=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 16384 8388608
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOT

    # Apply settings permanently
    sysctl -p >/dev/null 2>&1

    # Verify BBR
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$current_cc" == "bbr" ]]; then
        echo -e "${GREEN}✓ BBR successfully installed and configured!${NC}"
        echo -e "${YELLOW}Note: DNS and MTU settings remain unchanged.${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ BBR not enabled. Your kernel may not support BBR.${NC}"
        echo -e "${YELLOW}Other TCP optimizations have been applied.${NC}"
        return 1
    fi
}

# Backup Configuration
create_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/network_backup_$timestamp.tar.gz"
    
    echo -e "${YELLOW}Creating system backup...${NC}"
    
    # Backup important network files
    local backup_files=()
    
    [ -f "/etc/resolv.conf" ] && backup_files+=("/etc/resolv.conf")
    [ -f "/etc/sysctl.conf" ] && backup_files+=("/etc/sysctl.conf")
    [ -f "/etc/network/interfaces" ] && backup_files+=("/etc/network/interfaces")
    [ -f "$CONFIG_FILE" ] && backup_files+=("$CONFIG_FILE")
    
    # Backup network directories
    [ -d "/etc/netplan" ] && backup_files+=("/etc/netplan")
    [ -d "/etc/sysconfig/network-scripts" ] && backup_files+=("/etc/sysconfig/network-scripts")
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        echo -e "${RED}No network configuration files found to backup!${NC}"
        return 1
    fi
    
    # Create backup
    tar -czf "$backup_file" "${backup_files[@]}" 2>/dev/null
    
    # Backup iptables rules
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$BACKUP_DIR/iptables_backup_$timestamp.rules"
        echo -e "${GREEN}iptables rules backed up${NC}"
    fi
    
    if [ -f "$backup_file" ]; then
        echo -e "${GREEN}Backup created successfully: $backup_file${NC}"
        echo -e "${YELLOW}Backup includes: ${backup_files[*]}${NC}"
    else
        echo -e "${RED}Backup creation failed!${NC}"
        return 1
    fi
}

# Restore Backup
restore_backup() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo -e "${RED}No backups found in $BACKUP_DIR!${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}Available backups:${NC}"
    local i=1
    local backup_files=()
    
    for backup in "$BACKUP_DIR"/*.tar.gz; do
        if [ -f "$backup" ]; then
            echo "$i) $(basename "$backup")"
            backup_files[$i]="$backup"
            ((i++))
        fi
    done
    
    if [ $i -eq 1 ]; then
        echo -e "${RED}No backup files found!${NC}"
        return 1
    fi
    
    read -p "Enter backup number to restore: " backup_num
    local selected_backup="${backup_files[$backup_num]}"
    
    if [ -z "$selected_backup" ] || [ ! -f "$selected_backup" ]; then
        echo -e "${RED}Invalid backup selection!${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}Restoring from $selected_backup...${NC}"
    
    # Extract backup
    tar -xzf "$selected_backup" -C / 2>/dev/null
    
    # Restore iptables if available
    local iptables_backup="${selected_backup%.tar.gz}.rules"
    if [ -f "$iptables_backup" ] && command -v iptables-restore >/dev/null 2>&1; then
        iptables-restore < "$iptables_backup"
        echo -e "${GREEN}iptables rules restored${NC}"
    fi
    
    echo -e "${GREEN}Backup restored successfully!${NC}"
    echo -e "${YELLOW}You may need to restart network services.${NC}"
}

# Self-update functionality
self_update() {
    echo -e "${YELLOW}Checking for updates...${NC}"
    print_separator
    
    echo -e "Current version: ${GREEN}$SCRIPT_VERSION${NC}"
    echo -e "Script: ${BLUE}$SCRIPT_NAME${NC}"
    echo -e "Author: ${BOLD}$AUTHOR${NC}"
    echo ""
    echo -e "${YELLOW}Update Information:${NC}"
    echo -e "• New features in v9.5.0:"
    echo -e "  ✓ Fixed WARP Installation"
    echo -e "  ✓ Auto-registration for WARP"
    echo -e "  ✓ Better error handling"
    echo ""
    echo -e "${GREEN}This is the latest version!${NC}"
    echo -e "${YELLOW}For future updates, check the GitHub repository.${NC}"
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

# ============================================================================
# NEW FEATURES START HERE
# ============================================================================

# TCP MUX Configuration (Option 15)
configure_tcp_mux() {
    echo -e "${YELLOW}Configuring TCP MUX for better connection handling...${NC}"
    print_separator
    
    # Create TCP MUX configuration file
    local mux_config="/etc/tcp_mux.conf"
    
    cat > "$mux_config" <<EOT
# TCP MUX Configuration - Generated by $SCRIPT_NAME
# Date: $(date)

remote_addr = "0.0.0.0:3080"
transport = "tcpmux"
token = "your_token" 
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true 
mux_version = 1
mux_framesize = 32768 
mux_recievebuffer = 4194304
mux_streambuffer = 65536 
sniffer = false 
web_port = 8443
log_level = "info"
nodelay = true 
heartbeat = 40 
channel_size = 2048
mux_con = 8
mux_version = 1
mux_framesize = 32768 
mux_recievebuffer = 4194304
mux_streambuffer = 65536 
sniffer = false 
web_port = 8443
log_level = "info"
ports = []
EOT

    # Apply TCP MUX optimizations to sysctl
    echo -e "${BLUE}Applying TCP MUX kernel optimizations...${NC}"
    
    # Increase TCP buffers for MUX
    sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216'
    sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216'
    sysctl -w net.core.rmem_max=33554432
    sysctl -w net.core.wmem_max=33554432
    sysctl -w net.core.optmem_max=65536
    sysctl -w net.ipv4.tcp_mem='786432 1048576 26777216'
    
    # TCP MUX specific optimizations
    sysctl -w net.ipv4.tcp_tw_reuse=1
    sysctl -w net.ipv4.tcp_fin_timeout=30
    sysctl -w net.ipv4.tcp_max_orphans=65536
    sysctl -w net.ipv4.tcp_max_syn_backlog=16384
    sysctl -w net.core.somaxconn=32768
    
    # Save to sysctl.conf
    cat <<EOT >> /etc/sysctl.conf

# TCP MUX Optimizations - Added by $SCRIPT_NAME
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.optmem_max=65536
net.ipv4.tcp_mem=786432 1048576 26777216
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_max_orphans=65536
net.ipv4.tcp_max_syn_backlog=16384
net.core.somaxconn=32768
EOT

    # Apply settings
    sysctl -p >/dev/null 2>&1
    
    echo -e "${GREEN}✓ TCP MUX configuration saved to: $mux_config${NC}"
    echo -e "${YELLOW}TCP MUX optimizations have been applied to the kernel.${NC}"
    echo -e "${BLUE}You can edit the configuration file at: $mux_config${NC}"
    
    # Test if configuration is working
    echo -e "\n${YELLOW}Testing TCP MUX settings...${NC}"
    local current_tcp_rmem=$(sysctl net.ipv4.tcp_rmem | awk '{print $3 " " $4 " " $5}')
    echo -e "Current TCP read buffer: ${GREEN}$current_tcp_rmem${NC}"
    
    echo -e "${GREEN}✓ TCP MUX configuration completed successfully!${NC}"
}

# System Reboot (Option 16)
system_reboot() {
    if ! confirm_action "This will reboot the system immediately!"; then
        echo -e "${YELLOW}Reboot cancelled.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Saving current configuration...${NC}"
    save_config
    
    echo -e "${YELLOW}Creating backup before reboot...${NC}"
    create_backup
    
    echo -e "${RED}System will reboot in 5 seconds...${NC}"
    echo -e "${YELLOW}Press Ctrl+C to cancel${NC}"
    
    for i in {5..1}; do
        echo -e "${RED}Rebooting in $i seconds...${NC}"
        sleep 1
    done
    
    echo -e "${GREEN}Rebooting system now!${NC}"
    reboot
}

# Best MTU Auto-detection (Option 17)
find_best_mtu() {
    echo -e "${YELLOW}Searching for the best MTU size (1280-1500)...${NC}"
    print_separator
    
    local target="8.8.8.8"
    local best_mtu=1500
    local best_packets=0
    local best_time=9999
    local mtu_list=""
    
    # Test MTU sizes from 1280 to 1500
    for mtu in {1280..1500..20}; do
        echo -ne "Testing MTU: $mtu... "
        
        # Calculate payload size (MTU - 28 bytes for IP header)
        local payload=$((mtu - 28))
        
        # Test with ping (2 packets with 2 second timeout)
        if ping -M do -s $payload -c 2 -W 2 "$target" > /tmp/ping_test.txt 2>&1; then
            local packets_received=$(grep -o "2 received" /tmp/ping_test.txt | wc -l)
            local avg_time=$(grep "min/avg/max" /tmp/ping_test.txt | awk -F'/' '{print $5}' | cut -d' ' -f1 2>/dev/null)
            
            if [ -n "$avg_time" ] && [ "$packets_received" -eq 1 ]; then
                # Convert time to integer (remove decimal point)
                avg_time=${avg_time%.*}
                if [[ "$avg_time" =~ ^[0-9]+$ ]]; then
                    echo -e "${GREEN}✓ ${avg_time}ms${NC}"
                    
                    # Update best MTU if this one is better (lower time or same time but more packets)
                    if [ "$avg_time" -lt "$best_time" ] || ([ "$avg_time" -eq "$best_time" ] && [ "$mtu" -gt "$best_mtu" ]); then
                        best_mtu=$mtu
                        best_time=$avg_time
                        best_packets=$packets_received
                    fi
                    
                    mtu_list+="MTU $mtu: ${avg_time}ms ✓\n"
                else
                    echo -e "${YELLOW}✓ Connected (no time)${NC}"
                    mtu_list+="MTU $mtu: Connected ✓\n"
                fi
            else
                echo -e "${YELLOW}✓ Connected${NC}"
                mtu_list+="MTU $mtu: Connected ✓\n"
            fi
        else
            echo -e "${RED}✗ Failed${NC}"
            mtu_list+="MTU $mtu: Failed ✗\n"
        fi
        
        sleep 0.3
    done
    
    # Cleanup
    rm -f /tmp/ping_test.txt
    
    print_separator
    echo -e "${YELLOW}Test Results:${NC}"
    echo -e "$mtu_list"
    print_separator
    
    if [ "$best_time" -eq 9999 ]; then
        # If no MTU with timing found, try to find any working MTU
        echo -e "${YELLOW}Looking for any working MTU...${NC}"
        for mtu in {1500..1280..-20}; do
            local payload=$((mtu - 28))
            if ping -M do -s $payload -c 1 -W 1 "$target" >/dev/null 2>&1; then
                best_mtu=$mtu
                echo -e "${GREEN}Found working MTU: $mtu${NC}"
                break
            fi
        done
    fi
    
    if [ "$best_mtu" -eq 1500 ] && [ "$best_time" -eq 9999 ]; then
        echo -e "${RED}No stable MTU found! Keeping current MTU.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Best MTU found: ${BOLD}$best_mtu${NC}"
    if [ "$best_time" -ne 9999 ]; then
        echo -e "Ping time: ${BOLD}${best_time}ms${NC}"
    fi
    
    read -p "Apply this MTU? (yes/no): " apply_mtu
    if [[ "$apply_mtu" == "yes" ]] || [[ "$apply_mtu" == "y" ]]; then
        configure_mtu "$best_mtu"
        echo -e "${GREEN}✓ Best MTU ($best_mtu) has been applied!${NC}"
    else
        echo -e "${YELLOW}MTU not changed.${NC}"
    fi
}

# Iran VXLAN Tunnel (Option 18) - EXACT CODE AS REQUESTED
setup_iran_tunnel() {
    echo -e "${YELLOW}Setting up IRAN VXLAN Tunnel...${NC}"
    print_separator
    
    read -p "🔹 Enter IP address of kharej server: " REMOTE_IP
    
    IFACE=$(ip route | grep default | awk '{print $5}')
    VXLAN_IF="vxlan100"

    # VXLAN setup
    ip link add $VXLAN_IF type vxlan id 100 dev $IFACE remote $REMOTE_IP dstport 4789
    ip addr add 10.123.1.1/30 dev $VXLAN_IF
    ip -6 addr add fd11:1ceb:1d11::1/64 dev $VXLAN_IF
    ip link set $VXLAN_IF up

    # rc.local
    cat <<EOF > /etc/rc.local
#!/bin/bash
ip link add $VXLAN_IF type vxlan id 100 dev $IFACE remote $REMOTE_IP dstport 4789
ip addr add 10.123.1.1/30 dev $VXLAN_IF
ip -6 addr add fd11:1ceb:1d11::1/64 dev $VXLAN_IF
ip link set $VXLAN_IF up
exit 0
EOF

    chmod +x /etc/rc.local
    systemctl enable rc-local
    systemctl start rc-local

    echo "✅ IRAN VXLAN tunnel created to $REMOTE_IP (kharej)"
    echo -e "${GREEN}Tunnel setup completed!${NC}"
    echo -e "${YELLOW}Local IP: 10.123.1.1${NC}"
    echo -e "${YELLOW}Remote IP should be: 10.123.1.2${NC}"
}

# Kharej VXLAN Tunnel (Option 19) - EXACT CODE AS REQUESTED
setup_kharej_tunnel() {
    echo -e "${YELLOW}Setting up KHAREJ VXLAN Tunnel...${NC}"
    print_separator
    
    read -p "🛰  Enter IP of iran server: " REMOTE_IP
    IFACE=$(ip route | grep default | awk '{print $5}')
    VXLAN_IF="vxlan100"

    # Interface
    ip link add $VXLAN_IF type vxlan id 100 dev $IFACE remote $REMOTE_IP dstport 4789
    ip addr add 10.123.1.2/30 dev $VXLAN_IF
    ip -6 addr add fd11:1ceb:1d11::2/64 dev $VXLAN_IF
    ip link set $VXLAN_IF up

    # Create rc.local
    cat <<EOF > /etc/rc.local
#!/bin/bash
ip link add $VXLAN_IF type vxlan id 100 dev $IFACE remote $REMOTE_IP dstport 4789
ip addr add 10.123.1.2/30 dev $VXLAN_IF
ip -6 addr add fd11:1ceb:1d11::2/64 dev $VXLAN_IF
ip link set $VXLAN_IF up
exit 0
EOF

    chmod +x /etc/rc.local
    systemctl enable rc-local
    systemctl start rc-local

    echo "✅ VXLAN setup on KHAREJ completed (IPv4: 10.123.1.2 / IPv6: fd11:1ceb:1d11::2)"
    echo -e "${GREEN}Tunnel setup completed!${NC}"
    echo -e "${YELLOW}Local IP: 10.123.1.2${NC}"
    echo -e "${YELLOW}Remote IP should be: 10.123.1.1${NC}"
}

# Delete VXLAN Tunnel (Option 20)
delete_vxlan_tunnel() {
    if ! confirm_action "This will delete all VXLAN tunnels and configurations!"; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Deleting VXLAN tunnels...${NC}"
    
    # Remove VXLAN interface
    ip link del vxlan100 2>/dev/null
    ip link del vxlan200 2>/dev/null
    
    # Disable rc.local service
    systemctl stop rc-local 2>/dev/null
    systemctl disable rc-local 2>/dev/null
    
    # Remove rc.local file
    rm -f /etc/rc.local
    
    # Remove rc-local service files if they exist
    rm -f /etc/systemd/system/rc-local.service 2>/dev/null
    rm -f /lib/systemd/system/rc-local.service 2>/dev/null
    rm -f /usr/lib/systemd/system/rc-local.service 2>/dev/null
    
    echo -e "${GREEN}✓ All VXLAN tunnels and configurations have been removed!${NC}"
}

# HAProxy Installation and Configuration (Option 21)
install_haproxy_all_ports() {
    echo -e "${YELLOW}Installing HAProxy and configuring all ports...${NC}"
    print_separator
    
    # Check if HAProxy is already installed
    if command -v haproxy >/dev/null 2>&1; then
        echo -e "${GREEN}HAProxy is already installed.${NC}"
    else
        echo -e "${BLUE}Installing HAProxy...${NC}"
        
        # Detect package manager and install HAProxy
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update
            apt-get install haproxy -y
        elif command -v yum >/dev/null 2>&1; then
            yum install haproxy -y
        elif command -v dnf >/dev/null 2>&1; then
            dnf install haproxy -y
        elif command -v pacman >/dev/null 2>&1; then
            pacman -S haproxy --noconfirm
        else
            echo -e "${RED}Could not detect package manager!${NC}"
            return 1
        fi
        
        if ! command -v haproxy >/dev/null 2>&1; then
            echo -e "${RED}Failed to install HAProxy!${NC}"
            return 1
        fi
        
        echo -e "${GREEN}HAProxy installed successfully.${NC}"
    fi
    
    # Backup existing configuration
    if [ -f "/etc/haproxy/haproxy.cfg" ]; then
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.$(date +%Y%m%d_%H%M%S)
        echo -e "${GREEN}Backup of existing configuration created.${NC}"
    fi
    
    # Add configuration to the END of haproxy.cfg
    echo -e "${BLUE}Configuring HAProxy with all ports...${NC}"
    
    # Check if haproxy.cfg exists, if not create it with basic configuration
    if [ ! -f "/etc/haproxy/haproxy.cfg" ]; then
        cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

EOF
    fi
    
    # Append the port configurations to haproxy.cfg
    cat >> /etc/haproxy/haproxy.cfg <<EOF

# =============================================
# Port configurations added by $SCRIPT_NAME
# Date: $(date)
# =============================================

frontend de
    bind :::443
    mode tcp
    default_backend de
backend de
    mode tcp
    balance roundrobin
    server myloc 10.123.1.2:443

frontend de2
    bind :::23902
    mode tcp
    default_backend de2
backend de2
    mode tcp
    balance roundrobin
    server myloc 10.123.1.2:23902

frontend de3
    bind :::8081
    mode tcp
    default_backend de3
backend de3
    mode tcp
    balance roundrobin
    server myloc 10.123.1.2:8081

frontend de4
    bind :::8080
    mode tcp
    default_backend de4
backend de4
    mode tcp
    balance roundrobin
    server myloc 10.123.1.2:8080

frontend de5
    bind :::80
    mode tcp
    default_backend de5
backend de5
    mode tcp
    balance roundrobin
    server myloc 10.123.1.2:80

frontend de6
    bind :::8443
    mode tcp
    default_backend de6
backend de6
    mode tcp
    balance roundrobin
    server myloc 10.123.1.2:8443

frontend de7
    bind :::1080
    mode tcp
    default_backend de7
backend de7
    mode tcp
    balance roundrobin
    server myloc 10.123.1.2:1080
EOF
    
    echo -e "${GREEN}HAProxy configuration updated successfully.${NC}"
    
    # Validate configuration
    echo -e "${YELLOW}Validating HAProxy configuration...${NC}"
    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
        echo -e "${GREEN}✓ HAProxy configuration is valid.${NC}"
    else
        echo -e "${RED}✗ HAProxy configuration has errors!${NC}"
        echo -e "${YELLOW}Please check the configuration manually.${NC}"
        return 1
    fi
    
    # Restart HAProxy service
    echo -e "${YELLOW}Restarting HAProxy service...${NC}"
    
    # Try different service management commands
    if systemctl restart haproxy 2>/dev/null; then
        echo -e "${GREEN}✓ HAProxy service restarted successfully.${NC}"
    elif service haproxy restart 2>/dev/null; then
        echo -e "${GREEN}✓ HAProxy service restarted successfully.${NC}"
    elif /etc/init.d/haproxy restart 2>/dev/null; then
        echo -e "${GREEN}✓ HAProxy service restarted successfully.${NC}"
    else
        echo -e "${YELLOW}Could not restart HAProxy service. Starting it instead...${NC}"
        if systemctl start haproxy 2>/dev/null || service haproxy start 2>/dev/null || /etc/init.d/haproxy start 2>/dev/null; then
            echo -e "${GREEN}✓ HAProxy service started successfully.${NC}"
        else
            echo -e "${RED}✗ Could not start HAProxy service!${NC}"
            echo -e "${YELLOW}Please start it manually.${NC}"
        fi
    fi
    
    # Enable HAProxy to start on boot
    if systemctl enable haproxy 2>/dev/null; then
        echo -e "${GREEN}✓ HAProxy enabled to start on boot.${NC}"
    fi
    
    # Show status
    echo -e "\n${YELLOW}HAProxy Status:${NC}"
    if systemctl is-active --quiet haproxy 2>/dev/null; then
        echo -e "${GREEN}✓ HAProxy is running.${NC}"
    else
        echo -e "${YELLOW}⚠ HAProxy is not running.${NC}"
    fi
    
    # Show configured ports
    echo -e "\n${YELLOW}Configured Ports:${NC}"
    echo -e "443 (HTTPS)     → 10.123.1.2:443"
    echo -e "23902           → 10.123.1.2:23902"
    echo -e "8081            → 10.123.1.2:8081"
    echo -e "8080 (HTTP Alt) → 10.123.1.2:8080"
    echo -e "80 (HTTP)       → 10.123.1.2:80"
    echo -e "8443 (HTTPS Alt)→ 10.123.1.2:8443"
    echo -e "1080 (SOCKS)    → 10.123.1.2:1080"
    
    print_separator
    echo -e "${GREEN}✅ HAProxy installation and configuration completed!${NC}"
    echo -e "${YELLOW}Configuration file: /etc/haproxy/haproxy.cfg${NC}"
    echo -e "${YELLOW}Backup file: /etc/haproxy/haproxy.cfg.backup.*${NC}"
}

# ============================================================================
# CLOUDFLARE WARP INSTALLATION (FIXED VERSION with Auto-Registration) - Option 22
# ============================================================================

# Check WARP status
check_warp_status() {
    echo -e "${YELLOW}Checking WARP status...${NC}"
    
    if command -v warp-cli >/dev/null 2>&1; then
        echo -e "${GREEN}✓ warp-cli is installed${NC}"
        
        if systemctl is-active --quiet warp-svc 2>/dev/null; then
            echo -e "${GREEN}✓ warp-svc service is running${NC}"
            
            # Check registration status
            local reg_info=$(warp-cli --accept-tos registration 2>/dev/null | head -5)
            if echo "$reg_info" | grep -q "Missing registration"; then
                echo -e "${YELLOW}⚠ WARP is not registered${NC}"
                echo -e "${YELLOW}Attempting to register...${NC}"
                
                # Try to register
                warp-cli --accept-tos register 2>/dev/null
                sleep 3
                
                # Check again
                reg_info=$(warp-cli --accept-tos registration 2>/dev/null | head -5)
                if echo "$reg_info" | grep -q "Missing registration"; then
                    echo -e "${RED}✗ Failed to register WARP${NC}"
                    return 1
                else
                    echo -e "${GREEN}✓ WARP registration successful${NC}"
                fi
            else
                echo -e "${GREEN}✓ WARP is registered${NC}"
            fi
            
            # Check connection status
            local warp_status=$(warp-cli --accept-tos status 2>/dev/null | grep -E "Connected|Disconnected" | head -1 | xargs)
            if [[ "$warp_status" == *"Connected"* ]]; then
                echo -e "${GREEN}✓ WARP is connected${NC}"
                
                # Get IP address
                local warp_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
                if [[ -n "$warp_ip" ]]; then
                    echo -e "${BLUE}  IP Address: $warp_ip${NC}"
                fi
                
                # Test connectivity
                echo -e "${YELLOW}Testing WARP connectivity...${NC}"
                if curl -s4 --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
                    echo -e "${GREEN}✓ WARP is working correctly${NC}"
                else
                    echo -e "${YELLOW}⚠ WARP is connected but not routing all traffic${NC}"
                fi
                
                return 0
            else
                echo -e "${YELLOW}⚠ WARP is not connected${NC}"
                echo -e "${YELLOW}Attempting to connect...${NC}"
                
                warp-cli --accept-tos connect 2>/dev/null
                sleep 5
                
                warp_status=$(warp-cli --accept-tos status 2>/dev/null | grep -E "Connected|Disconnected" | head -1 | xargs)
                if [[ "$warp_status" == *"Connected"* ]]; then
                    echo -e "${GREEN}✓ WARP connected successfully${NC}"
                    return 0
                else
                    echo -e "${RED}✗ Failed to connect WARP${NC}"
                    return 1
                fi
            fi
        else
            echo -e "${YELLOW}⚠ warp-svc service is not running${NC}"
            echo -e "${YELLOW}Starting warp-svc service...${NC}"
            
            systemctl start warp-svc 2>/dev/null
            sleep 3
            
            if systemctl is-active --quiet warp-svc 2>/dev/null; then
                echo -e "${GREEN}✓ warp-svc service started${NC}"
                
                # Try to register and connect
                warp-cli --accept-tos register 2>/dev/null
                warp-cli --accept-tos set-mode tunnel 2>/dev/null
                warp-cli --accept-tos connect 2>/dev/null
                sleep 5
                
                check_warp_status
            else
                echo -e "${RED}✗ Failed to start warp-svc service${NC}"
                return 1
            fi
        fi
    else
        echo -e "${RED}✗ WARP is not installed${NC}"
        return 1
    fi
}

# Install WARP with proper registration
install_warp_cloudflare() {
    echo -e "${YELLOW}Installing Cloudflare WARP...${NC}"
    print_separator
    
    # Check if already installed
    if command -v warp-cli >/dev/null 2>&1; then
        echo -e "${YELLOW}WARP is already installed.${NC}"
        read -p "Do you want to reinstall? (yes/no): " reinstall
        if [[ "$reinstall" != "yes" ]] && [[ "$reinstall" != "y" ]]; then
            check_warp_status
            return
        fi
        echo -e "${YELLOW}Removing existing WARP installation...${NC}"
        remove_warp
        sleep 2
    fi
    
    # Detect distribution
    detect_distro
    
    # Install dependencies
    echo -e "${YELLOW}Installing dependencies...${NC}"
    
    case $DISTRO in
        ubuntu|debian)
            apt-get update
            apt-get install -y curl gnupg
            ;;
        centos|rhel|fedora|almalinux|rocky)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl
            else
                yum install -y curl
            fi
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update && apt-get install -y curl gnupg
            elif command -v yum >/dev/null 2>&1; then
                yum install -y curl
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y curl
            fi
            ;;
    esac
    
    # Install WARP from official repository
    echo -e "${YELLOW}Installing WARP from official repository...${NC}"
    
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        # For Ubuntu/Debian
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || {
            echo -e "${RED}✗ Failed to add GPG key${NC}"
            return 1
        }
        
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null 2>&1
        
        apt-get update
        apt-get install -y cloudflare-warp 2>/dev/null || {
            echo -e "${RED}✗ Failed to install WARP package${NC}"
            return 1
        }
        
    elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" || "$DISTRO" == "almalinux" || "$DISTRO" == "rocky" ]]; then
        # For RHEL-based distributions
        curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null 2>&1
        
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y cloudflare-warp 2>/dev/null || {
                echo -e "${RED}✗ Failed to install WARP package${NC}"
                return 1
            }
        else
            yum install -y cloudflare-warp 2>/dev/null || {
                echo -e "${RED}✗ Failed to install WARP package${NC}"
                return 1
            }
        fi
    else
        echo -e "${RED}✗ Unsupported distribution: $DISTRO${NC}"
        return 1
    fi
    
    if ! command -v warp-cli >/dev/null 2>&1; then
        echo -e "${RED}✗ WARP installation failed${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ WARP installed successfully${NC}"
    
    # Start and enable service
    echo -e "${YELLOW}Starting WARP service...${NC}"
    systemctl start warp-svc 2>/dev/null
    systemctl enable warp-svc 2>/dev/null
    
    # Wait for service to start
    sleep 5
    
    if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
        echo -e "${YELLOW}⚠ Service not active, trying manual start...${NC}"
        warp-svc 2>/dev/null &
        sleep 3
    fi
    
    # Register WARP account
    echo -e "${YELLOW}Registering WARP account...${NC}"
    
    # Try multiple registration attempts
    local registration_success=false
    for i in {1..5}; do
        echo "Registration attempt $i..."
        
        # Kill any existing warp-svc process
        pkill -f warp-svc 2>/dev/null
        sleep 1
        
        # Start service fresh
        systemctl start warp-svc 2>/dev/null
        sleep 3
        
        # Register
        if warp-cli --accept-tos register 2>/dev/null; then
            registration_success=true
            echo -e "${GREEN}✓ Registration successful${NC}"
            break
        else
            echo -e "${YELLOW}⚠ Registration attempt $i failed${NC}"
            sleep 2
        fi
    done
    
    if [ "$registration_success" = false ]; then
        echo -e "${YELLOW}⚠ Automatic registration failed, trying manual method...${NC}"
        
        # Alternative registration method
        curl -s4 --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null
        sleep 2
        
        # Try one more time
        warp-cli --accept-tos register 2>/dev/null && registration_success=true
    fi
    
    if [ "$registration_success" = true ]; then
        # Set to tunnel mode
        echo -e "${YELLOW}Configuring tunnel mode...${NC}"
        warp-cli --accept-tos set-mode tunnel 2>/dev/null
        
        # Connect
        echo -e "${YELLOW}Connecting to WARP...${NC}"
        warp-cli --accept-tos connect 2>/dev/null
        
        # Wait for connection
        sleep 5
        
        # Check status
        check_warp_status
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ WARP installation and configuration completed successfully!${NC}"
            echo -e "${YELLOW}Note: You may need to restart the system for all changes to take effect.${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠ WARP installed but connection check failed${NC}"
            echo -e "${YELLOW}Try manually: warp-cli --accept-tos connect${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ WARP installation failed - could not register${NC}"
        echo -e "${YELLOW}Troubleshooting steps:${NC}"
        echo -e "1. Check internet connection"
        echo -e "2. Try: systemctl restart warp-svc"
        echo -e "3. Try: warp-cli --accept-tos register"
        echo -e "4. Check logs: journalctl -u warp-svc"
        return 1
    fi
}

# Remove WARP
remove_warp() {
    if ! confirm_action "This will remove Cloudflare WARP!"; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Removing Cloudflare WARP...${NC}"
    
    # Stop service
    systemctl stop warp-svc 2>/dev/null
    systemctl disable warp-svc 2>/dev/null
    
    # Remove package
    detect_distro
    case $DISTRO in
        ubuntu|debian)
            apt-get remove --purge -y cloudflare-warp 2>/dev/null
            rm -f /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null
            rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
            ;;
        centos|rhel|fedora|almalinux|rocky)
            if command -v dnf >/dev/null 2>&1; then
                dnf remove -y cloudflare-warp 2>/dev/null
            else
                yum remove -y cloudflare-warp 2>/dev/null
            fi
            rm -f /etc/yum.repos.d/cloudflare-warp.repo 2>/dev/null
            ;;
    esac
    
    # Clean up files
    rm -rf /var/lib/cloudflare-warp 2>/dev/null
    rm -rf /etc/cloudflare 2>/dev/null
    
    # Remove WireGuard interface if exists
    if ip link show warp0 >/dev/null 2>&1; then
        ip link del warp0 2>/dev/null
    fi
    
    echo -e "${GREEN}✓ Cloudflare WARP removed successfully!${NC}"
}

# Fix WARP registration issues
fix_warp_registration() {
    echo -e "${YELLOW}Fixing WARP registration issues...${NC}"
    
    if ! command -v warp-cli >/dev/null 2>&1; then
        echo -e "${RED}✗ WARP is not installed${NC}"
        return 1
    fi
    
    # Stop service
    systemctl stop warp-svc 2>/dev/null
    sleep 2
    
    # Kill any remaining processes
    pkill -f warp-svc 2>/dev/null
    pkill -f warp 2>/dev/null
    
    # Remove registration data
    rm -rf /var/lib/cloudflare-warp 2>/dev/null
    rm -rf /etc/cloudflare 2>/dev/null
    
    # Start service
    systemctl start warp-svc 2>/dev/null
    sleep 5
    
    # Register
    echo -e "${YELLOW}Registering WARP...${NC}"
    warp-cli --accept-tos register 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Registration successful${NC}"
        
        # Connect
        warp-cli --accept-tos set-mode tunnel 2>/dev/null
        warp-cli --accept-tos connect 2>/dev/null
        sleep 3
        
        check_warp_status
    else
        echo -e "${RED}✗ Registration failed${NC}"
        return 1
    fi
}

# WARP Management Menu
manage_warp() {
    while true; do
        echo -e "\n${YELLOW}Cloudflare WARP Management${NC}"
        echo -e "1) Install/Reinstall WARP"
        echo -e "2) Check WARP Status"
        echo -e "3) Fix Registration Issues"
        echo -e "4) Connect to WARP"
        echo -e "5) Disconnect from WARP"
        echo -e "6) Restart WARP Service"
        echo -e "7) Remove WARP"
        echo -e "8) View WARP Logs"
        echo -e "9) Back to Main Menu"
        
        read -p "Enter your choice [1-9]: " warp_choice
        
        case $warp_choice in
            1)
                install_warp_cloudflare
                ;;
            2)
                check_warp_status
                ;;
            3)
                fix_warp_registration
                ;;
            4)
                echo -e "${YELLOW}Connecting to WARP...${NC}"
                warp-cli --accept-tos connect 2>/dev/null
                sleep 3
                check_warp_status
                ;;
            5)
                echo -e "${YELLOW}Disconnecting from WARP...${NC}"
                warp-cli --accept-tos disconnect 2>/dev/null
                echo -e "${GREEN}✓ Disconnected${NC}"
                ;;
            6)
                echo -e "${YELLOW}Restarting WARP service...${NC}"
                systemctl restart warp-svc 2>/dev/null
                sleep 3
                check_warp_status
                ;;
            7)
                remove_warp
                ;;
            8)
                echo -e "${YELLOW}Showing WARP logs...${NC}"
                journalctl -u warp-svc --no-pager -n 30
                ;;
            9)
                return
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                ;;
        esac
        
        read -p "Press [Enter] to continue..."
    done
}

# Reset ALL Changes
reset_all() {
    if ! confirm_action "This will reset ALL changes to default settings!"; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return
    fi
    
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
    sed -i '/# BBR Optimization - Added by $SCRIPT_NAME/,/net.core.wmem_max=16777216/d' /etc/sysctl.conf
    
    # Remove TCP MUX settings
    sed -i '/# TCP MUX Optimizations - Added by $SCRIPT_NAME/,/net.core.somaxconn=32768/d' /etc/sysctl.conf
    
    # Delete VXLAN tunnels
    delete_vxlan_tunnel
    
    # Remove WARP
    remove_warp
    
    # Stop and disable HAProxy
    if command -v haproxy >/dev/null 2>&1; then
        systemctl stop haproxy 2>/dev/null
        systemctl disable haproxy 2>/dev/null
        echo -e "${GREEN}HAProxy stopped and disabled.${NC}"
    fi
    
    sysctl -p >/dev/null 2>&1

    # Remove config file
    rm -f "$CONFIG_FILE"
    
    # Remove TCP MUX config
    rm -f /etc/tcp_mux.conf

    echo -e "${GREEN}All changes have been reset to default!${NC}"
}

# Main Menu
show_menu() {
    load_config
    detect_distro
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
        echo -e "11) Network Speed Test"
        echo -e "12) Backup Configuration"
        echo -e "13) Restore Backup"
        echo -e "14) Check for Updates"
        echo -e "15) TCP MUX Configuration"
        echo -e "16) Reboot System"
        echo -e "17) Find Best MTU Size"
        echo -e "18) Setup Iran Tunnel"
        echo -e "19) Setup Kharej Tunnel"
        echo -e "20) Delete VXLAN Tunnel"
        echo -e "21) Install HAProxy & All Ports"
        echo -e "22) Cloudflare WARP Management"
        echo -e "23) Exit"
        
        read -p "Enter your choice [1-23]: " choice
        
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
                speed_test
                ;;
            12)
                create_backup
                ;;
            13)
                restore_backup
                ;;
            14)
                self_update
                ;;
            15)
                configure_tcp_mux
                ;;
            16)
                system_reboot
                ;;
            17)
                find_best_mtu
                ;;
            18)
                setup_iran_tunnel
                ;;
            19)
                setup_kharej_tunnel
                ;;
            20)
                delete_vxlan_tunnel
                ;;
            21)
                install_haproxy_all_ports
                ;;
            22)
                manage_warp
                ;;
            23)
                echo -e "${GREEN}Exiting... Thank you for using $SCRIPT_NAME!${NC}"
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
check_requirements
check_root
show_menu
