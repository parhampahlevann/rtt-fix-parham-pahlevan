#!/bin/bash

# =========================================================
# Ultimate Network Optimizer
# Version 10.0 - Bug fixes + UDP/TCP-noise/Hetzner/SNI tools
# Author: Parham Pahlevan
#
# Changelog vs 9.7:
#  - FIX: DNS config could silently leave you with a dead resolver when
#         the DNS server you entered (esp. IPv6) wasn't actually reachable,
#         or was a link-local IPv6 address with no interface scope.
#         configure_dns() now scopes link-local IPv6, prefers resolvectl
#         when systemd-resolved is present, tests the new servers, and
#         rolls back automatically if none of them answer.
#  - FIX: "Disable IPv6" only touched conf.all/default and never verified
#         anything, so it silently no-op'd on some systems. It now loops
#         every interface, flushes stale addresses, verifies, and offers
#         to persist.
#  - FIX: every "persist to /etc/sysctl.conf" feature (BBR, TCP MUX, BBR+
#         fq_codel, CPU optimizer) either appended duplicate blocks on
#         every re-run or, in the CPU optimizer's case, clobbered the
#         WHOLE /etc/sysctl.conf file. All of these now write to their
#         own idempotent /etc/sysctl.d/90-netopt-*.conf drop-in, which is
#         also what makes a clean full uninstall possible.
#  - FIX: menu numbering had a gap (22/23 missing) and System Lock Fixer
#         was implemented but never wired into the menu. Renumbered 1-36.
#  - FIX: reset_all() never removed persisted sysctl.d files and double-
#         prompted for confirmation via delete_vxlan_tunnel.
#  - NEW: BBR profile rewritten for TCP stability (fq instead of fq_codel
#         per upstream BBR guidance, drops the removed tcp_low_latency key).
#  - NEW: UDP optimizer (buffers/queues/backlog - BBR itself is TCP-only,
#         see the option's own output for why).
#  - NEW: TCP noise fixer (reordering/jitter tolerance).
#  - NEW: Hetzner MTU fixer, Full DNS reset (systemd-resolved), SNI/CDN
#         latency scanner, Full uninstall.
#  - NEW: main status screen now re-reads MTU live instead of a cached value.
#  - NEW: Enable IPv6 option (menu 36) - removes any disable_ipv6 lines from
#         /etc/sysctl.conf, writes =0 for all/default, applies and reloads.
#         Exit moved from 36 to 37.
# =========================================================

SCRIPT_NAME="Ultimate Network Optimizer"
SCRIPT_VERSION="10.0"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/network_optimizer.conf"
LOG_FILE="/var/log/network_optimizer.log"
BACKUP_DIR="/var/backups/network_optimizer"
SYSCTL_D_DIR="/etc/sysctl.d"
NETOPT_TAG="90-netopt"
SNI_HISTORY_FILE="$BACKUP_DIR/sni_scan_history.txt"

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

# ==============================================================
# Idempotent sysctl.d drop-in helpers.
# Every feature that used to append to /etc/sysctl.conf (duplicating
# itself on every re-run) or, worse, overwrite it outright now goes
# through here instead - one file per feature, safely re-writable,
# and trivial to remove cleanly (see sysctl_unpersist_all / full_uninstall).
# ==============================================================
sysctl_persist() {
    local slug="$1"
    local content="$2"
    local file="${SYSCTL_D_DIR}/${NETOPT_TAG}-${slug}.conf"
    {
        echo "# Managed by $SCRIPT_NAME - do not edit by hand, re-run the menu option instead"
        echo "# Feature: $slug | Generated: $(date)"
        echo "$content"
    } > "$file"
    sysctl --system >/dev/null 2>&1
}

sysctl_unpersist() {
    local slug="$1"
    rm -f "${SYSCTL_D_DIR}/${NETOPT_TAG}-${slug}.conf"
}

sysctl_unpersist_all() {
    rm -f "${SYSCTL_D_DIR}/${NETOPT_TAG}-"*.conf
    sysctl --system >/dev/null 2>&1
}

