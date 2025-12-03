#!/bin/bash

# Global Configuration
SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="9.6"  # Fixed VXLAN reboot & Improved WARP routing
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
    if command -v warp-go >/dev/null 2>&1; then
        if systemctl is-active --quiet warp-go 2>/dev/null; then
            local warp_ipv4=$(curl -s4 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep warp | cut -d= -f2)
            local warp_ipv6=$(curl -s6 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep warp | cut -d= -f2)
            
            if [[ "$warp_ipv4" == "on" ]] || [[ "$warp_ipv4" == "plus" ]]; then
                echo -e "${YELLOW}Cloudflare WARP: ${GREEN}Active (IPv4)${NC}"
            elif [[ "$warp_ipv6" == "on" ]] || [[ "$warp_ipv6" == "plus" ]]; then
                echo -e "${YELLOW}Cloudflare WARP: ${GREEN}Active (IPv6)${NC}"
            else
                echo -e "${YELLOW}Cloudflare WARP: ${YELLOW}Installed (Not running)${NC}"
            fi
        else
            echo -e "${YELLOW}Cloudflare WARP: ${RED}Not running${NC}"
        fi
    fi
    
    # Show Fix DNS status
    if [ -f "/etc/systemd/resolved.conf.d/disable-resolved.conf" ]; then
        echo -e "${YELLOW}Fix DNS: ${GREEN}Applied${NC}"
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

# ============================================================================
# IMPORTANT: برطرف کردن مشکل تانل VXLAN پس از ریبوت (گزینه 18 و 19)
# ============================================================================

