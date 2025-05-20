#!/bin/bash

# UDP2RAW Professional Tunnel Manager - iPmartNetwork 2025

CYAN="\e[96m"
GREEN="\e[92m"
YELLOW="\e[93m"
RED="\e[91m"
MAGENTA="\e[95m"
NC="\e[0m"

UDP2RAW_DIR="/usr/local/bin"
UDP2RAW_PATH="$UDP2RAW_DIR/udp2raw"
UDP2RAW_URL_BASE="https://github.com/iPmartNetwork/UDPRAW-V2/releases/latest/download"

press_enter() {
    echo -e "\n${MAGENTA}Press Enter to continue... ${NC}"
    read
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   BIN="udp2raw_amd64";;
        armv7*|armv6*)  BIN="udp2raw_arm";;
        arm64|aarch64)  BIN="udp2raw_arm64";;
        mips*)          BIN="udp2raw_mips";;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1;;
    esac
}

network_optimization() {
    echo -e "${YELLOW}Applying network optimizations...${NC}"
    modprobe tcp_bbr 2>/dev/null
    echo "tcp_bbr" | tee /etc/modules-load.d/bbr.conf >/dev/null
    cat << EOF >> /etc/sysctl.conf

# Optimized for UDP2RAW
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_congestion_control=bbr
net.core.netdev_max_backlog=250000
net.core.somaxconn=4096
EOF
    sysctl -p >/dev/null 2>&1
    ulimit -n 1048576
    echo -e "${GREEN}Network optimization applied.${NC}"
    sleep 1
}

install_udp2raw() {
    clear
    detect_arch
    echo -e "${YELLOW}Installing dependencies & udp2raw for [$ARCH]...${NC}"
    apt-get update -y >/dev/null
    apt-get install curl wget -y >/dev/null
    display_fancy_progress 12

    mkdir -p $UDP2RAW_DIR
    URL="$UDP2RAW_URL_BASE/$BIN"
    if ! curl -L --retry 3 -o "$UDP2RAW_PATH" "$URL"; then
        echo -e "${RED}Download failed. Check your internet or proxy.${NC}"
        return 1
    fi
    chmod +x "$UDP2RAW_PATH"

    # فایل را بررسی کن!
    if ! file "$UDP2RAW_PATH" | grep -qi "executable"; then
        echo -e "${RED}Downloaded file is not a valid executable!${NC}"
        rm -f "$UDP2RAW_PATH"
        return 1
    fi
    echo -e "${GREEN}udp2raw installed successfully for [$ARCH].${NC}"
    network_optimization
}

display_fancy_progress() {
    local duration=$1
    local sleep_interval=0.08
    local progress=0
    local bar_length=40
    while [ $progress -lt $duration ]; do
        printf "\r${CYAN} ["
        for ((i = 0; i < bar_length; i++)); do
            if [ $i -lt $((progress * bar_length / duration)) ]; then
                printf "${GREEN}█${CYAN}"
            else
                printf "░"
            fi
        done
        printf "] ${YELLOW}%d%%${NC}" $((progress*100/duration))
        progress=$((progress + 1))
        sleep $sleep_interval
    done
    echo
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

show_status_panel() {
    clear
    echo -e "${CYAN}--------- [ UDP2RAW Status Panel ] ----------${NC}"
    for svc in udp2raw-s udp2raw-c; do
        if systemctl is-active --quiet $svc.service; then
            echo -e "${GREEN}[$svc] is running ✅${NC}"
        else
            echo -e "${RED}[$svc] is stopped ❌${NC}"
        fi
    done
    echo -e "${CYAN}---------------------------------------------${NC}\n"
}

test_ping_jitter() {
    local target=$1
    echo -e "${MAGENTA}Testing latency and jitter to $target ...${NC}"
    if command -v ping &> /dev/null; then
        ping -c 10 "$target" | tail -2
    else
        echo -e "${RED}ping command not found.${NC}"
    fi
}

configure_tunnel() {
    local mode role
    clear
    echo -e "${CYAN}Set Tunnel Role:${NC} ${GREEN}[1] Server (Outside)   [2] Client (Inside)${NC}"
    read -p "Enter [1/2]: " role
    if [ "$role" = "1" ]; then
        mode="-s"
        echo -e "${YELLOW}Choose listen IP mode:${NC} [1] IPv4 (0.0.0.0)  [2] IPv6 ([::])"
        read -p "Your choice: " ipmode
        [ "$ipmode" = "2" ] && listenip="[::]" || listenip="0.0.0.0"
        read -p "Local Listen Port [default: 443]: " lport; lport=${lport:-443}
        while ! validate_port "$lport"; do
            echo -e "${RED}Invalid port. Enter again:${NC}"
            read lport
        done
        read -p "Forward to local WireGuard port [default: 40600]: " fport; fport=${fport:-40600}
        while ! validate_port "$fport"; do
            echo -e "${RED}Invalid port. Enter again:${NC}"
            read fport
        done
        read -p "Password for UDP2RAW: " pass
        while [ -z "$pass" ]; do
            echo -e "${RED}Password cannot be empty:${NC}"; read pass
        done
        echo -e "${YELLOW}Raw Protocol Mode:${NC} [1] udp  [2] faketcp  [3] icmp"
        read -p "Your choice: " proto
        case $proto in 1) raw_mode="udp";; 2) raw_mode="faketcp";; 3) raw_mode="icmp";; *) raw_mode="udp";; esac

        cat << EOF > /etc/systemd/system/udp2raw-s.service
