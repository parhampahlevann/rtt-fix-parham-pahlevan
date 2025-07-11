#!/bin/bash
# Optimization script for ReverseTlsTunnel on Ubuntu 22.04 with interactive menu
# Goals: Reduce traffic, eliminate disconnections, lower ping, improve stability
# Features: Install, Uninstall, Status, Manual MTU/DNS, Fix Permission Denied, Reboot
# Author: Optimized for ReverseTlsTunnel by Grok
# License: MIT (shareable on GitHub)

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

# Check if running on Ubuntu 22.04
if ! lsb_release -d | grep -q "Ubuntu 22.04"; then
  echo "This script is designed for Ubuntu 22.04. Proceed with caution."
  read -p "Continue? (y/n): " confirm
  if [ "$confirm" != "y" ]; then
    exit 1
  fi
fi

# Log file
LOG_FILE="/var/log/rtt_optimization.log"

# Function to check and fix file permissions
check_permissions() {
  local file="$1"
  if [ -f "$file" ] && [ ! -w "$file" ]; then
    chmod u+w "$file" 2>/dev/null || { echo "Error: Cannot modify $file (Permission Denied)"; exit 1; }
  fi
}

# Function to install optimizations
install_optimizations() {
  echo "Installing optimizations..." | tee -a "$LOG_FILE"

  # Backup sysctl.conf
  check_permissions "/etc/sysctl.conf"
  cp /etc/sysctl.conf /etc/sysctl.conf.bak
  echo "Backed up sysctl.conf to /etc/sysctl.conf.bak" | tee -a "$LOG_FILE"

  # Enable BBR congestion control
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

  # Optimize TCP buffers
  echo "net.ipv4.tcp_rmem = 4096 87380 8388608" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_wmem = 4096 16384 4194304" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_window_scaling=1" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_low_latency=1" >> /etc/sysctl.conf

  # Enable TCP Fast Open
  echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf

  # Optimize MTU and MSS
  echo "net.ipv4.tcp_mtu_probing=1" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_base_mss=1024" >> /etc/sysctl.conf

  # Increase max connections
  echo "net.core.somaxconn=65535" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_max_syn_backlog=8192" >> /etc/sysctl.conf
  echo "net.core.netdev_max_backlog=5000" >> /etc/sysctl.conf

  # TCP Keepalive
  echo "net.ipv4.tcp_keepalive_time=300" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_keepalive_intvl=60" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_keepalive_probes=10" >> /etc/sysctl.conf

  # Apply sysctl changes
  sysctl -p >/dev/null 2>&1 || { echo "Error applying sysctl changes" | tee -a "$LOG_FILE"; exit 1; }
  echo "Applied TCP optimizations." | tee -a "$LOG_FILE"

  # Install and configure ufw
  apt-get update
  apt-get install -y ufw
  ufw allow 22/tcp
  ufw allow 443/tcp # Adjust based on ReverseTlsTunnel port
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  echo "Firewall configured with ufw." | tee -a "$LOG_FILE"

  # Install netdata for monitoring
  apt-get install -y netdata
  systemctl enable netdata
  systemctl start netdata
  echo "Netdata installed. Access at http://$(hostname -I | awk '{print $1}'):19999" | tee -a "$LOG_FILE"

  # Optimize ReverseTlsTunnel service
  if systemctl list-units | grep -q "rtt"; then
    check_permissions "/etc/security/limits.conf"
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf
    systemctl set-property rtt.service CPUSchedulingPolicy=rr CPUSchedulingPriority=20 IOSchedulingClass=best-effort IOSchedulingPriority=2
    systemctl daemon-reload
    systemctl restart rtt
    echo "ReverseTlsTunnel service optimized." | tee -a "$LOG_FILE"
  else
    echo "Warning: ReverseTlsTunnel service not found." | tee -a "$LOG_FILE"
  fi

  # Apply traffic shaping
  apt-get install -y iproute2
  tc qdisc add dev eth0 root tbf rate 10mbit burst 32kbit latency 50ms 2>/dev/null || echo "Warning: Traffic shaping already applied or eth0 not found." | tee -a "$LOG_FILE"
  echo "Traffic shaping applied." | tee -a "$LOG_FILE"

  echo "Installation completed at $(date)" | tee -a "$LOG_FILE"
}