# Iran VXLAN Tunnel (گزینه 18) - کاملاً اصلاح شده برای بقا پس از ریبوت
setup_iran_tunnel() {
    echo -e "${YELLOW}Setting up IRAN VXLAN Tunnel (Persistent after reboot)...${NC}"
    print_separator
    
    read -p "🔹 Enter IP address of kharej server: " REMOTE_IP
    
    IFACE=$(ip route | grep default | awk '{print $5}')
    VXLAN_IF="vxlan100"
    VXLAN_ID="100"
    LOCAL_IP="10.123.1.1/30"
    LOCAL_IPV6="fd11:1ceb:1d11::1/64"
    
    # حذف تانل موجود اگر وجود دارد
    ip link del $VXLAN_IF 2>/dev/null
    
    # ایجاد تانل موقت
    ip link add $VXLAN_IF type vxlan id $VXLAN_ID dev $IFACE remote $REMOTE_IP dstport 4789
    ip addr add $LOCAL_IP dev $VXLAN_IF
    ip -6 addr add $LOCAL_IPV6 dev $VXLAN_IF
    ip link set $VXLAN_IF up mtu 1500
    
    # تست تانل
    echo -e "${YELLOW}Testing tunnel connectivity...${NC}"
    if ip addr show $VXLAN_IF | grep -q "10.123.1.1"; then
        echo -e "${GREEN}✓ Temporary tunnel created successfully${NC}"
    else
        echo -e "${RED}✗ Failed to create temporary tunnel${NC}"
        return 1
    fi
    
    # روش 1: استفاده از systemd-networkd (برای سیستم‌های مدرن)
    if command -v networkctl >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring with systemd-networkd...${NC}"
        
        # ایجاد configuration برای systemd-networkd
        mkdir -p /etc/systemd/network
        
        cat > /etc/systemd/network/10-vxlan-iran.netdev <<EOF
[NetDev]
Name=$VXLAN_IF
Kind=vxlan

[VXLAN]
VNI=$VXLAN_ID
Remote=$REMOTE_IP
Local=$(ip addr show $IFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
DestinationPort=4789
EOF
        
        cat > /etc/systemd/network/20-vxlan-iran.network <<EOF
[Match]
Name=$VXLAN_IF

[Network]
Address=$LOCAL_IP
Address=$LOCAL_IPV6
EOF
        
        # فعال‌سازی و راه‌اندازی
        systemctl enable systemd-networkd
        systemctl restart systemd-networkd
        
        echo -e "${GREEN}✓ systemd-networkd configuration created${NC}"
    
    # روش 2: استفاده از netplan (برای Ubuntu 18.04 به بعد)
    elif [ -d /etc/netplan ]; then
        echo -e "${YELLOW}Configuring with netplan...${NC}"
        
        # پیدا کردن فایل netplan
        NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -z "$NETPLAN_FILE" ]; then
            NETPLAN_FILE="/etc/netplan/01-network-manager-all.yaml"
        fi
        
        # پشتیبان‌گیری
        cp "$NETPLAN_FILE" "$NETPLAN_FILE.backup.$(date +%Y%m%d_%H%M%S)"
        
        # اضافه کردن configuration VXLAN
        cat > /etc/netplan/99-vxlan.yaml <<EOF
network:
  version: 2
  vlans:
    $VXLAN_IF:
      id: $VXLAN_ID
      link: $IFACE
      addresses:
        - $LOCAL_IP
        - $LOCAL_IPV6
      vxlan:
        remote: $REMOTE_IP
        port: 4789
EOF
        
        netplan generate
        netplan apply
        
        echo -e "${GREEN}✓ netplan configuration created${NC}"
    
    # روش 3: استفاده از network-scripts (برای CentOS/RHEL)
    elif [ -d /etc/sysconfig/network-scripts ]; then
        echo -e "${YELLOW}Configuring with network-scripts...${NC}"
        
        cat > /etc/sysconfig/network-scripts/ifcfg-$VXLAN_IF <<EOF
DEVICE=$VXLAN_IF
DEVICETYPE=vxlan
VXLAN_ID=$VXLAN_ID
VXLAN_LOCAL=$(ip addr show $IFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
VXLAN_REMOTE=$REMOTE_IP
VXLAN_PORT=4789
ONBOOT=yes
BOOTPROTO=none
TYPE=VXLAN
IPADDR=10.123.1.1
PREFIX=30
IPV6INIT=yes
IPV6ADDR=$LOCAL_IPV6
IPV6_AUTOCONF=no
EOF
        
        systemctl restart network
        echo -e "${GREEN}✓ network-scripts configuration created${NC}"
    
    # روش 4: استفاده از systemd service (آخرین راه‌حل)
    else
        echo -e "${YELLOW}Configuring with systemd service...${NC}"
        
        # ایجاد اسکریپت راه‌اندازی
        cat > /usr/local/bin/setup-vxlan-iran.sh <<EOF
#!/bin/bash
# Setup VXLAN Iran Tunnel
IFACE=$IFACE
VXLAN_IF=$VXLAN_IF
REMOTE_IP=$REMOTE_IP

# Wait for network
sleep 5

# Delete existing interface
ip link del \$VXLAN_IF 2>/dev/null

# Create VXLAN
ip link add \$VXLAN_IF type vxlan id 100 dev \$IFACE remote \$REMOTE_IP dstport 4789
ip addr add 10.123.1.1/30 dev \$VXLAN_IF
ip -6 addr add fd11:1ceb:1d11::1/64 dev \$VXLAN_IF
ip link set \$VXLAN_IF up mtu 1500

# Add routes if needed
ip route add 10.123.1.0/30 dev \$VXLAN_IF 2>/dev/null
EOF
        
        chmod +x /usr/local/bin/setup-vxlan-iran.sh
        
        # ایجاد سرویس systemd
        cat > /etc/systemd/system/vxlan-iran.service <<EOF
[Unit]
Description=VXLAN Iran Tunnel
After=network.target network-online.target
Wants=network-online.target
Requires=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-vxlan-iran.sh
ExecStop=/bin/bash -c "ip link del $VXLAN_IF 2>/dev/null || true"
User=root
Restart=no

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable vxlan-iran.service
        systemctl start vxlan-iran.service
        
        echo -e "${GREEN}✓ systemd service created${NC}"
    fi
    
    # ایجاد cron job برای بررسی تانل
    echo -e "${YELLOW}Creating health check cron job...${NC}"
    
    cat > /usr/local/bin/check-vxlan.sh <<EOF
#!/bin/bash
# VXLAN Health Check
if ! ip link show vxlan100 >/dev/null 2>&1; then
    echo "\$(date): VXLAN tunnel is down, restarting..." >> /var/log/vxlan.log
    /usr/local/bin/setup-vxlan-iran.sh
fi
EOF
    
    chmod +x /usr/local/bin/check-vxlan.sh
    
    # اضافه کردن به crontab
    (crontab -l 2>/dev/null | grep -v "check-vxlan"; echo "*/5 * * * * /usr/local/bin/check-vxlan.sh") | crontab -
    
    print_separator
    echo -e "${GREEN}✅ IRAN VXLAN tunnel created successfully!${NC}"
    echo -e "${YELLOW}Tunnel Details:${NC}"
    echo -e "  Interface: $VXLAN_IF"
    echo -e "  Local IPv4: 10.123.1.1"
    echo -e "  Local IPv6: fd11:1ceb:1d11::1"
    echo -e "  Remote IP: $REMOTE_IP"
    echo -e "  VNI: $VXLAN_ID"
    echo -e "${YELLOW}Tunnel will survive reboot!${NC}"
}

# Kharej VXLAN Tunnel (گزینه 19) - کاملاً اصلاح شده برای بقا پس از ریبوت
setup_kharej_tunnel() {
    echo -e "${YELLOW}Setting up KHAREJ VXLAN Tunnel (Persistent after reboot)...${NC}"
    print_separator
    
    read -p "🛰  Enter IP of iran server: " REMOTE_IP
    IFACE=$(ip route | grep default | awk '{print $5}')
    VXLAN_IF="vxlan100"
    VXLAN_ID="100"
    LOCAL_IP="10.123.1.2/30"
    LOCAL_IPV6="fd11:1ceb:1d11::2/64"
    
    # حذف تانل موجود اگر وجود دارد
    ip link del $VXLAN_IF 2>/dev/null
    
    # ایجاد تانل موقت
    ip link add $VXLAN_IF type vxlan id $VXLAN_ID dev $IFACE remote $REMOTE_IP dstport 4789
    ip addr add $LOCAL_IP dev $VXLAN_IF
    ip -6 addr add $LOCAL_IPV6 dev $VXLAN_IF
    ip link set $VXLAN_IF up mtu 1500
    
    # تست تانل
    echo -e "${YELLOW}Testing tunnel connectivity...${NC}"
    if ip addr show $VXLAN_IF | grep -q "10.123.1.2"; then
        echo -e "${GREEN}✓ Temporary tunnel created successfully${NC}"
    else
        echo -e "${RED}✗ Failed to create temporary tunnel${NC}"
        return 1
    fi
    
    # روش 1: استفاده از systemd-networkd
    if command -v networkctl >/dev/null 2>&1; then
        echo -e "${YELLOW}Configuring with systemd-networkd...${NC}"
        
        mkdir -p /etc/systemd/network
        
        cat > /etc/systemd/network/10-vxlan-kharej.netdev <<EOF
[NetDev]
Name=$VXLAN_IF
Kind=vxlan

[VXLAN]
VNI=$VXLAN_ID
Remote=$REMOTE_IP
Local=$(ip addr show $IFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
DestinationPort=4789
EOF
        
        cat > /etc/systemd/network/20-vxlan-kharej.network <<EOF
[Match]
Name=$VXLAN_IF

[Network]
Address=$LOCAL_IP
Address=$LOCAL_IPV6
EOF
        
        systemctl enable systemd-networkd
        systemctl restart systemd-networkd
        
        echo -e "${GREEN}✓ systemd-networkd configuration created${NC}"
    
    # روش 2: استفاده از netplan
    elif [ -d /etc/netplan ]; then
        echo -e "${YELLOW}Configuring with netplan...${NC}"
        
        NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
        if [ -z "$NETPLAN_FILE" ]; then
            NETPLAN_FILE="/etc/netplan/01-network-manager-all.yaml"
        fi
        
        cp "$NETPLAN_FILE" "$NETPLAN_FILE.backup.$(date +%Y%m%d_%H%M%S)"
        
        cat > /etc/netplan/99-vxlan.yaml <<EOF
network:
  version: 2
  vlans:
    $VXLAN_IF:
      id: $VXLAN_ID
      link: $IFACE
      addresses:
        - $LOCAL_IP
        - $LOCAL_IPV6
      vxlan:
        remote: $REMOTE_IP
        port: 4789
EOF
        
        netplan generate
        netplan apply
        
        echo -e "${GREEN}✓ netplan configuration created${NC}"
    
    # روش 3: استفاده از network-scripts
    elif [ -d /etc/sysconfig/network-scripts ]; then
        echo -e "${YELLOW}Configuring with network-scripts...${NC}"
        
        cat > /etc/sysconfig/network-scripts/ifcfg-$VXLAN_IF <<EOF
DEVICE=$VXLAN_IF
DEVICETYPE=vxlan
VXLAN_ID=$VXLAN_ID
VXLAN_LOCAL=$(ip addr show $IFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)
VXLAN_REMOTE=$REMOTE_IP
VXLAN_PORT=4789
ONBOOT=yes
BOOTPROTO=none
TYPE=VXLAN
IPADDR=10.123.1.2
PREFIX=30
IPV6INIT=yes
IPV6ADDR=$LOCAL_IPV6
IPV6_AUTOCONF=no
EOF
        
        systemctl restart network
        echo -e "${GREEN}✓ network-scripts configuration created${NC}"
    
    # روش 4: استفاده از systemd service
    else
        echo -e "${YELLOW}Configuring with systemd service...${NC}"
        
        cat > /usr/local/bin/setup-vxlan-kharej.sh <<EOF
#!/bin/bash
# Setup VXLAN Kharej Tunnel
IFACE=$IFACE
VXLAN_IF=$VXLAN_IF
REMOTE_IP=$REMOTE_IP

# Wait for network
sleep 5

# Delete existing interface
ip link del \$VXLAN_IF 2>/dev/null

# Create VXLAN
ip link add \$VXLAN_IF type vxlan id 100 dev \$IFACE remote \$REMOTE_IP dstport 4789
ip addr add 10.123.1.2/30 dev \$VXLAN_IF
ip -6 addr add fd11:1ceb:1d11::2/64 dev \$VXLAN_IF
ip link set \$VXLAN_IF up mtu 1500

# Add routes if needed
ip route add 10.123.1.0/30 dev \$VXLAN_IF 2>/dev/null
EOF
        
        chmod +x /usr/local/bin/setup-vxlan-kharej.sh
        
        cat > /etc/systemd/system/vxlan-kharej.service <<EOF
[Unit]
Description=VXLAN Kharej Tunnel
After=network.target network-online.target
Wants=network-online.target
Requires=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-vxlan-kharej.sh
ExecStop=/bin/bash -c "ip link del $VXLAN_IF 2>/dev/null || true"
User=root
Restart=no

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable vxlan-kharej.service
        systemctl start vxlan-kharej.service
        
        echo -e "${GREEN}✓ systemd service created${NC}"
    fi
    
    # ایجاد cron job برای بررسی تانل
    echo -e "${YELLOW}Creating health check cron job...${NC}"
    
    cat > /usr/local/bin/check-vxlan.sh <<EOF
#!/bin/bash
# VXLAN Health Check
if ! ip link show vxlan100 >/dev/null 2>&1; then
    echo "\$(date): VXLAN tunnel is down, restarting..." >> /var/log/vxlan.log
    /usr/local/bin/setup-vxlan-kharej.sh
fi
EOF
    
    chmod +x /usr/local/bin/check-vxlan.sh
    
    (crontab -l 2>/dev/null | grep -v "check-vxlan"; echo "*/5 * * * * /usr/local/bin/check-vxlan.sh") | crontab -
    
    print_separator
    echo -e "${GREEN}✅ KHAREJ VXLAN tunnel created successfully!${NC}"
    echo -e "${YELLOW}Tunnel Details:${NC}"
    echo -e "  Interface: $VXLAN_IF"
    echo -e "  Local IPv4: 10.123.1.2"
    echo -e "  Local IPv6: fd11:1ceb:1d11::2"
    echo -e "  Remote IP: $REMOTE_IP"
    echo -e "  VNI: $VXLAN_ID"
    echo -e "${YELLOW}Tunnel will survive reboot!${NC}"
}

# ============================================================================
# IMPROVED CLOUDFLARE WARP INSTALLATION (گزینه 22)
# ============================================================================

# Get CPU architecture
get_cpu_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        armv6l)
            echo "armv6"
            ;;
        *)
            echo "amd64"  # Default to amd64
            ;;
    esac
}