show_header() {
    clear
    echo -e "${BLUE}${BOLD}====================================================="
    echo -e "   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}"
    echo -e "=====================================================${NC}"
    detect_distro
    echo -e "${YELLOW}Distribution: ${BOLD}$DISTRO $DISTRO_VERSION${NC}"
    echo -e "${YELLOW}Interface: ${BOLD}$NETWORK_INTERFACE${NC}"

    # Live MTU read instead of trusting a possibly-stale cached/saved value.
    local live_mtu
    live_mtu=$(cat "/sys/class/net/$NETWORK_INTERFACE/mtu" 2>/dev/null || echo "unknown")
    if [[ "$live_mtu" != "unknown" && "$live_mtu" != "$CURRENT_MTU" ]]; then
        echo -e "${YELLOW}Current MTU: ${BOLD}$live_mtu${NC} ${YELLOW}(saved config says $CURRENT_MTU - out of sync)${NC}"
        CURRENT_MTU=$live_mtu
    else
        echo -e "${YELLOW}Current MTU: ${BOLD}$live_mtu${NC}"
    fi
    if ip link show vxlan100 >/dev/null 2>&1; then
        local vx_mtu
        vx_mtu=$(cat /sys/class/net/vxlan100/mtu 2>/dev/null || echo "?")
        echo -e "${YELLOW}VXLAN100 MTU: ${BOLD}$vx_mtu${NC}"
    fi

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

# Accepts IPv4 and IPv6 (validation only - link-local scoping is handled
# separately in configure_dns, since a bare fe80:: address is syntactically
# valid even though it needs a %interface suffix to actually be usable).
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
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

# ========== NEW: Hetzner MTU fixer ==========
# Runs the exact command Hetzner support gives out for a stuck/wrong MTU,
# then optionally reuses configure_mtu()'s existing persistence logic so it
# survives a reboot too (the bare "ip link set" alone is runtime-only).
hetzner_mtu_fixer() {
    local target_if="eth0"
    if ! ip link show "$target_if" >/dev/null 2>&1; then
        echo -e "${YELLOW}No eth0 on this box, using the detected default interface instead: $NETWORK_INTERFACE${NC}"
        target_if="$NETWORK_INTERFACE"
    fi
    echo -e "${YELLOW}Running: ip link set dev $target_if mtu 1500${NC}"
    if ip link set dev "$target_if" mtu 1500; then
        echo -e "${GREEN}MTU set to 1500 on $target_if.${NC}"
    else
        echo -e "${RED}Failed to set MTU on $target_if.${NC}"
        return 1
    fi
    if [[ "$target_if" == "$NETWORK_INTERFACE" ]]; then
        CURRENT_MTU=1500
        save_config
    fi
    read -p "Also persist 1500 across reboots (netplan/NetworkManager)? (y/n): " p
    if [[ "$p" =~ ^[Yy]$ ]]; then
        local saved_if="$NETWORK_INTERFACE"
        NETWORK_INTERFACE="$target_if"
        configure_mtu 1500
        NETWORK_INTERFACE="$saved_if"
    fi
}

_detect_systemd_resolved() {
    command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null
}

_dns_reachable() {
    local server="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +time=2 +tries=1 @"$server" example.com >/dev/null 2>&1
        return $?
    fi
    timeout 2 bash -c "cat < /dev/null > /dev/tcp/$server/53" 2>/dev/null
    return $?
}

# ================== DNS Configuration (supports IPv4 & IPv6) ==================
# Rewritten. Root causes addressed for "IPv6 DNS doesn't work":
#  1) A link-local IPv6 nameserver (fe80::/10) is syntactically valid but
#     glibc's resolver can't use it without a %interface scope - it's now
#     auto-scoped.
#  2) On systemd-resolved systems /etc/resolv.conf is normally a symlink;
#     blindly deleting it and chattr +i-ing a plain file in its place fights
#     the service. We now configure via resolvectl when it's active.
#  3) Nothing ever verified the server actually answered a query before
#     committing to it - if it's unreachable (no route, IPv6 down, typo)
#     you'd end up with a broken resolver and no feedback. Now tested, with
#     automatic rollback if none of the entered servers respond.
# ======================================================================
configure_dns() {
    echo -e "\n${YELLOW}DNS Configuration (supports IPv4 and IPv6)${NC}"
    print_separator

    echo -e "${BLUE}Enter the DNS servers you want to use (IPv4 or IPv6):${NC}"
    read -p "Primary DNS: " dns1
    local dns1_base="${dns1%%%*}"
    if ! validate_ip "$dns1_base"; then
        echo -e "${RED}Invalid IP address!${NC}"
        return 1
    fi

    read -p "Secondary DNS (optional, press Enter to skip): " dns2
    local dns2_base=""
    [ -n "$dns2" ] && dns2_base="${dns2%%%*}"

    DNS_SERVERS=("$dns1")
    if [ -n "$dns2" ]; then
        if validate_ip "$dns2_base"; then
            DNS_SERVERS+=("$dns2")
        else
            echo -e "${RED}Invalid secondary DNS IP, ignoring it.${NC}"
        fi
    fi

    local i
    for i in "${!DNS_SERVERS[@]}"; do
        local d="${DNS_SERVERS[$i]}"
        if [[ "$d" =~ ^[fF][eE]80: ]] && [[ "$d" != *%* ]]; then
            DNS_SERVERS[$i]="${d}%${NETWORK_INTERFACE}"
            echo -e "${YELLOW}Link-local address needs an interface scope, using: ${DNS_SERVERS[$i]}${NC}"
        fi
    done

    if _detect_systemd_resolved; then
        echo -e "${YELLOW}systemd-resolved detected - configuring via resolvectl.${NC}"
        if resolvectl dns "$NETWORK_INTERFACE" "${DNS_SERVERS[@]}" && \
           resolvectl domain "$NETWORK_INTERFACE" '~.'; then
            echo -e "${GREEN}resolvectl accepted the new servers.${NC}"
        else
            echo -e "${RED}resolvectl rejected the servers. Nothing changed.${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}systemd-resolved not active - writing /etc/resolv.conf directly.${NC}"
        if [ -L /etc/resolv.conf ]; then
            echo -e "${YELLOW}Note: /etc/resolv.conf is a symlink and will be replaced with a plain file.${NC}"
        fi
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
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
    fi

    echo -e "${YELLOW}Testing the new servers before committing...${NC}"
    local reachable=0 dns plain
    for dns in "${DNS_SERVERS[@]}"; do
        plain="${dns%%%*}"
        if _dns_reachable "$plain"; then
            reachable=1
            echo -e "${GREEN}  $dns: OK${NC}"
        else
            echo -e "${RED}  $dns: no response${NC}"
        fi
    done

    if [[ "$reachable" -eq 0 ]]; then
        echo -e "${RED}None of the entered DNS servers responded - rolling back so DNS doesn't break.${NC}"
        if _detect_systemd_resolved; then
            resolvectl revert "$NETWORK_INTERFACE" 2>/dev/null
        else
            reset_dns
        fi
        return 1
    fi

    if ! _detect_systemd_resolved; then
        chattr +i /etc/resolv.conf 2>/dev/null || \
            echo -e "${YELLOW}Warning: could not set resolv.conf immutable (chattr +i).${NC}"
    fi

    CURRENT_DNS=$(printf "%s " "${DNS_SERVERS[@]}")
    save_config

    echo -e "\n${GREEN}DNS updated successfully.${NC}"
    echo -e "${GREEN}Current DNS servers: ${DNS_SERVERS[*]}${NC}"
}
# ======================================================================

reset_dns() {
    echo -e "${YELLOW}Resetting DNS to default...${NC}"
    if _detect_systemd_resolved; then
        resolvectl revert "$NETWORK_INTERFACE" 2>/dev/null
        resolvectl dns "$NETWORK_INTERFACE" 8.8.8.8 8.8.4.4 2>/dev/null
    else
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf <<EOF
# $SCRIPT_NAME - Default DNS
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    fi
    DNS_SERVERS=("8.8.8.8" "8.8.4.4")
    CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    save_config
    echo -e "${GREEN}DNS reset to default (Google DNS)${NC}"
}

# ========== NEW: Full DNS reset (systemd-resolved) ==========
reset_full_dns() {
    echo -e "${YELLOW}Full DNS reset via systemd-resolved...${NC}"
    print_separator
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl list-unit-files 2>/dev/null | grep -q systemd-resolved; then
        echo -e "${RED}systemd-resolved isn't present on this system - nothing to restart.${NC}"
        echo -e "${YELLOW}Use 'Configure DNS' or 'Show Current DNS' instead.${NC}"
        return 1
    fi
    systemctl restart systemd-resolved
    resolvectl flush-caches
    resolvectl status
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

    if _detect_systemd_resolved; then
        print_separator
        echo -e "${BOLD}resolvectl status for $NETWORK_INTERFACE:${NC}"
        resolvectl status "$NETWORK_INTERFACE" 2>/dev/null
    fi

    print_separator
    echo -e "${BOLD}Configured DNS Servers:${NC}"
    for dns in "${DNS_SERVERS[@]}"; do
        echo "  $dns"
    done
}

# ========== BBR ==========
# Rewritten for TCP stability:
#  - drops net.ipv4.tcp_low_latency (removed from the kernel years ago,
#    the sysctl -w for it was silently failing every run)
#  - pairs BBR with the "fq" qdisc instead of fq_codel: BBR relies on
#    fq's internal packet pacing, which is the pairing upstream/Google's
#    own BBR docs recommend; fq_codel doesn't give BBR the same pacing.
#  - applies fq live via tc as well as persisting default_qdisc, since
#    the sysctl alone only affects interfaces that come up *after* it's set
#  - tcp_ecn=2 (accept, don't initiate) instead of 1, since some networks/
#    middleboxes mishandle ECN-marked packets and can cause stalls
#  - idempotent: writes one sysctl.d drop-in instead of appending to
#    /etc/sysctl.conf on every run
install_bbr() {
    echo -e "${YELLOW}Installing/optimizing BBR for stable TCP...${NC}"
    print_separator

    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        modprobe tcp_bbr 2>/dev/null
    fi
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo -e "${RED}This kernel doesn't support BBR (tcp_bbr module unavailable). Aborting.${NC}"
        return 1
    fi

    local content
    content=$(cat <<'EOT'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_tw_buckets = 200000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOT
)
    sysctl_persist "bbr" "$content"
    tc qdisc replace dev "$NETWORK_INTERFACE" root fq 2>/dev/null

    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$cc" == "bbr" ]]; then
        echo -e "${GREEN}BBR active now. congestion_control=$cc  default_qdisc=$qd${NC}"
    else
        echo -e "${YELLOW}Sysctl applied but congestion_control currently reports: $cc${NC}"
    fi
    echo -e "${YELLOW}Note: switched default_qdisc from fq_codel to fq - fq is the pairing BBR's${NC}"
    echo -e "${YELLOW}own docs recommend for correct pacing.${NC}"
}

uninstall_bbr() {
    echo -e "${YELLOW}Uninstalling BBR and restoring previous settings...${NC}"
    print_separator

    sysctl_unpersist "bbr"

    # legacy cleanup for anyone who last ran the old (pre-10.0) version
    local backup
    backup=$(ls -1t /etc/sysctl.conf.backup.* 2>/dev/null | head -n1)
    if [ -n "$backup" ]; then
        echo -e "${YELLOW}Restoring legacy backup file: $backup${NC}"
        cp "$backup" /etc/sysctl.conf
    elif grep -q "# BBR Optimization - Added by $SCRIPT_NAME" /etc/sysctl.conf 2>/dev/null; then
        sed -i "/# BBR Optimization - Added by $SCRIPT_NAME/,/net.core.wmem_max=16777216/d" /etc/sysctl.conf
        echo -e "${YELLOW}Removed legacy BBR block from /etc/sysctl.conf${NC}"
    fi

    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    tc qdisc replace dev "$NETWORK_INTERFACE" root fq_codel 2>/dev/null
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
    sysctl -p >/dev/null 2>&1 || true

    local cc
    cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "${GREEN}Current congestion control: ${cc}${NC}"
    echo -e "${GREEN}BBR uninstall / rollback completed.${NC}"
}
# ===============================================================

# ========== NEW: UDP packet-loss / drop optimizer ==========
udp_optimizer() {
    echo -e "${YELLOW}UDP packet-loss / drop optimizer${NC}"
    print_separator
    echo -e "${BLUE}Heads up: BBR is a TCP-only congestion-control algorithm - the kernel has${NC}"
    echo -e "${BLUE}no equivalent for UDP, so there's no such thing as \"BBR for UDP\" at the${NC}"
    echo -e "${BLUE}kernel level. What actually cuts UDP packet loss/drops at the OS layer is${NC}"
    echo -e "${BLUE}bigger socket/memory buffers and a higher NAPI processing budget - that's${NC}"
    echo -e "${BLUE}what this option tunes (useful for WireGuard/QUIC/UDP-based tunnels).${NC}"
    print_separator

    local content
    content=$(cat <<'EOT'
net.ipv4.udp_mem = 1124736 1498316 2097152
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
EOT
)
    sysctl_persist "udp" "$content"

    if command -v ethtool >/dev/null 2>&1; then
        local max_rx
        max_rx=$(ethtool -g "$NETWORK_INTERFACE" 2>/dev/null | awk '/^RX:/{print $2; exit}')
        if [[ -n "$max_rx" && "$max_rx" =~ ^[0-9]+$ ]]; then
            ethtool -G "$NETWORK_INTERFACE" rx "$max_rx" 2>/dev/null && \
                echo -e "${GREEN}RX ring buffer raised to driver max ($max_rx) on $NETWORK_INTERFACE${NC}"
        fi
    fi

    echo -e "${GREEN}UDP buffer/queue tuning applied and persisted.${NC}"
    local after
    after=$(grep -i '^Udp:' -A1 /proc/net/snmp 2>/dev/null | tail -1)
    echo -e "${YELLOW}Udp: counters right now (RcvbufErrors = OS-level UDP drops so far).${NC}"
    echo -e "${YELLOW}These are just a baseline to watch going forward, not a before/after proof:${NC}"
    echo "  snapshot: $after"
}

# ========== NEW: TCP noise fixer ==========
tcp_noise_fixer() {
    echo -e "${YELLOW}TCP noise / instability fixer${NC}"
    echo -e "${BLUE}Makes TCP more tolerant of reordering, jitter and spurious-loss signals${NC}"
    echo -e "${BLUE}from noisy links/tunnels, without touching congestion-control aggressiveness${NC}"
    echo -e "${BLUE}- so it doesn't add any packet loss or drops of its own.${NC}"
    print_separator

    local content
    content=$(cat <<'EOT'
net.ipv4.tcp_reordering = 8
net.ipv4.tcp_frto = 2
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_syn_retries = 6
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOT
)
    sysctl_persist "noise" "$content"
    echo -e "${GREEN}Applied.${NC}"
    echo -e "${YELLOW}Trade-off worth knowing: raising tcp_reordering delays fast-retransmit${NC}"
    echo -e "${YELLOW}slightly, which is a net win on reordering-prone tunnels but means real${NC}"
    echo -e "${YELLOW}loss on a genuinely bad link is noticed a little later.${NC}"
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
    if [ -d "$SYSCTL_D_DIR" ]; then
        shopt -s nullglob
        local netopt_files=(${SYSCTL_D_DIR}/${NETOPT_TAG}-*.conf)
        shopt -u nullglob
        items+=("${netopt_files[@]}")
    fi
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
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}Restore done.${NC}"
}

