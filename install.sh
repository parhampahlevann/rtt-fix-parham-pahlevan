#!/bin/bash

# Global Configuration
SCRIPT_NAME="BBR VIP Optimizer"
SCRIPT_VERSION="2.4"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
SYSCTL_BACKUP="/etc/sysctl.conf.bak"
CRON_JOB_FILE="/etc/cron.d/bbr_vip_autoreset"

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1

# Color and Formatting
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
    echo ""
}

# Check Root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${BOLD_RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
}

# Install Dependencies
install_deps() {
    local packages=("bc" "jq" "net-tools")
    local to_install=()
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            to_install+=("$pkg")
        fi
    done
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Installing dependencies: ${to_install[*]}${NC}"
        apt-get update && apt-get install -y "${to_install[@]}"
    fi
}

# Network Interface Selection
select_interface() {
    interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
    
    if [[ ${#interfaces[@]} -eq 1 ]]; then
        INTERFACE=${interfaces[0]}
        echo -e "${GREEN}Auto-selected interface: $INTERFACE${NC}"
        return
    fi

    echo -e "${YELLOW}Available network interfaces:${NC}"
    PS3="Please select interface (1-${#interfaces[@]}): "
    select INTERFACE in "${interfaces[@]}"; do
        if [[ -n "$INTERFACE" ]]; then
            break
        else
            echo -e "${RED}Invalid selection!${NC}"
        fi
    done
}

# BBR Configuration
configure_bbr() {
    echo -e "\n${YELLOW}Configuring TCP congestion control...${NC}"
    
    # Load required modules
    modprobe tcp_bbr 2>/dev/null || echo -e "${RED}Failed to load tcp_bbr module${NC}"
    modprobe sch_fq 2>/dev/null || echo -e "${RED}Failed to load sch_fq module${NC}"

    # Apply BBR settings
    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
    } >> /etc/sysctl.conf
    
    sysctl -p
    
    echo -e "${GREEN}BBR configured successfully!${NC}"
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

# Performance tuning
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

# Firewall Configuration
configure_firewall() {
    echo -e "\n${YELLOW}Configuring firewall...${NC}"
    
    if command -v ufw &>/dev/null; then
        ufw disable
        echo -e "${GREEN}UFW firewall disabled.${NC}"
    fi
}

# X-UI Detection
detect_xui() {
    if systemctl is-active x-ui &>/dev/null; then
        echo "x-ui"
    fi
}

# Cron Job Management
add_cron_job() {
    local service_name="$1"
    local interval="${2:-15}"
    
    echo -e "\n${YELLOW}Adding cron job for $service_name...${NC}"
    
    echo "*/$interval * * * * root systemctl restart $service_name >/dev/null 2>&1" > "$CRON_JOB_FILE"
    chmod 644 "$CRON_JOB_FILE"
    systemctl restart cron
    
    echo -e "${GREEN}Cron job added successfully!${NC}"
}

# Main Installation
install_optimizations() {
    show_header
    check_root
    install_deps
    select_interface
    
    # Backup original settings
    cp /etc/sysctl.conf "$SYSCTL_BACKUP"
    
    configure_bbr
    optimize_tcp
    configure_firewall
    
    # Check for X-UI
    if xui_service=$(detect_xui); then
        read -p "Detected X-UI service. Configure auto-restart? (y/n): " choice
        if [[ "$choice" =~ [yY] ]]; then
            add_cron_job "$xui_service"
        fi
    fi
    
    echo -e "\n${GREEN}Optimization completed successfully!${NC}"
    echo -e "Log file: ${BLUE}$LOG_FILE${NC}"
}

# Uninstallation
uninstall_optimizations() {
    show_header
    check_root
    
    echo -e "\n${YELLOW}=== Reverting optimizations ===${NC}"
    
    if [[ -f "$SYSCTL_BACKUP" ]]; then
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        rm -f /etc/sysctl.d/60-bbr-optimizations.conf
        sysctl -p
        echo -e "${GREEN}System settings restored.${NC}"
    fi
    
    if [[ -f "$CRON_JOB_FILE" ]]; then
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
    
    if [[ -f "$CRON_JOB_FILE" ]]; then
        echo -e "\n${BOLD}Auto-Restart Service:${NC}"
        echo "Service: $(awk '{print $6}' $CRON_JOB_FILE)"
        echo "Interval: $(awk '{print $1}' $CRON_JOB_FILE | cut -d'/' -f2) minutes"
    fi
}

# Main Menu
show_menu() {
    while true; do
        show_header
        echo -e "${BOLD}Main Menu:${NC}"
        echo -e "1. ${GREEN}Install Optimizations${NC}"
        echo -e "2. ${RED}Uninstall Optimizations${NC}"
        echo -e "3. ${BLUE}Check Status${NC}"
        echo -e "4. ${BOLD_RED}Exit${NC}"
        
        read -p "Select an option [1-4]: " choice
        
        case $choice in
            1) install_optimizations ;;
            2) uninstall_optimizations ;;
            3) check_status ;;
            4) 
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

# Clean line endings (for Windows edited files)
clean_script() {
    sed -i 's/\r$//' "$0"
}

# Main Execution
clean_script
show_menu