# Get Cloudflare WARP server locations
get_warp_locations() {
    echo -e "${YELLOW}Available Cloudflare WARP Locations:${NC}"
    echo "1) 🇺🇸  USA - East (162.159.192.1)"
    echo "2) 🇺🇸  USA - West (162.159.193.1)"
    echo "3) 🇪🇺  Europe - Frankfurt (162.159.195.1)"
    echo "4) 🇸🇬  Asia - Singapore (162.159.196.1)"
    echo "5) 🇯🇵  Japan - Tokyo (162.159.197.1)"
    echo "6) 🇦🇺  Australia - Sydney (162.159.198.1)"
    echo "7) 🇮🇳  India - Mumbai (162.159.199.1)"
    echo "8) 🇧🇷  Brazil - São Paulo (162.159.200.1)"
    echo "9) 🇿🇦  South Africa - Johannesburg (162.159.201.1)"
    echo "10) Auto-select (Best Location)"
}

# Install WARP with proper IPv4 routing
install_warp_with_routing() {
    echo -e "${YELLOW}Installing Cloudflare WARP with IPv4 Routing...${NC}"
    print_separator
    
    # Select location
    get_warp_locations
    read -p "Select location (1-10): " location_choice
    
    # Map location choice to endpoint
    case $location_choice in
        1) ENDPOINT="162.159.192.1:2408" ;;
        2) ENDPOINT="162.159.193.1:2408" ;;
        3) ENDPOINT="162.159.195.1:2408" ;;
        4) ENDPOINT="162.159.196.1:2408" ;;
        5) ENDPOINT="162.159.197.1:2408" ;;
        6) ENDPOINT="162.159.198.1:2408" ;;
        7) ENDPOINT="162.159.199.1:2408" ;;
        8) ENDPOINT="162.159.200.1:2408" ;;
        9) ENDPOINT="162.159.201.1:2408" ;;
        10) ENDPOINT="162.159.192.1:2408" ;; # Default to automatic
        *) ENDPOINT="162.159.192.1:2408" ;;  # Default
    esac
    
    echo -e "${GREEN}Selected endpoint: $ENDPOINT${NC}"
    
    # Get CPU architecture
    local cpu_arch=$(get_cpu_arch)
    
    # Install dependencies
    echo -e "${YELLOW}Installing dependencies...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y curl wget jq openssl resolvconf iproute2 net-tools iptables
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget jq openssl iproute iptables
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget jq openssl iproute iptables
    fi
    
    # Check if WARP is already installed
    if command -v warp-go >/dev/null 2>&1; then
        echo -e "${YELLOW}WARP is already installed. Reinstalling...${NC}"
        systemctl stop warp-go 2>/dev/null
        systemctl disable warp-go 2>/dev/null
        rm -f /usr/local/bin/warp-go
        rm -rf /etc/warp
    fi
    
    # Create temp directory
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Download warp-go from reliable source
    echo -e "${YELLOW}Downloading WARP-GO...${NC}"
    
    # Try multiple sources
    local download_success=false
    
    # Source 1: GitHub
    local github_url="https://github.com/fscarmen/warp/releases/latest/download/warp-go_linux_$cpu_arch"
    if wget -q --timeout=20 --tries=2 -O warp-go "$github_url"; then
        download_success=true
        echo -e "${GREEN}✓ Downloaded from GitHub${NC}"
    
    # Source 2: GitLab
    elif wget -q --timeout=20 --tries=2 -O warp-go "https://gitlab.com/rwkgyg/CFwarp/-/raw/main/warp-go_1.0.8_linux_$cpu_arch"; then
        download_success=true
        echo -e "${GREEN}✓ Downloaded from GitLab${NC}"
    
    # Source 3: Direct
    elif wget -q --timeout=20 --tries=2 -O warp-go "https://cdn.jsdelivr.net/gh/fscarmen/warp/warp-go_linux_$cpu_arch"; then
        download_success=true
        echo -e "${GREEN}✓ Downloaded from CDN${NC}"
    fi
    
    if [ "$download_success" = false ]; then
        echo -e "${RED}✗ Failed to download WARP-GO from all sources${NC}"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Install warp-go
    chmod +x warp-go
    mv warp-go /usr/local/bin/warp-go
    
    # Create WARP configuration directory
    mkdir -p /etc/warp
    
    # Generate configuration with proper routing
    echo -e "${YELLOW}Generating WARP configuration...${NC}"
    
    # Get current main IP
    local main_ip=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+' | head -n1)
    local main_iface=$NETWORK_INTERFACE
    
    # Generate random keys
    local private_key=$(openssl rand -base64 32 | head -c 44)
    local device_id=$(cat /proc/sys/kernel/random/uuid)
    
    # Create configuration file with routing
    cat > /etc/warp/warp.conf <<EOF