self_update() {
    echo -e "${YELLOW}Local version: $SCRIPT_VERSION${NC}"
    echo -e "${YELLOW}Changes: DNS/IPv6 bug fixes, idempotent sysctl.d persistence, UDP${NC}"
    echo -e "${YELLOW}optimizer, TCP noise fixer, Hetzner MTU fixer, full DNS reset, SNI${NC}"
    echo -e "${YELLOW}scanner, full uninstall. See the header comment for the full list.${NC}"
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

# ========== IPv6 ==========
# Shared, fixed implementation. Root causes addressed for "disable doesn't
# actually disable anything when I click it":
#  - only writing conf.all/conf.default never touched already-existing
#    per-interface values, which some renderers (netplan/NetworkManager)
#    can re-assert, effectively overriding "all"
#  - nothing verified the write actually took effect, so a silent failure
#    (e.g. read-only /proc under some container/lockdown setups) looked
#    identical to success
#  - stale addresses/routes from before the change weren't flushed
_ipv6_apply() {
    local val="$1"   # 0 = enable, 1 = disable
    local ok=1
    sysctl -w net.ipv6.conf.all.disable_ipv6="$val" >/dev/null 2>&1 || ok=0
    sysctl -w net.ipv6.conf.default.disable_ipv6="$val" >/dev/null 2>&1 || ok=0
    sysctl -w net.ipv6.conf.lo.disable_ipv6="$val" >/dev/null 2>&1 || ok=0

    local f
    for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [ -e "$f" ] || continue
        echo "$val" > "$f" 2>/dev/null || ok=0
    done

    if [[ "$val" == "1" ]]; then
        local ifpath ifname
        for ifpath in /sys/class/net/*; do
            [ -e "$ifpath" ] || continue
            ifname=$(basename "$ifpath")
            [[ "$ifname" == "lo" ]] && continue
            ip -6 addr flush dev "$ifname" scope global 2>/dev/null
        done
    fi
    [[ "$ok" == "1" ]]
}

manage_ipv6() {
    echo -e "\n${YELLOW}IPv6 Management${NC}"
    echo -e "1) Disable IPv6"
    echo -e "2) Enable IPv6"
    echo -e "3) Back"
    read -p "Choice [1-3]: " c
    case $c in
        1)
            if _ipv6_apply 1; then
                echo -e "${GREEN}IPv6 disabled on all current interfaces.${NC}"
            else
                echo -e "${RED}One or more sysctl writes failed - see any errors above.${NC}"
            fi
            local live
            live=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
            echo -e "${YELLOW}Verified state (net.ipv6.conf.all.disable_ipv6): $live${NC}"
            read -p "Persist across reboot? (y/n): " persist
            if [[ "$persist" =~ ^[Yy]$ ]]; then
                sysctl_persist "ipv6-disable" "net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1"
            fi
            ;;
        2)
            _ipv6_apply 0
            sysctl_unpersist "ipv6-disable"
            echo -e "${GREEN}IPv6 re-enabled. A reboot (or networking restart) may be needed to get${NC}"
            echo -e "${GREEN}addresses back via SLAAC/DHCPv6.${NC}"
            ;;
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
# TCP MUX Configuration (Enhanced) - now persists idempotently via
# sysctl.d instead of only applying at runtime, and uses fq (not
# fq_codel) to stay consistent with the BBR profile it also sets.
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

    local content
    content=$(cat <<'EOT'
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10
net.core.rmem_default = 262144
net.core.wmem_default = 262144
EOT
)
    sysctl_persist "tcpmux" "$content"

    echo -e "${GREEN}TCP MUX configured with performance optimizations (persisted).${NC}"
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

# delete_vxlan_tunnel now takes an optional "yes" arg to skip its own
# confirm prompt when it's called from reset_all/full_uninstall, which
# already asked for confirmation once - previously it always prompted
# again even inside an already-confirmed full reset.
delete_vxlan_tunnel() {
    local silent="${1:-no}"
    if [[ "$silent" != "yes" ]]; then
        confirm_action "Delete VXLAN100 & systemd service?" || return 1
    fi
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

uninstall_haproxy_full() {
    if ! confirm_action "Uninstall HAProxy completely?"; then return; fi
    echo -e "${YELLOW}Stopping and removing HAProxy...${NC}"
    systemctl stop haproxy 2>/dev/null
    systemctl disable haproxy 2>/dev/null
    apt purge -y haproxy 2>/dev/null
    apt autoremove -y 2>/dev/null
    echo -e "${GREEN}HAProxy completely removed.${NC}"
}

timezone_fixer() {
    echo -e "${YELLOW}Setting timezone to Asia/Tehran...${NC}"
    timedatectl set-timezone Asia/Tehran 2>/dev/null || {
        echo -e "${RED}timedatectl not available, trying manual...${NC}"
        ln -sf /usr/share/zoneinfo/Asia/Tehran /etc/localtime
    }
    echo -e "${GREEN}Timezone set to $(timedatectl | grep "Time zone" | awk '{print $3}')${NC}"
}

# BBR + fq_codel: an alternate high-throughput profile (kept separate from
# "Install BBR Optimization" since fq_codel vs fq is a real trade-off, not
# a bug - fq_codel handles mixed/bursty traffic and bufferbloat better,
# plain fq gives BBR more accurate pacing). Now idempotent.
bbr_fq_codel() {
    echo -e "${YELLOW}Applying BBR + fq_codel high-throughput profile...${NC}"
    print_separator

    modprobe nf_conntrack 2>/dev/null
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo 1012144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
    fi

    local content
    content=$(cat <<'EOT'
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.default_qdisc = fq_codel
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.ip_local_port_range = 10240 65535
net.core.somaxconn = 65535
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_mem = 2097152 3145728 4194304
net.ipv4.tcp_slow_start_after_idle = 0
fs.file-max = 2097152
EOT
)
    sysctl_persist "fqcodel" "$content"

    if ! grep -q "netopt soft nofile" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<EOT
# netopt soft nofile - added by $SCRIPT_NAME
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOT
    fi
    echo -e "${GREEN}BBR+fq_codel profile applied.${NC}"
    echo -e "${YELLOW}This uses fq_codel (better for mixed/bufferbloat-heavy traffic). For pure${NC}"
    echo -e "${YELLOW}BBR pacing accuracy, use 'Install BBR Optimization' instead (uses fq).${NC}"
}
# ===============================================================

nameserver_fixer() {
    echo -e "${YELLOW}Resetting DNS to 1.1.1.1 and 8.8.8.8...${NC}"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
    echo -e "${GREEN}DNS reset.${NC}"
}

# IPv6 Disable full: now a thin wrapper around the fixed _ipv6_apply, so it
# gets the same per-interface loop + flush + verification, and always
# persists (that's the whole point of the "full/permanent" variant).
ipv6_disable_full() {
    echo -e "${YELLOW}Disabling IPv6 completely (persisted)...${NC}"
    if _ipv6_apply 1; then
        sysctl_persist "ipv6-disable" "net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1"
        echo -e "${GREEN}IPv6 disabled on all interfaces and persisted across reboots.${NC}"
    else
        echo -e "${RED}Some sysctl writes failed - check kernel IPv6 support.${NC}"
    fi
}

# ========== NEW: Enable IPv6 ==========
# Re-enables IPv6 and persists it in /etc/sysctl.conf:
#  1) drops any existing net.ipv6.conf.(all|default).disable_ipv6 lines
#  2) appends =0 for both
#  3) applies them live with sysctl -w
#  4) reloads everything with sysctl --system
# Also removes the 90-netopt-ipv6-disable.conf drop-in (created by menu 28 /
# Manage IPv6 -> Disable) so a leftover disable_ipv6=1 can't fight this.
enable_ipv6() {
    echo -e "${YELLOW}Enabling IPv6 (persisting in /etc/sysctl.conf)...${NC}"
    print_separator

    sysctl_unpersist "ipv6-disable"

    touch /etc/sysctl.conf
    if sed -i -E '/^[[:space:]]*net\.ipv6\.conf\.(all|default)\.disable_ipv6[[:space:]]*=/d' /etc/sysctl.conf && \
       printf '\nnet.ipv6.conf.all.disable_ipv6=0\nnet.ipv6.conf.default.disable_ipv6=0\n' >> /etc/sysctl.conf && \
       sysctl -w net.ipv6.conf.all.disable_ipv6=0 && \
       sysctl -w net.ipv6.conf.default.disable_ipv6=0; then
        sysctl --system >/dev/null 2>&1
        local live
        live=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        if [[ "$live" == "0" ]]; then
            echo -e "${GREEN}IPv6 enabled (net.ipv6.conf.all.disable_ipv6 = 0) and persisted.${NC}"
            echo -e "${YELLOW}If no IPv6 address appears yet, restart networking or reboot to get one via SLAAC/DHCPv6.${NC}"
        else
            echo -e "${RED}Setting was written but the live value is still: $live${NC}"
        fi
    else
        echo -e "${RED}Failed to enable IPv6 - see errors above.${NC}"
        return 1
    fi
}

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
            if ! grep -q "ethtool -K $IF" /etc/rc.local 2>/dev/null; then
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
            if ! grep -q "ip link set dev $IF txqueuelen" /etc/rc.local 2>/dev/null; then
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

    # FIX: this used to "cat > /etc/sysctl.conf" and clobber the WHOLE file,
    # silently discarding anything in there this script didn't put there.
    # Now it writes its own sysctl.d drop-in instead (still backed up first
    # by backup_files(), but no longer destructive by default).
    step6() {
        echo -e "${YELLOW}Step 6: Applying sysctl configuration...${NC}"
        local content
        content=$(cat <<'EOT'
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
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.dev_weight = 64
net.core.default_qdisc = fq
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.optmem_max = 65536
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_rmem = 8192 262144 8388608
net.ipv4.tcp_wmem = 8192 262144 8388608
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
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
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOT
)
        sysctl_persist "cpu" "$content"
        echo -e "${GREEN}sysctl configuration applied (via ${NETOPT_TAG}-cpu.conf, /etc/sysctl.conf left untouched)${NC}"
    }

    advanced_optimization() {
        echo -e "${YELLOW}Applying advanced server optimization...${NC}"
        local content
        content=$(cat <<'EOT'
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_tw_buckets = 200000
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_ecn = 2
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
EOT
)
        sysctl_persist "cpu-advanced" "$content"
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
            if ! grep -q "ip link set dev $IF mtu" /etc/rc.local 2>/dev/null; then
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
        sysctl_unpersist "cpu"
        sysctl_unpersist "cpu-advanced"
        local IF=$(get_interface)
        if [[ -n "$IF" ]]; then
            tc qdisc del dev $IF root 2>/dev/null
            ethtool -K $IF tso on gso on gro on 2>/dev/null
            ip link set dev $IF txqueuelen 1000
        fi
        if [[ -f /etc/rc.local ]]; then
            printf '#!/bin/bash\nexit 0\n' > /etc/rc.local
        fi
        systemctl stop irqbalance 2>/dev/null
        systemctl disable irqbalance 2>/dev/null
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

# ========== NEW: SNI / CDN latency scanner ==========
# Measures TLS handshake time (TCP connect + SNI-based TLS handshake, a
# more representative number than a bare ICMP ping for HTTPS/SNI use) to a
# static list of well-known global CDN/cloud hostnames, ranks them by
# latency, and remembers what it already showed you in SNI_HISTORY_FILE so
# a repeat scan surfaces fresh candidates instead of the same ones again.
SNI_CANDIDATE_DOMAINS=(
  "www.cloudflare.com" "cdnjs.cloudflare.com" "speed.cloudflare.com"
  "www.google.com" "fonts.gstatic.com" "www.gstatic.com"
  "d1.awsstatic.com" "s3.amazonaws.com" "aws.amazon.com"
  "www.microsoft.com" "ajax.aspnetcdn.com" "www.office.com"
  "www.fastly.com" "fastly.jsdelivr.net" "cdn.jsdelivr.net"
  "www.akamai.com" "images-na.ssl-images-amazon.com"
  "www.bing.com" "www.wikipedia.org" "upload.wikimedia.org"
  "www.apple.com" "www.icloud.com"
  "unpkg.com" "cdn.statically.io" "www.jsdelivr.net"
  "www.digitalocean.com" "www.linode.com" "www.oracle.com"
  "www.github.com" "raw.githubusercontent.com" "objects.githubusercontent.com"
  "www.npmjs.com" "registry.npmjs.org"
)

sni_scanner() {
    echo -e "${YELLOW}SNI / CDN latency scanner${NC}"
    echo -e "${BLUE}Times the TCP+TLS handshake to well-known global CDN hostnames and ranks${NC}"
    echo -e "${BLUE}them by latency. Hostnames already shown in a previous scan are skipped${NC}"
    echo -e "${BLUE}so repeated scans surface fresh candidates instead of repeats.${NC}"
    print_separator

    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}openssl not found - required for TLS timing (apt-get install -y openssl).${NC}"
        return 1
    fi

    mkdir -p "$BACKUP_DIR"
    touch "$SNI_HISTORY_FILE"

    local results=() domain ip t1 t2 ms rc
    declare -A seen_ip=()
    for domain in "${SNI_CANDIDATE_DOMAINS[@]}"; do
        grep -qxF "$domain" "$SNI_HISTORY_FILE" 2>/dev/null && continue

        ip=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1; exit}')
        [[ -z "$ip" ]] && continue
        [[ -n "${seen_ip[$ip]:-}" ]] && continue
        seen_ip["$ip"]=1

        t1=$(date +%s%N)
        timeout 3 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null >/dev/null 2>&1
        rc=$?
        t2=$(date +%s%N)
        [[ $rc -ne 0 ]] && continue

        ms=$(( (t2 - t1) / 1000000 ))
        results+=("$ms|$domain|$ip")
    done

    if [ ${#results[@]} -eq 0 ]; then
        echo -e "${YELLOW}No new candidates responded (or the whole list has already been shown).${NC}"
        read -p "Clear scan history and rescan the full list? (y/n): " clr
        [[ "$clr" =~ ^[Yy]$ ]] && : > "$SNI_HISTORY_FILE"
        return 0
    fi

    mapfile -t results < <(printf '%s\n' "${results[@]}" | sort -t'|' -k1,1n)

    print_separator
    printf "%-6s %-35s %s\n" "ms" "SNI / hostname" "IP"
    print_separator
    local shown=0 r ms2 domain2 ip2
    for r in "${results[@]}"; do
        [ $shown -ge 10 ] && break
        IFS='|' read -r ms2 domain2 ip2 <<< "$r"
        printf "%-6s %-35s %s\n" "$ms2" "$domain2" "$ip2"
        echo "$domain2" >> "$SNI_HISTORY_FILE"
        ((shown++))
    done
    print_separator
    local scanned_total
    scanned_total=$(wc -l < "$SNI_HISTORY_FILE" 2>/dev/null || echo 0)
    echo -e "${GREEN}Shown this run: $shown | Total shown so far: $scanned_total / ${#SNI_CANDIDATE_DOMAINS[@]}${NC}"
}

reset_all() {
    if ! confirm_action "Reset ALL changes to default?"; then return; fi
    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>/dev/null
    CURRENT_MTU=1500
    reset_dns
    sysctl_unpersist_all
    _ipv6_apply 0
    iptables -t nat -F 2>/dev/null
    delete_vxlan_tunnel "yes"
    command -v haproxy >/dev/null 2>&1 && { systemctl disable --now haproxy 2>/dev/null || true; }
    rm -f "$CONFIG_FILE" /etc/tcp_mux.conf
    echo -e "${GREEN}All reset to default.${NC}"
}

# ========== NEW: FULL UNINSTALL ==========
full_uninstall() {
    echo -e "${RED}${BOLD}=== FULL UNINSTALL ===${NC}"
    echo "This attempts to undo every change this script can make:"
    echo "  - MTU, DNS, IPv6, BBR/UDP/TCP-noise/CPU-optimizer sysctl tuning"
    echo "  - VXLAN tunnel + its systemd service"
    echo "  - HAProxy (full package purge)"
    echo "  - the GitHub-fixer /etc/hosts entry"
    echo "  - CPU Optimizer's tc/ethtool/rc.local/irqbalance changes"
    echo "  - this script's own config, log and backup files (optional, asked separately)"
    if ! confirm_action "This cannot be undone. Continue?"; then return; fi

    sysctl_unpersist_all
    _ipv6_apply 0

    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>/dev/null
    reset_dns

    delete_vxlan_tunnel "yes"

    if command -v haproxy >/dev/null 2>&1; then
        systemctl stop haproxy 2>/dev/null
        systemctl disable haproxy 2>/dev/null
        apt purge -y haproxy 2>/dev/null
        apt autoremove -y 2>/dev/null
    fi

    sed -i '/raw.githubusercontent.com/d' /etc/hosts 2>/dev/null

    iptables -t nat -F 2>/dev/null

    local IF
    IF=$(ip -4 route show default | awk '{print $5}' | head -1)
    if [[ -n "$IF" ]]; then
        tc qdisc del dev "$IF" root 2>/dev/null
        ethtool -K "$IF" tso on gso on gro on 2>/dev/null
        ip link set dev "$IF" txqueuelen 1000 2>/dev/null
    fi
    [[ -f /etc/sysctl.conf.backup ]] && cp /etc/sysctl.conf.backup /etc/sysctl.conf
    [[ -f /etc/resolv.conf.backup ]] && cp /etc/resolv.conf.backup /etc/resolv.conf
    [[ -f /etc/rc.local ]] && printf '#!/bin/bash\nexit 0\n' > /etc/rc.local
    systemctl stop irqbalance 2>/dev/null
    systemctl disable irqbalance 2>/dev/null

    read -p "Also revert server timezone to UTC? (y/n): " tz
    [[ "$tz" =~ ^[Yy]$ ]] && timedatectl set-timezone UTC 2>/dev/null

    sysctl --system >/dev/null 2>&1

    read -p "Also delete this script's backups/config/log files? (y/n): " wipe
    if [[ "$wipe" =~ ^[Yy]$ ]]; then
        rm -rf "$BACKUP_DIR" "$CONFIG_FILE" "$LOG_FILE" /etc/tcp_mux.conf
    fi

    echo -e "${GREEN}Full uninstall complete. A reboot is recommended to confirm a clean state.${NC}"
}

show_menu() {
    load_config
    detect_distro
    while true; do
        show_header
        echo -e "${BOLD}Main Menu:${NC}"
        echo " 1) Install BBR Optimization (stable TCP profile)"
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
        echo "22) GitHub Fixer (add raw.githubusercontent.com)"
        echo "23) Uninstall HAProxy (complete removal)"
        echo "24) Server Timezone Fixer (set to Asia/Tehran)"
        echo "25) BBR + fq_codel (alternate high-throughput profile)"
        echo "26) Nameserver Fixer (quick reset: 1.1.1.1 & 8.8.8.8)"
        echo "27) Uninstall BBR"
        echo "28) IPv6 Fixer (disable IPv6 permanently)"
        echo "29) System Lock Fixer (clear stuck dpkg/apt locks)"
        echo "30) UDP Packet-Loss / Drop Optimizer"
        echo "31) TCP Noise Fixer (reordering/jitter tolerance)"
        echo "32) Hetzner MTU Fixer (reset eth0 MTU to 1500)"
        echo "33) Full DNS Reset (systemd-resolved restart+flush+status)"
        echo "34) SNI / CDN Latency Scanner"
        echo "35) FULL UNINSTALL (remove every change, restore original state)"
        echo "36) Enable IPv6 (re-enable + persist in /etc/sysctl.conf)"
        echo "37) Exit"
        read -p "Enter your choice [1-37]: " choice
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
            22) github_fixer ;;
            23) uninstall_haproxy_full ;;
            24) timezone_fixer ;;
            25) bbr_fq_codel ;;
            26) nameserver_fixer ;;
            27) uninstall_bbr ;;
            28) ipv6_disable_full ;;
            29) system_lock_fixer ;;
            30) udp_optimizer ;;
            31) tcp_noise_fixer ;;
            32) hetzner_mtu_fixer ;;
            33) reset_full_dns ;;
            34) sni_scanner ;;
            35) full_uninstall ;;
            36) enable_ipv6 ;;
            37) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
            *)  echo -e "${RED}Invalid option!${NC}" ;;
        esac
        read -p "Press [Enter] to continue..."
    done
}

check_requirements
check_root
show_menu