# Function to uninstall optimizations
uninstall_optimizations() {
  echo "Uninstalling optimizations..." | tee -a "$LOG_FILE"

  # Restore sysctl.conf
  if [ -f "/etc/sysctl.conf.bak" ]; then
    check_permissions "/etc/sysctl.conf"
    mv /etc/sysctl.conf.bak /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo "Restored sysctl.conf." | tee -a "$LOG_FILE"
  else
    echo "Warning: sysctl.conf backup not found." | tee -a "$LOG_FILE"
  fi

  # Remove ufw
  if command -v ufw >/dev/null; then
    ufw --force reset
    apt-get purge -y ufw
    echo "Removed ufw." | tee -a "$LOG_FILE"
  fi

  # Remove netdata
  if command -v netdata >/dev/null; then
    systemctl stop netdata
    apt-get purge -y netdata
    echo "Removed netdata." | tee -a "$LOG_FILE"
  fi

  # Remove traffic shaping
  tc qdisc del dev eth0 root 2>/dev/null || echo "No traffic shaping to remove." | tee -a "$LOG_FILE"

  # Remove limits
  if [ -f "/etc/security/limits.conf" ]; then
    check_permissions "/etc/security/limits.conf"
    sed -i '/nofile 65535/d' /etc/security/limits.conf
    echo "Removed file descriptor limits." | tee -a "$LOG_FILE"
  fi

  # Reset rtt service optimizations
  if systemctl list-units | grep -q "rtt"; then
    systemctl set-property rtt.service CPUSchedulingPolicy=other CPUSchedulingPriority=0 IOSchedulingClass=idle IOSchedulingPriority=7
    systemctl daemon-reload
    systemctl restart rtt
    echo "Reset ReverseTlsTunnel service settings." | tee -a "$LOG_FILE"
  fi

  echo "Uninstallation completed at $(date)" | tee -a "$LOG_FILE"
}

# Function to show status
show_status() {
  echo "Optimization Status:" | tee -a "$LOG_FILE"
  echo "-------------------"
  echo "TCP Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "TCP Keepalive Time: $(sysctl -n net.ipv4.tcp_keepalive_time)"
  echo "Max Connections (somaxconn): $(sysctl -n net.core.somaxconn)"
  echo "MTU Probing: $(sysctl -n net.ipv4.tcp_mtu_probing)"
  echo "Firewall Status:"
  ufw status 2>/dev/null || echo "ufw not installed."
  echo "Netdata Status:"
  systemctl status netdata --no-pager 2>/dev/null || echo "Netdata not installed."
  echo "ReverseTlsTunnel Service:"
  systemctl status rtt --no-pager 2>/dev/null || echo "ReverseTlsTunnel not running."
  echo "Current MTU (eth0): $(ip link show eth0 | grep mtu | awk '{print $5}')"
  echo "Current DNS: $(cat /etc/resolv.conf | grep nameserver)"
  echo "-------------------" | tee -a "$LOG_FILE"
}

# Function to change MTU and DNS
change_mtu_dns() {
  echo "Change MTU and DNS Settings"
  echo "Current MTU (eth0): $(ip link show eth0 | grep mtu | awk '{print $5}')"
  read -p "Enter new MTU (e.g., 1400, press Enter to skip): " new_mtu
  if [ -n "$new_mtu" ]; then
    ip link set dev eth0 mtu "$new_mtu" 2>/dev/null || { echo "Error setting MTU." | tee -a "$LOG_FILE"; return 1; }
    echo "Set MTU to $new_mtu on eth0." | tee -a "$LOG_FILE"
  fi

  echo "Current DNS: $(cat /etc/resolv.conf | grep nameserver)"
  read -p "Enter new DNS server (e.g., 8.8.8.8, press Enter to skip): " new_dns
  if [ -n "$new_dns" ]; then
    check_permissions "/etc/resolv.conf"
    echo "nameserver $new_dns" > /etc/resolv.conf
    echo "Set DNS to $new_dns." | tee -a "$LOG_FILE"
  fi
}

# Function to reboot the system
reboot_system() {
  echo "Rebooting system..." | tee -a "$LOG_FILE"
  reboot
}

# Interactive Menu
while true; do
  echo "ReverseTlsTunnel Optimization Menu"
  echo "1. Install optimizations"
  echo "2. Uninstall optimizations"
  echo "3. Show status"
  echo "4. Change MTU and DNS"
  echo "5. Exit"
  echo "6. Reboot"
  read -p "Select an option [1-6]: " choice

  case $choice in
    1)
      install_optimizations
      ;;
    2)
      uninstall_optimizations
      ;;
    3)
      show_status
      ;;
    4)
      change_mtu_dns
      ;;
    5)
      echo "Exiting..." | tee -a "$LOG_FILE"
      exit 0
      ;;
    6)
      reboot_system
      ;;
    *)
      echo "Invalid option. Please select 1-6."
      ;;
  esac
done