[Account]
Device = $device_id
PrivateKey = $private_key
Token = 
Type = free
Name = WARP-CLI
MTU = 1280

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = $ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
KeepAlive = 25
PersistentKeepalive = 25

[Interface]
Address = 172.16.0.2/32
Address = 2606:4700:110:8d77:97e5:59e8:b5a6:8a2a/128
DNS = 1.1.1.1, 1.0.0.1
Table = auto
PostUp = ip rule add from 172.16.0.2 lookup main
PostUp = ip route add default via 172.16.0.2 dev warp0 table main
PostDown = ip rule del from 172.16.0.2 lookup main
EOF
    
    # Create routing script
    cat > /etc/warp/setup-routing.sh <<'EOF'
#!/bin/bash
# WARP Routing Setup Script

# Wait for WARP interface
sleep 5

# Get WARP interface IP
WARP_IP=$(ip addr show warp0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

if [ -n "$WARP_IP" ]; then
    echo "WARP IP detected: $WARP_IP"
    
    # Add WARP IP to main interface as secondary IP (برای نمایش)
    ip addr add $WARP_IP/32 dev $NETWORK_INTERFACE label $NETWORK_INTERFACE:warp 2>/dev/null
    
    # Create custom routing table
    ip route flush table 100 2>/dev/null
    ip rule del fwmark 100 2>/dev/null
    
    # Mark packets for WARP routing
    iptables -t mangle -A OUTPUT -p tcp -m multiport --dports 80,443 -j MARK --set-mark 100
    iptables -t mangle -A OUTPUT -p udp -m multiport --dports 53,443 -j MARK --set-mark 100
    
    # Create routing table for WARP
    ip route add default via $WARP_IP dev warp0 table 100
    ip rule add fwmark 100 table 100
    
    # Route specific traffic through WARP
    ip route add 1.1.1.1/32 dev warp0 2>/dev/null
    ip route add 8.8.8.8/32 dev warp0 2>/dev/null
    
    echo "Routing setup complete. WARP IP: $WARP_IP"
else
    echo "WARP interface not found, routing setup skipped"
fi
EOF
    
    chmod +x /etc/warp/setup-routing.sh
    
    # Create systemd service
    cat > /etc/systemd/system/warp-go.service <<EOF
[Unit]
Description=Cloudflare WARP Service
After=network.target
Wants=network.target
Requires=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStartPre=/bin/bash -c "sleep 3"
ExecStart=/usr/local/bin/warp-go --config=/etc/warp/warp.conf
ExecStartPost=/etc/warp/setup-routing.sh
Restart=always
RestartSec=5
Environment="LOG_LEVEL=info"
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable warp-go
    systemctl start warp-go
    
    # Wait for connection
    echo -e "${YELLOW}Waiting for WARP connection (15 seconds)...${NC}"
    sleep 15
    
    # Cleanup
    cd /
    rm -rf "$temp_dir"
    
    # Check connection and get IP
    echo -e "${YELLOW}Checking WARP connection...${NC}"
    
    # Try multiple times to get WARP IP
    local warp_ip=""
    for i in {1..5}; do
        warp_ip=$(curl -s4 --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep 'ip=' | cut -d= -f2)
        if [ -n "$warp_ip" ] && [ "$warp_ip" != "$main_ip" ]; then
            break
        fi
        sleep 3
    done
    
    # Add WARP IP to main interface for display
    if [ -n "$warp_ip" ] && [ "$warp_ip" != "$main_ip" ]; then
        ip addr add $warp_ip/32 dev $main_iface label ${main_iface}:warp 2>/dev/null
        echo -e "${GREEN}✓ WARP IPv4 added to $main_iface: $warp_ip${NC}"
    fi
    
    # Test connectivity
    if curl -s4 --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ WARP connectivity test passed${NC}"
        
        # Show final status
        echo -e "\n${GREEN}✅ Cloudflare WARP installed successfully!${NC}"
        echo -e "${YELLOW}Connection Details:${NC}"
        echo -e "  WARP IPv4: $warp_ip"
        echo -e "  Endpoint: $ENDPOINT"
        echo -e "  Main Interface: $main_iface"
        echo -e "  Original IP: $main_ip"
        echo -e "  WARP IP displayed on: ${main_iface}:warp"
        echo -e "\n${YELLOW}All IPv4 traffic is now routed through Cloudflare WARP${NC}"
        
        # Create management script
        cat > /usr/local/bin/warp-manager <<'EOF'
#!/bin/bash

case "$1" in
    status)
        echo "=== WARP Status ==="
        if systemctl is-active --quiet warp-go; then
            echo "Service: RUNNING"
            warp_ip=$(curl -s4 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep 'ip=' | cut -d= -f2)
            warp_status=$(curl -s4 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep 'warp=' | cut -d= -f2)
            echo "WARP Status: $warp_status"
            echo "Current IP: $warp_ip"
            echo "Interface: $(ip addr show | grep -B2 "$warp_ip" | grep ': ' | awk '{print $2}')"
        else
            echo "Service: STOPPED"
        fi
        ;;
    ip)
        curl -s4 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep 'ip=' | cut -d= -f2
        ;;
    restart)
        systemctl restart warp-go
        echo "WARP restarted"
        ;;
    stop)
        systemctl stop warp-go
        echo "WARP stopped"
        ;;
    start)
        systemctl start warp-go
        echo "WARP started"
        ;;
    *)
        echo "Usage: $0 {status|ip|restart|stop|start}"
        ;;