[Unit]
Description=UDP2RAW Server
After=network.target
[Service]
ExecStart=$UDP2RAW_PATH -s -l $listenip:$lport -r 127.0.0.1:$fport -k "$pass" --raw-mode $raw_mode --fix-gro --cipher-mode xor --sock-buf 4096000 --mtu 1500 -a
Restart=always
[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now udp2raw-s.service
        echo -e "${GREEN}Server (Outside) tunnel started.${NC}"
        test_ping_jitter "127.0.0.1"
    else
        mode="-c"
        echo -e "${YELLOW}Choose connect mode:${NC} [1] IPv4 [2] IPv6"
        read -p "Your choice: " ipmode
        [ "$ipmode" = "2" ] && remote_ip="IPv6" || remote_ip="IPv4"
        read -p "Local Listen Port [default: 40600]: " lport; lport=${lport:-40600}
        while ! validate_port "$lport"; do
            echo -e "${RED}Invalid port. Enter again:${NC}"
            read lport
        done
        read -p "Remote IP to connect: " raddr
        while [ -z "$raddr" ]; do
            echo -e "${RED}Remote address cannot be empty:${NC}"; read raddr
        done
        read -p "Remote Port [default: 443]: " rport; rport=${rport:-443}
        while ! validate_port "$rport"; do
            echo -e "${RED}Invalid port. Enter again:${NC}"
            read rport
        done
        read -p "Password (must match server): " pass
        while [ -z "$pass" ]; do
            echo -e "${RED}Password cannot be empty:${NC}"; read pass
        done
        echo -e "${YELLOW}Raw Protocol Mode:${NC} [1] udp  [2] faketcp  [3] icmp"
        read -p "Your choice: " proto
        case $proto in 1) raw_mode="udp";; 2) raw_mode="faketcp";; 3) raw_mode="icmp";; *) raw_mode="udp";; esac

        if [ "$remote_ip" = "IPv4" ]; then
            execstr="$UDP2RAW_PATH -c -l 0.0.0.0:$lport -r $raddr:$rport -k $pass --raw-mode $raw_mode --fix-gro --cipher-mode xor --sock-buf 4096000 --mtu 1500 -a"
        else
            execstr="$UDP2RAW_PATH -c -l [::]:$lport -r [$raddr]:$rport -k $pass --raw-mode $raw_mode --fix-gro --cipher-mode xor --sock-buf 4096000 --mtu 1500 -a"
        fi

        cat << EOF > /etc/systemd/system/udp2raw-c.service
[Unit]
Description=UDP2RAW Client
After=network.target
[Service]
ExecStart=$execstr
Restart=always
[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now udp2raw-c.service
        echo -e "${GREEN}Client (Inside) tunnel started.${NC}"
        test_ping_jitter "$raddr"
    fi
}

show_logs() {
    echo -e "${YELLOW}UDP2RAW Service Logs:${NC}\n"
    journalctl -u udp2raw-s.service -u udp2raw-c.service --no-pager --since "10 min ago" | tail -50
}

uninstall_udp2raw() {
    echo -e "${RED}Uninstalling UDP2RAW & cleaning up...${NC}"
    systemctl stop udp2raw-s.service udp2raw-c.service 2>/dev/null
    systemctl disable udp2raw-s.service udp2raw-c.service 2>/dev/null
    rm -f /etc/systemd/system/udp2raw-*.service $UDP2RAW_PATH
    systemctl daemon-reload
    echo -e "${GREEN}Uninstalled.${NC}"
}

main_menu() {
    while true; do
        show_status_panel
        echo -e "${MAGENTA}=========== UDP2RAW Tunnel Pro Menu ===========${NC}"
        echo -e "${YELLOW}1) Install / Update udp2raw"
        echo -e "2) Configure Tunnel"
        echo -e "3) Show Tunnel Logs"
        echo -e "4) Network Optimization"
        echo -e "5) Uninstall udp2raw"
        echo -e "0) Exit${NC}\n"
        read -p "$(echo -e "${GREEN}Choose an option [0-5]: ${NC}")" ch
        case $ch in
            1) install_udp2raw;;
            2) configure_tunnel;;
            3) show_logs;;
            4) network_optimization;;
            5) uninstall_udp2raw;;
            0) echo -e "${CYAN}Bye.${NC}"; exit 0;;
            *) echo -e "${RED}Invalid.${NC}";;
        esac
        press_enter
    done
}

# Start
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run this script as root.${NC}"
    exit 1
fi

main_menu