esac
EOF
        
        chmod +x /usr/local/bin/warp-manager
        
        echo -e "\n${BLUE}Management commands:${NC}"
        echo -e "  warp-manager status  - Check WARP status"
        echo -e "  warp-manager ip      - Show current WARP IP"
        echo -e "  warp-manager restart - Restart WARP"
        echo -e "  systemctl status warp-go - Service details"
        
    else
        echo -e "${YELLOW}⚠ WARP installed but connectivity test failed${NC}"
        echo -e "${YELLOW}Checking service status...${NC}"
        systemctl status warp-go --no-pager | tail -20
    fi
    
    print_separator
}

# Check WARP status
check_warp_status() {
    echo -e "${YELLOW}Checking WARP status...${NC}"
    print_separator
    
    if ! command -v warp-go >/dev/null 2>&1; then
        echo -e "${RED}✗ WARP is not installed${NC}"
        return 1
    fi
    
    if systemctl is-active --quiet warp-go 2>/dev/null; then
        echo -e "${GREEN}✓ WARP service is running${NC}"
        
        # Get current IPs
        local main_ip=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+' | head -n1)
        local warp_ip=$(curl -s4 --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep 'ip=' | cut -d= -f2)
        local warp_status=$(curl -s4 --max-time 5 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep 'warp=' | cut -d= -f2)
        
        echo -e "${YELLOW}IP Information:${NC}"
        echo -e "  Original IP: $main_ip"
        
        if [ -n "$warp_ip" ]; then
            echo -e "  Current IP: $warp_ip"
            echo -e "  WARP Status: $warp_status"
            
            # Check if WARP IP is different from main IP
            if [ "$warp_ip" != "$main_ip" ]; then
                echo -e "  Traffic Routing: ${GREEN}Through WARP ✓${NC}"
                
                # Display interface with WARP IP
                local warp_interface=$(ip addr show | grep -B2 "$warp_ip" | grep ': ' | awk '{print $2}' || echo "warp0")
                echo -e "  WARP Interface: $warp_interface"
            else
                echo -e "  Traffic Routing: ${YELLOW}Direct (Not through WARP)${NC}"
            fi
        fi
        
        # Test connectivity
        echo -e "\n${YELLOW}Connectivity Tests:${NC}"
        if curl -s4 --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
            echo -e "  IPv4 to 1.1.1.1: ${GREEN}OK ✓${NC}"
        else
            echo -e "  IPv4 to 1.1.1.1: ${RED}FAILED ✗${NC}"
        fi
        
        # Check routing table
        echo -e "\n${YELLOW}Routing Information:${NC}"
        ip route show | grep -E "warp0|default" | head -5
        
    else
        echo -e "${RED}✗ WARP service is not running${NC}"
        echo -e "${YELLOW}Try: systemctl start warp-go${NC}"
    fi
    
    print_separator
}

# Remove WARP completely
remove_warp() {
    if ! confirm_action "This will remove Cloudflare WARP and restore original routing!"; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Removing Cloudflare WARP...${NC}"
    
    # Stop and disable service
    systemctl stop warp-go 2>/dev/null
    systemctl disable warp-go 2>/dev/null
    
    # Remove WARP IP from main interface
    local main_iface=$NETWORK_INTERFACE
    ip addr show $main_iface | grep "warp" | awk '{print $2}' | while read ip; do
        ip addr del $ip dev $main_iface 2>/dev/null
    done
    
    # Remove routing rules
    ip rule del fwmark 100 2>/dev/null
    ip route flush table 100 2>/dev/null
    
    # Remove iptables rules
    iptables -t mangle -F 2>/dev/null
    
    # Remove files
    rm -f /usr/local/bin/warp-go
    rm -f /usr/local/bin/warp-manager
    rm -f /etc/warp/setup-routing.sh
    rm -rf /etc/warp
    rm -f /etc/systemd/system/warp-go.service
    
    # Reload systemd
    systemctl daemon-reload 2>/dev/null
    
    echo -e "${GREEN}✓ Cloudflare WARP completely removed!${NC}"
    echo -e "${YELLOW}Original network configuration restored.${NC}"
}

# WARP Management Menu
manage_warp() {
    while true; do
        echo -e "\n${YELLOW}Cloudflare WARP Management${NC}"
        echo -e "1) Install/Reinstall WARP with IPv4 Routing"
        echo -e "2) Check WARP Status & IP"
        echo -e "3) Restart WARP Service"
        echo -e "4) Stop WARP Service"
        echo -e "5) Remove WARP Completely"
        echo -e "6) View WARP Logs"
        echo -e "7) Test WARP Connection"
        echo -e "8) Back to Main Menu"
        
        read -p "Enter your choice [1-8]: " warp_choice
        
        case $warp_choice in
            1)
                install_warp_with_routing
                ;;
            2)
                check_warp_status
                ;;
            3)
                echo -e "${YELLOW}Restarting WARP service...${NC}"
                if systemctl restart warp-go 2>/dev/null; then
                    echo -e "${GREEN}✓ WARP service restarted${NC}"
                    sleep 5
                    check_warp_status
                else
                    echo -e "${RED}✗ Failed to restart WARP service${NC}"
                fi
                ;;
            4)
                echo -e "${YELLOW}Stopping WARP service...${NC}"
                if systemctl stop warp-go 2>/dev/null; then
                    echo -e "${GREEN}✓ WARP service stopped${NC}"
                else
                    echo -e "${RED}✗ Failed to stop WARP service${NC}"
                fi
                ;;
            5)
                remove_warp
                ;;
            6)
                echo -e "${YELLOW}Showing last 30 lines of WARP logs...${NC}"
                journalctl -u warp-go --no-pager -n 30
                ;;
            7)
                echo -e "${YELLOW}Testing WARP connection...${NC}"
                if curl -s4 --max-time 5 https://1.1.1.1 >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ WARP connection successful${NC}"
                    curl -s4 https://cloudflare.com/cdn-cgi/trace | grep -E "ip=|warp=|country="
                else
                    echo -e "${RED}✗ WARP connection failed${NC}"
                fi
                ;;
            8)
                return
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                ;;
        esac
        
        read -p "Press [Enter] to continue..."
    done
}

# ============================================================================
# FIX DNS FUNCTION (گزینه 23)
# ============================================================================
fix_dns() {
    echo -e "${YELLOW}Fixing DNS Configuration...${NC}"
    print_separator
    
    echo -e "${BLUE}Step 1: Stopping systemd-resolved...${NC}"
    sudo systemctl stop systemd-resolved
    echo -e "${GREEN}✓ systemd-resolved stopped${NC}"
    
    echo -e "${BLUE}Step 2: Disabling systemd-resolved...${NC}"
    sudo systemctl disable systemd-resolved
    echo -e "${GREEN}✓ systemd-resolved disabled${NC}"
    
    echo -e "${BLUE}Step 3: Removing existing resolv.conf...${NC}"
    sudo rm -f /etc/resolv.conf
    echo -e "${GREEN}✓ /etc/resolv.conf removed${NC}"
    
    echo -e "${BLUE}Step 4: Creating new resolv.conf...${NC}"
    
    # Get DNS servers from user
    echo -e "${YELLOW}Enter two DNS servers (separated by space):${NC}"
    echo -e "${GREEN}Example: 1.1.1.1 8.8.8.8${NC}"
    read -p "Enter DNS servers: " dns_input
    
    # Default to Cloudflare and Google if no input
    if [ -z "$dns_input" ]; then
        DNS1="1.1.1.1"
        DNS2="8.8.8.8"
        echo -e "${YELLOW}Using default DNS: $DNS1 $DNS2${NC}"
    else
        DNS_ARRAY=($dns_input)
        DNS1=${DNS_ARRAY[0]}
        DNS2=${DNS_ARRAY[1]:-8.8.8.8}  # Default second DNS to Google
    fi
    
    # Validate DNS servers
    validate_dns() {
        local dns=$1
        if [[ $dns =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            return 0
        else
            return 1
        fi
    }
    
    if ! validate_dns "$DNS1"; then
        echo -e "${RED}Invalid DNS server: $DNS1${NC}"
        echo -e "${YELLOW}Using default DNS: 1.1.1.1${NC}"
        DNS1="1.1.1.1"
    fi
    
    if ! validate_dns "$DNS2"; then
        echo -e "${RED}Invalid DNS server: $DNS2${NC}"
        echo -e "${YELLOW}Using default DNS: 8.8.8.8${NC}"
        DNS2="8.8.8.8"
    fi
    
    # Create new resolv.conf
    cat > /etc/resolv.conf <<EOF
# Generated by $SCRIPT_NAME - Fix DNS
# Date: $(date)
# Manual DNS configuration

nameserver $DNS1
nameserver $DNS2
options rotate
options timeout:2
options attempts:3
EOF
    
    echo -e "${GREEN}✓ /etc/resolv.conf created with DNS: $DNS1, $DNS2${NC}"
    
    # Make resolv.conf immutable
    echo -e "${BLUE}Step 5: Making resolv.conf immutable...${NC}"
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo -e "${GREEN}✓ /etc/resolv.conf is now immutable${NC}"
    
    # Create systemd-resolved disable configuration
    echo -e "${BLUE}Step 6: Creating systemd-resolved disable config...${NC}"
    mkdir -p /etc/systemd/resolved.conf.d/
    cat > /etc/systemd/resolved.conf.d/disable-resolved.conf <<EOF
[Resolve]
DNSStubListener=no
EOF
    
    # Restart systemd-resolved (it will start but not interfere)
    systemctl restart systemd-resolved 2>/dev/null || true
    
    # Test DNS
    echo -e "${BLUE}Step 7: Testing DNS configuration...${NC}"
    if command -v dig >/dev/null 2>&1; then
        echo -e "${YELLOW}Testing DNS resolution...${NC}"
        if dig google.com +short @$DNS1 >/dev/null 2>&1; then
            echo -e "${GREEN}✓ DNS $DNS1 is working${NC}"
        else
            echo -e "${YELLOW}⚠ DNS $DNS1 test failed${NC}"
        fi
        
        if dig google.com +short @$DNS2 >/dev/null 2>&1; then
            echo -e "${GREEN}✓ DNS $DNS2 is working${NC}"
        else
            echo -e "${YELLOW}⚠ DNS $DNS2 test failed${NC}"
        fi
    fi
    
    print_separator
    echo -e "${GREEN}✅ DNS Fix completed successfully!${NC}"
    echo -e "${YELLOW}Configured DNS servers:${NC}"
    echo -e "  Primary:   $DNS1"
    echo -e "  Secondary: $DNS2"
    echo -e "${YELLOW}File: /etc/resolv.conf${NC}"
    echo -e "${YELLOW}Status: Immutable (protected from changes)${NC}"
}

# ============================================================================
# DELETE VXLAN TUNNEL (گزینه 20)
# ============================================================================
delete_vxlan_tunnel() {
    if ! confirm_action "This will delete all VXLAN tunnels and configurations!"; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Deleting VXLAN tunnels and all configurations...${NC}"
    
    # Remove VXLAN interface
    ip link del vxlan100 2>/dev/null
    
    # Remove all configuration methods
    rm -f /etc/systemd/network/10-vxlan-*.netdev 2>/dev/null
    rm -f /etc/systemd/network/20-vxlan-*.network 2>/dev/null
    
    rm -f /etc/netplan/99-vxlan.yaml 2>/dev/null
    
    rm -f /etc/sysconfig/network-scripts/ifcfg-vxlan100 2>/dev/null
    
    rm -f /etc/systemd/system/vxlan-iran.service 2>/dev/null
    rm -f /etc/systemd/system/vxlan-kharej.service 2>/dev/null
    rm -f /usr/local/bin/setup-vxlan-*.sh 2>/dev/null
    rm -f /usr/local/bin/check-vxlan.sh 2>/dev/null
    
    # Remove cron jobs
    crontab -l 2>/dev/null | grep -v "check-vxlan" | crontab - 2>/dev/null
    
    # Apply changes
    systemctl daemon-reload 2>/dev/null
    
    if [ -d /etc/netplan ]; then
        netplan apply 2>/dev/null
    fi
    
    if [ -d /etc/sysconfig/network-scripts ]; then
        systemctl restart network 2>/dev/null
    fi
    
    echo -e "${GREEN}✓ All VXLAN tunnels and configurations have been removed!${NC}"
}

# ============================================================================
# MAIN MENU
# ============================================================================
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
        echo -e "18) Setup Iran Tunnel (Persistent)"
        echo -e "19) Setup Kharej Tunnel (Persistent)"
        echo -e "20) Delete VXLAN Tunnel"
        echo -e "21) Install HAProxy & All Ports"
        echo -e "22) Cloudflare WARP Management (Improved IPv4 Routing)"
        echo -e "23) Fix DNS Configuration"
        echo -e "24) Exit"
        
        read -p "Enter your choice [1-24]: " choice
        
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
                fix_dns
                ;;
            24)
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
