#!/bin/bash
# =============================================================================
#  CONFIG SNAPSHOT TOOL  —  Pre / Post Reboot
#  Supports : SLES 9/10/11/12/15  |  RHEL/CentOS 5/6/7/8/9
#             Ubuntu 18/20/22      |  Debian-based distros
#  Author   : Linux Infrastructure Team
#  Version  : 2.0
#
#  Usage:
#    sudo bash config_snapshot.sh --mode pre
#    sudo bash config_snapshot.sh --mode post
#    sudo bash config_snapshot.sh --mode post --archive
#    sudo bash config_snapshot.sh --mode post --pre-dir /tmp/snapshots/srv01_pre_20250601_120000
#    sudo bash config_snapshot.sh --mode pre  --skip 11        # skip packages
#    sudo bash config_snapshot.sh --mode pre  --skip 11,16     # skip packages + checksums
#    sudo bash config_snapshot.sh --mode pre  --skip packages  # skip by name
#
#  Module numbers for --skip:
#    01=os_info  02=kernel   03=cpu      04=memory   05=hardware
#    06=disk     07=network  08=ntp      09=ports    10=firewall
#    11=packages 12=services 13=security 14=cron     15=users
#    16=checksums 17=processes 18=logs   19=boot
#
#  Output:  /tmp/snapshots/<hostname>_<mode>_<timestamp>/
#           /tmp/snapshots/<hostname>_<mode>_<timestamp>.html
# =============================================================================

# ---------------------------------------------------------------------------
# Bash version note:
#   SLES 9  → bash 2.05b   SLES 10/11 → bash 3.x   SLES 12/15 → bash 4+
#   RHEL 5/6 → bash 3.x    RHEL 7+    → bash 4+     Ubuntu 18+ → bash 4.4+
# Script uses only POSIX-safe constructs — no ${var^^}, no bash 4+ arrays.
# Uppercase conversion uses tr, which works on all versions back to bash 2.
# ---------------------------------------------------------------------------

set -uo pipefail

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: Run as root (sudo)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Colours  (safe for any terminal; disabled if not interactive)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m';  WHITE='\033[1;37m'
    BOLD='\033[1m';    DIM='\033[2m';      RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; WHITE=''
    BOLD=''; DIM=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Defaults / globals
# ---------------------------------------------------------------------------
MODE=""
ARCHIVE=0
PRE_DIR_OVERRIDE=""
BASE_DIR="/tmp/snapshots"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
SNAPSHOT_DIR=""
HTML_REPORT=""
LOG_FILE=""
START_TIME=$(date +%s)
OS_NAME=""; OS_ID=""; OS_VERSION=""; OS_PRETTY=""; OS_FAMILY=""; OS_MAJOR=""
INIT_SYSTEM=""   # systemd | sysv | upstart

# Module skip list — comma-separated module numbers or names
# e.g. "11" or "11,20" or "packages" or "boot"
SKIP_MODULES=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)        MODE="$2";             shift 2 ;;
        --archive)     ARCHIVE=1;             shift   ;;
        --pre-dir)     PRE_DIR_OVERRIDE="$2"; shift 2 ;;
        --skip)        SKIP_MODULES="$2";     shift 2 ;;
        --help|-h)
            grep '^#  ' "$0" | sed 's/^#  //'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "ERROR: --mode pre|post is required." >&2
    exit 1
fi
if [ "$MODE" != "pre" ] && [ "$MODE" != "post" ]; then
    echo "ERROR: --mode must be 'pre' or 'post'." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------
SNAPSHOT_DIR="${BASE_DIR}/${HOSTNAME_SHORT}_${MODE}_${TIMESTAMP}"
HTML_REPORT="${BASE_DIR}/${HOSTNAME_SHORT}_${MODE}_${TIMESTAMP}.html"
LOG_FILE="${SNAPSHOT_DIR}/00_snapshot.log"

mkdir -p "$SNAPSHOT_DIR" || { echo "ERROR: Cannot create $SNAPSHOT_DIR" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "$1" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# OS Detection  — must handle /etc/os-release (modern) and legacy files
# ---------------------------------------------------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="${NAME:-unknown}"
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_PRETTY="${PRETTY_NAME:-$NAME}"
    elif [ -f /etc/redhat-release ]; then
        OS_PRETTY=$(cat /etc/redhat-release)
        OS_NAME="$OS_PRETTY"
        OS_VERSION=$(echo "$OS_PRETTY" | grep -oE '[0-9]+\.[0-9]+' | head -1)
        OS_ID="rhel"
    elif [ -f /etc/SuSE-release ]; then
        OS_PRETTY=$(head -1 /etc/SuSE-release)
        OS_NAME="$OS_PRETTY"
        OS_VERSION=$(grep VERSION /etc/SuSE-release | awk '{print $3}')
        OS_ID="sles"
    elif [ -f /etc/debian_version ]; then
        OS_VERSION=$(cat /etc/debian_version)
        OS_NAME="Debian"; OS_ID="debian"
        OS_PRETTY="Debian $OS_VERSION"
    else
        OS_NAME="Unknown"; OS_ID="unknown"; OS_VERSION="unknown"; OS_PRETTY="Unknown Linux"
    fi

    # Family
    case "$OS_ID" in
        rhel|centos|rocky|almalinux|fedora|ol) OS_FAMILY="rhel" ;;
        sles|suse|opensuse|opensuse-leap|opensuse-tumbleweed) OS_FAMILY="suse" ;;
        ubuntu|debian|linuxmint|raspbian) OS_FAMILY="debian" ;;
        *) OS_FAMILY="unknown" ;;
    esac

    # Major version
    OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)

    # Init system detection
    if   command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif [ -f /etc/init/rc-sysinit.conf ] || command -v initctl >/dev/null 2>&1; then
        INIT_SYSTEM="upstart"
    else
        INIT_SYSTEM="sysv"
    fi
}

# ---------------------------------------------------------------------------
# Compatibility helpers
# (try modern tool first, fall back to legacy equivalent)
# ---------------------------------------------------------------------------

# Network interface listing
compat_ip_addr() {
    if command -v ip >/dev/null 2>&1; then
        ip addr show
    else
        ifconfig -a 2>/dev/null || echo "ifconfig/ip not available"
    fi
}

compat_ip_route() {
    if command -v ip >/dev/null 2>&1; then
        ip route show
    else
        route -n 2>/dev/null || echo "route not available"
    fi
}

compat_ip_neigh() {
    if command -v ip >/dev/null 2>&1; then
        ip neigh show 2>/dev/null || true
    fi
    arp -n 2>/dev/null || true
}

compat_ip_link_stats() {
    if command -v ip >/dev/null 2>&1; then
        ip -s link show
    else
        netstat -i 2>/dev/null || echo "Not available"
    fi
}

# Listening ports
compat_listen_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null
    else
        echo "ss/netstat not available"
    fi
}

compat_connections() {
    if command -v ss >/dev/null 2>&1; then
        ss -tnp 2>/dev/null | head -60
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tnp 2>/dev/null | head -60
    fi
}

compat_socket_summary() {
    if command -v ss >/dev/null 2>&1; then
        ss -s 2>/dev/null
    elif command -v netstat >/dev/null 2>&1; then
        netstat -s 2>/dev/null | head -40
    fi
}

# Block device listing
compat_lsblk() {
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || lsblk
    else
        fdisk -l 2>/dev/null | grep "^Disk /" || echo "lsblk not available"
    fi
}

# Uptime human-readable
compat_uptime_pretty() {
    uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | cut -d, -f1-2
}

# timedatectl / legacy timezone
compat_timezone() {
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl 2>/dev/null | grep -E "Time zone|Local time|NTP"
    else
        echo "Timezone: $(date +%Z)"
        [ -f /etc/localtime ] && ls -la /etc/localtime 2>/dev/null
        [ -f /etc/timezone ] && cat /etc/timezone 2>/dev/null
        [ -f /etc/sysconfig/clock ] && cat /etc/sysconfig/clock 2>/dev/null
    fi
}

# findmnt / legacy mounts
compat_mounts() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt --real
    else
        mount | column -t 2>/dev/null || mount
    fi
}

# journalctl / legacy syslog
compat_recent_logs() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -n 60 --no-pager 2>/dev/null
    else
        tail -60 /var/log/messages 2>/dev/null \
            || tail -60 /var/log/syslog 2>/dev/null \
            || echo "No log source available"
    fi
}

# Service listing
compat_services_enabled() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl list-unit-files --type=service --state=enabled 2>/dev/null
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --list 2>/dev/null | grep ":on"
    elif command -v update-rc.d >/dev/null 2>&1; then
        ls /etc/rc3.d/ 2>/dev/null | grep '^S'
    fi
}

compat_services_running() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl list-units --type=service --state=running 2>/dev/null
    elif command -v service >/dev/null 2>&1; then
        service --status-all 2>/dev/null | grep "[ +]" || true
    fi
}

compat_services_failed() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl list-units --state=failed 2>/dev/null
    fi
}

compat_runlevel() {
    if command -v runlevel >/dev/null 2>&1; then
        runlevel 2>/dev/null
    elif [ -f /etc/inittab ]; then
        grep "^id:" /etc/inittab | head -1
    fi
}

# NTP check
compat_ntp_status() {
    if command -v chronyc >/dev/null 2>&1; then
        echo "--- Chrony tracking ---"
        chronyc tracking 2>/dev/null
        echo ""
        echo "--- Chrony sources ---"
        chronyc sources -v 2>/dev/null
    fi
    if command -v ntpq >/dev/null 2>&1; then
        echo "--- NTP peers ---"
        ntpq -p 2>/dev/null
    fi
    if command -v ntpstat >/dev/null 2>&1; then
        echo "--- NTP stat ---"
        ntpstat 2>/dev/null
    fi
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        echo "--- timedatectl ---"
        timedatectl 2>/dev/null
    fi
}

# md5sum wrapper (SLES9 uses md5sum, others same)
compat_md5() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" 2>/dev/null
    elif command -v md5 >/dev/null 2>&1; then
        md5 "$1" 2>/dev/null
    fi
}

# Count listen ports
count_listen_ports() {
    compat_listen_ports | grep -cE "LISTEN|udp" 2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# Module skip helper
# should_skip <module_number> <module_name>
# Returns 0 (true/skip) if the module is in the SKIP_MODULES list
# Accepts match by number (e.g. "11") or name keyword (e.g. "packages")
# ---------------------------------------------------------------------------
should_skip() {
    local num="$1" name="$2"
    [ -z "$SKIP_MODULES" ] && return 1   # nothing to skip
    # Check each comma-separated token
    local IFS_ORIG="$IFS"
    IFS=","
    for token in $SKIP_MODULES; do
        IFS="$IFS_ORIG"
        # strip whitespace
        token=$(echo "$token" | tr -d ' ')
        if [ "$token" = "$num" ] || [ "$token" = "$name" ]; then
            # Print a visible SKIPPED line so engineers see it in the run output
            local padded
            padded=$(printf "%-38s" "Module ${num} (${name})")
            echo -e "  ${YELLOW}[~]${RESET} ${WHITE}${padded}${RESET} ${YELLOW}SKIPPED${RESET}   ${DIM}excluded via --skip${RESET}"
            return 0   # match — should skip
        fi
        IFS=","
    done
    IFS="$IFS_ORIG"
    return 1   # no match — do not skip
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
print_banner() {
    clear 2>/dev/null || true
    local mode_upper
    mode_upper=$(echo "$MODE" | tr '[:lower:]' '[:upper:]')
    local color
    [ "$MODE" = "pre" ] && color="$CYAN" || color="$YELLOW"
    echo -e "${BOLD}${color}"
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    printf  "  ║       CONFIG SNAPSHOT TOOL  —  %-34s║\n" "${mode_upper}-REBOOT"
    echo "  ║                Linux Infrastructure Team                       ║"
    echo -e "  ╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${WHITE}${BOLD}Server     :${RESET}  ${GREEN}$(hostname -f 2>/dev/null || hostname)${RESET}"
    echo -e "  ${WHITE}${BOLD}OS         :${RESET}  ${GREEN}${OS_PRETTY}${RESET}"
    echo -e "  ${WHITE}${BOLD}Init       :${RESET}  ${GREEN}${INIT_SYSTEM}${RESET}"
    echo -e "  ${WHITE}${BOLD}Kernel     :${RESET}  ${GREEN}$(uname -r)${RESET}"
    echo -e "  ${WHITE}${BOLD}Mode       :${RESET}  ${color}${BOLD}${mode_upper}${RESET}"
    echo -e "  ${WHITE}${BOLD}Snapshot   :${RESET}  ${DIM}${SNAPSHOT_DIR}${RESET}"
    echo -e "  ${WHITE}${BOLD}Started    :${RESET}  $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

print_section() {
    echo ""
    echo -e "  ${BOLD}${YELLOW}▶  $1${RESET}"
    echo -e "  ${DIM}  ──────────────────────────────────────────${RESET}"
}

print_status() {
    local label="$1" status="$2" detail="$3"
    local padded
    padded=$(printf "%-38s" "$label")
    case "$status" in
        OK)   echo -e "  ${GREEN}[✔]${RESET} ${WHITE}${padded}${RESET} ${GREEN}CAPTURED${RESET}  ${DIM}${detail}${RESET}" ;;
        SKIP) echo -e "  ${YELLOW}[~]${RESET} ${WHITE}${padded}${RESET} ${YELLOW}SKIPPED${RESET}   ${DIM}${detail}${RESET}" ;;
        *)    echo -e "  ${RED}[✘]${RESET} ${WHITE}${padded}${RESET} ${RED}FAILED${RESET}    ${DIM}${detail}${RESET}" ;;
    esac
}

# =============================================================================
#  CAPTURE FUNCTIONS
# =============================================================================

# 01 — OS & System Info
capture_os_info() {
    local f="${SNAPSHOT_DIR}/01_os_info.txt"
    {
        echo "=== OS INFORMATION ==="
        echo "Hostname         : $(hostname -f 2>/dev/null || hostname)"
        echo "Short Hostname   : $(hostname -s 2>/dev/null || hostname)"
        echo "OS               : ${OS_PRETTY}"
        echo "OS Family        : ${OS_FAMILY}"
        echo "OS Version       : ${OS_VERSION}"
        echo "OS Major         : ${OS_MAJOR}"
        echo "Init System      : ${INIT_SYSTEM}"
        echo "Snapshot Mode    : ${MODE}"
        echo "Captured At      : $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "=== TIMEZONE ==="
        compat_timezone
        echo ""
        echo "=== LOCALE ==="
        locale 2>/dev/null || echo "locale command not found"
        echo ""
        echo "=== UPTIME & LOAD ==="
        uptime
        echo ""
        echo "=== WHO IS LOGGED IN ==="
        who 2>/dev/null || w 2>/dev/null || echo "Not available"
        echo ""
        echo "=== VIRTUAL / PHYSICAL DETECTION ==="
        if command -v systemd-detect-virt >/dev/null 2>&1; then
            echo "Virt: $(systemd-detect-virt 2>/dev/null)"
        fi
        if command -v virt-what >/dev/null 2>&1; then
            echo "virt-what: $(virt-what 2>/dev/null)"
        fi
        if [ -f /sys/class/dmi/id/product_name ]; then
            echo "Product: $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
        fi
        if [ -f /sys/class/dmi/id/sys_vendor ]; then
            echo "Vendor : $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
        fi
    } > "$f" 2>&1
    print_status "OS & System Information" "OK" "${OS_PRETTY} | init: ${INIT_SYSTEM}"
}

# 02 — Kernel
capture_kernel() {
    local f="${SNAPSHOT_DIR}/02_kernel.txt"
    {
        echo "=== RUNNING KERNEL ==="
        uname -r
        echo ""
        echo "=== FULL UNAME ==="
        uname -a
        echo ""
        echo "=== KERNEL BOOT PARAMETERS ==="
        cat /proc/cmdline 2>/dev/null || echo "Not available"
        echo ""
        echo "=== INSTALLED KERNELS ==="
        case "$OS_FAMILY" in
            rhel) rpm -qa 2>/dev/null | grep -E "^kernel-[0-9]" | sort ;;
            suse) rpm -qa 2>/dev/null | grep -E "^kernel-" | sort ;;
            debian) dpkg -l 2>/dev/null | grep -E "linux-image" | awk '{print $2,$3}' ;;
        esac
        echo ""
        echo "=== BOOTLOADER CONFIG ==="
        if [ -f /etc/default/grub ]; then
            echo "--- /etc/default/grub ---"
            cat /etc/default/grub
        fi
        # grub2
        for gcfg in /boot/grub2/grub.cfg /boot/grub/grub.cfg /boot/grub2/grub.conf; do
            [ -f "$gcfg" ] && { echo "--- $gcfg (first 60 lines) ---"; head -60 "$gcfg"; }
        done
        # legacy grub (RHEL5/SLES9)
        [ -f /boot/grub/menu.lst ] && { echo "--- /boot/grub/menu.lst ---"; cat /boot/grub/menu.lst; }
        [ -f /boot/grub/grub.conf ] && { echo "--- /boot/grub/grub.conf ---"; cat /boot/grub/grub.conf; }
        echo ""
        echo "=== LOADED KERNEL MODULES ==="
        lsmod | head -80
        echo ""
        echo "=== KERNEL PARAMETERS (sysctl -a) ==="
        # sysctl -a reads from /proc/sys — all in-memory, no disk or network I/O, fast on all OS versions
        sysctl -a 2>/dev/null | sort
    } > "$f" 2>&1
    print_status "Kernel & Boot Config" "OK" "Running: $(uname -r)"
}

# 03 — CPU
capture_cpu() {
    local f="${SNAPSHOT_DIR}/03_cpu.txt"
    {
        echo "=== CPU SUMMARY ==="
        if command -v lscpu >/dev/null 2>&1; then
            lscpu
        else
            grep -E "^processor|^model name|^cpu MHz|^cache size|^physical id" /proc/cpuinfo | sort -u
        fi
        echo ""
        echo "=== CPU COUNT ==="
        echo "Total vCPUs      : $(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo)"
        echo ""
        echo "=== CPU FLAGS (first processor) ==="
        grep "^flags" /proc/cpuinfo | head -1
        echo ""
        echo "=== CURRENT CPU USAGE ==="
        top -bn1 2>/dev/null | head -8 || echo "top not available"
        echo ""
        echo "=== LOAD AVERAGE ==="
        cat /proc/loadavg
        echo ""
        echo "=== CPU FREQ SCALING ==="
        ls /sys/devices/system/cpu/cpu0/cpufreq/ 2>/dev/null \
            && cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null \
            || echo "cpufreq not available"
    } > "$f" 2>&1
    local cpus
    cpus=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo)
    print_status "CPU Information" "OK" "${cpus} vCPU(s)"
}

# 04 — Memory
capture_memory() {
    local f="${SNAPSHOT_DIR}/04_memory.txt"
    {
        echo "=== MEMORY OVERVIEW ==="
        free -h 2>/dev/null || free
        echo ""
        echo "=== MEMORY BYTES ==="
        free -b 2>/dev/null || true
        echo ""
        echo "=== /proc/meminfo ==="
        cat /proc/meminfo
        echo ""
        echo "=== SWAP ==="
        if command -v swapon >/dev/null 2>&1; then
            swapon --show 2>/dev/null || swapon -s 2>/dev/null || echo "No swap"
        fi
        cat /proc/swaps 2>/dev/null || true
        echo ""
        echo "=== TOP MEMORY CONSUMERS ==="
        ps aux 2>/dev/null | sort -rk4 | head -15 || ps -eo pid,pmem,rss,comm | sort -rk2 | head -15
        echo ""
        echo "=== HUGE PAGES ==="
        grep -i huge /proc/meminfo 2>/dev/null || echo "Huge pages info not available"
    } > "$f" 2>&1
    local mt mu
    mt=$(free -h 2>/dev/null | grep Mem | awk '{print $2}')
    mu=$(free -h 2>/dev/null | grep Mem | awk '{print $3}')
    print_status "Memory & Swap" "OK" "Total: ${mt} | Used: ${mu}"
}

# 05 — Hardware (NEW — was missing entirely)
capture_hardware() {
    local f="${SNAPSHOT_DIR}/05_hardware.txt"
    {
        echo "=== BIOS / SYSTEM INFO (dmidecode) ==="
        if command -v dmidecode >/dev/null 2>&1; then
            dmidecode -t bios     2>/dev/null
            echo ""
            dmidecode -t system   2>/dev/null
            echo ""
            echo "=== MEMORY DIMMs ==="
            dmidecode -t memory   2>/dev/null | grep -E "Size|Speed|Locator|Type:|Manufacturer|Serial" | grep -v "No Module"
            echo ""
            echo "=== PROCESSOR (dmidecode) ==="
            dmidecode -t processor 2>/dev/null | grep -E "Socket|Version|Max Speed|Core|Thread"
        else
            echo "dmidecode not available"
        fi
        echo ""
        echo "=== PCI DEVICES (lspci) ==="
        if command -v lspci >/dev/null 2>&1; then
            lspci 2>/dev/null
        else
            echo "lspci not available"
        fi
        echo ""
        echo "=== SCSI / BLOCK DEVICES (lsscsi) ==="
        if command -v lsscsi >/dev/null 2>&1; then
            lsscsi 2>/dev/null
        else
            echo "lsscsi not available — using /proc/scsi/scsi"
            cat /proc/scsi/scsi 2>/dev/null || echo "Not available"
        fi
        echo ""
        echo "=== USB DEVICES (lsusb) ==="
        if command -v lsusb >/dev/null 2>&1; then
            lsusb 2>/dev/null
        else
            cat /proc/bus/usb/devices 2>/dev/null | head -40 || echo "lsusb not available"
        fi
        echo ""
        echo "=== SOFTWARE RAID (mdstat) ==="
        cat /proc/mdstat 2>/dev/null || echo "No software RAID"
        echo ""
        echo "=== HARDWARE RAID (storcli/megacli) ==="
        if command -v storcli >/dev/null 2>&1; then
            storcli show all 2>/dev/null
        elif command -v storcli64 >/dev/null 2>&1; then
            storcli64 show all 2>/dev/null
        elif command -v MegaCli >/dev/null 2>&1; then
            MegaCli -LDInfo -Lall -aALL 2>/dev/null
        elif command -v MegaCli64 >/dev/null 2>&1; then
            MegaCli64 -LDInfo -Lall -aALL 2>/dev/null
        else
            echo "No storcli/MegaCli found"
        fi
    } > "$f" 2>&1
    print_status "Hardware (BIOS/PCI/RAID)" "OK" "dmidecode + lspci + RAID captured"
}

# 06 — Disk & Storage
capture_disk() {
    local f="${SNAPSHOT_DIR}/06_disk.txt"
    {
        echo "=== DISK USAGE (df) ==="
        df -hT 2>/dev/null || df -h
        echo ""
        echo "=== DISK INODES ==="
        df -i 2>/dev/null || true
        echo ""
        echo "=== BLOCK DEVICES ==="
        compat_lsblk
        echo ""
        echo "=== DISK COUNT ==="
        echo "Physical disks detected:"
        if command -v lsblk >/dev/null 2>&1; then
            lsblk -d -o NAME,SIZE,TYPE 2>/dev/null | grep disk
        else
            fdisk -l 2>/dev/null | grep "^Disk /dev" | grep -v "doesn't contain"
        fi
        echo ""
        echo "=== FDISK ==="
        fdisk -l 2>/dev/null | grep -E "^Disk /dev|sectors|^/dev"
        echo ""
        echo "=== FSTAB ==="
        cat /etc/fstab
        echo ""
        echo "=== CRYPTTAB ==="
        cat /etc/crypttab 2>/dev/null || echo "No crypttab"
        echo ""
        echo "=== CURRENT MOUNTS ==="
        compat_mounts
        echo ""
        echo "=== LVM — Physical Volumes ==="
        pvs 2>/dev/null || pvdisplay 2>/dev/null || echo "LVM not in use"
        echo ""
        echo "=== LVM — Volume Groups ==="
        vgs 2>/dev/null || vgdisplay 2>/dev/null || echo "LVM not in use"
        echo ""
        echo "=== LVM — Logical Volumes ==="
        lvs 2>/dev/null || lvdisplay 2>/dev/null || echo "LVM not in use"
        echo ""
        echo "=== MULTIPATH STATUS ==="
        if command -v multipath >/dev/null 2>&1; then
            multipath -ll 2>/dev/null || echo "multipath not active"
        else
            echo "multipath not installed"
        fi
        echo ""
        echo "=== NFS / CIFS MOUNTS ==="
        mount 2>/dev/null | grep -E "nfs|cifs|smb" || echo "None"
        echo ""
        echo "=== DISK I/O STATS ==="
        if command -v iostat >/dev/null 2>&1; then
            iostat -x 1 1 2>/dev/null
        else
            cat /proc/diskstats 2>/dev/null | head -20
        fi
    } > "$f" 2>&1
    local disks
    disks=$(lsblk -d -o TYPE 2>/dev/null | grep -c disk || fdisk -l 2>/dev/null | grep -c "^Disk /dev" || echo "?")
    print_status "Disk & Storage" "OK" "${disks} disk(s) | LVM + multipath captured"
}

# 07 — Network
capture_network() {
    local f="${SNAPSHOT_DIR}/07_network.txt"
    {
        echo "=== HOSTNAME & FQDN ==="
        echo "Hostname : $(hostname)"
        echo "FQDN     : $(hostname -f 2>/dev/null || hostname)"
        echo ""
        echo "=== NETWORK INTERFACES ==="
        compat_ip_addr
        echo ""
        echo "=== ROUTING TABLE ==="
        compat_ip_route
        echo ""
        echo "=== ARP / NEIGHBOUR TABLE ==="
        compat_ip_neigh
        echo ""
        echo "=== INTERFACE STATISTICS ==="
        compat_ip_link_stats
        echo ""
        echo "=== DNS CONFIGURATION ==="
        cat /etc/resolv.conf
        echo ""
        echo "=== /etc/hosts ==="
        cat /etc/hosts
        echo ""
        echo "=== NETWORK INTERFACE CONFIG FILES ==="
        # RHEL/CentOS/SLES network-scripts
        if [ -d /etc/sysconfig/network-scripts ]; then
            echo "--- /etc/sysconfig/network-scripts/ ---"
            for f2 in /etc/sysconfig/network-scripts/ifcfg-*; do
                [ -f "$f2" ] && { echo "=== $f2 ==="; cat "$f2"; echo ""; }
            done
        fi
        # SLES
        if [ -d /etc/sysconfig/network ]; then
            echo "--- /etc/sysconfig/network/ ---"
            for f2 in /etc/sysconfig/network/ifcfg-*; do
                [ -f "$f2" ] && { echo "=== $f2 ==="; cat "$f2"; echo ""; }
            done
        fi
        # Ubuntu 18+ netplan
        if [ -d /etc/netplan ]; then
            echo "--- /etc/netplan/ ---"
            for f2 in /etc/netplan/*.yaml /etc/netplan/*.yml; do
                [ -f "$f2" ] && { echo "=== $f2 ==="; cat "$f2"; echo ""; }
            done
        fi
        # Debian interfaces
        [ -f /etc/network/interfaces ] && { echo "--- /etc/network/interfaces ---"; cat /etc/network/interfaces; }
        echo ""
        echo "=== BONDING / TEAMING ==="
        if [ -d /proc/net/bonding ]; then
            for b in /proc/net/bonding/*; do
                echo "--- $b ---"; cat "$b" 2>/dev/null
            done
        else
            echo "No bonding configured"
        fi
        if command -v teamdctl >/dev/null 2>&1; then
            echo "--- Team interfaces ---"
            for t in $(teamdctl --list 2>/dev/null); do
                teamdctl "$t" state 2>/dev/null
            done
        fi
        echo ""
        echo "=== BRIDGE CONFIG ==="
        if command -v brctl >/dev/null 2>&1; then
            brctl show 2>/dev/null
        else
            ip link show type bridge 2>/dev/null || echo "No bridges"
        fi
        echo ""
        echo "=== VLAN CONFIG ==="
        cat /proc/net/vlan/config 2>/dev/null || ip -d link show 2>/dev/null | grep -A2 "vlan" || echo "No VLANs"
    } > "$f" 2>&1
    local ips
    if command -v ip >/dev/null 2>&1; then
        ips=$(ip -4 addr show 2>/dev/null | grep inet | grep -v 127 | awk '{print $2}' | tr '\n' ' ')
    else
        ips=$(ifconfig 2>/dev/null | grep "inet " | grep -v 127 | awk '{print $2}' | tr '\n' ' ')
    fi
    print_status "Network Configuration" "OK" "${ips:-unknown}"
}

# 08 — NTP / Time Sync (NEW)
capture_ntp() {
    local f="${SNAPSHOT_DIR}/08_ntp.txt"
    {
        echo "=== NTP / TIME SYNC STATUS ==="
        compat_ntp_status
        echo ""
        echo "=== NTP CONFIG FILES ==="
        for ntpcfg in /etc/ntp.conf /etc/ntpd.conf /etc/chrony.conf /etc/chrony/chrony.conf; do
            [ -f "$ntpcfg" ] && { echo "--- $ntpcfg ---"; cat "$ntpcfg"; echo ""; }
        done
        echo ""
        echo "=== CURRENT TIME ==="
        date '+%Y-%m-%d %H:%M:%S %Z'
        echo "UTC: $(date -u '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "=== HWCLOCK ==="
        hwclock --show 2>/dev/null || echo "hwclock not available"
    } > "$f" 2>&1
    print_status "NTP / Time Sync" "OK" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# 09 — Ports & Connections
capture_ports() {
    local f="${SNAPSHOT_DIR}/09_ports.txt"
    {
        echo "=== LISTENING PORTS ==="
        compat_listen_ports
        echo ""
        echo "=== ESTABLISHED CONNECTIONS ==="
        compat_connections
        echo ""
        echo "=== SOCKET SUMMARY ==="
        compat_socket_summary
    } > "$f" 2>&1
    local portcount
    portcount=$(count_listen_ports)
    print_status "Open Ports & Connections" "OK" "${portcount} listening port(s)"
}

# 10 — Firewall
capture_firewall() {
    local f="${SNAPSHOT_DIR}/10_firewall.txt"
    {
        echo "=== FIREWALL STATUS ==="
        if command -v firewall-cmd >/dev/null 2>&1; then
            echo "--- FirewallD ---"
            firewall-cmd --state 2>/dev/null || true
            firewall-cmd --list-all 2>/dev/null || true
            firewall-cmd --list-all-zones 2>/dev/null || true
            echo ""
        fi
        if command -v ufw >/dev/null 2>&1; then
            echo "--- UFW ---"
            ufw status verbose 2>/dev/null
            echo ""
        fi
        echo "=== IPTABLES (IPv4) ==="
        iptables -L -n -v 2>/dev/null || echo "iptables not available"
        echo ""
        echo "=== IPTABLES NAT ==="
        iptables -t nat -L -n -v 2>/dev/null || true
        echo ""
        echo "=== IP6TABLES ==="
        ip6tables -L -n -v 2>/dev/null || echo "ip6tables not available"
        echo ""
        echo "=== IPTABLES-SAVE ==="
        iptables-save 2>/dev/null || echo "iptables-save not available"
    } > "$f" 2>&1
    print_status "Firewall Rules" "OK" "firewalld/iptables/ufw captured"
}

# 11 — Packages
capture_packages() {
    local f="${SNAPSHOT_DIR}/11_packages.txt"
    {
        echo "=== INSTALLED PACKAGES ==="
        case "$OS_FAMILY" in
            rhel|suse)
                rpm -qa --queryformat '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}\n' 2>/dev/null | sort ;;
            debian)
                dpkg-query -W -f='${Package}|${Version}|${Architecture}\n' 2>/dev/null | sort ;;
        esac
        echo ""
        echo "=== PACKAGE COUNT ==="
        case "$OS_FAMILY" in
            rhel|suse) echo "Total: $(rpm -qa 2>/dev/null | wc -l) RPM packages" ;;
            debian)    echo "Total: $(dpkg -l 2>/dev/null | grep '^ii' | wc -l) packages" ;;
        esac
        echo ""
        echo "=== PATCH / UPDATE HISTORY ==="
        case "$OS_FAMILY" in
            rhel)
                if command -v dnf >/dev/null 2>&1; then
                    dnf history list 2>/dev/null | head -40
                elif command -v yum >/dev/null 2>&1; then
                    yum history list 2>/dev/null | head -40 \
                        || rpm -qa --queryformat '%{INSTALLTIME:date} %{NAME}-%{VERSION}\n' 2>/dev/null | sort -r | head -40
                fi
                ;;
            suse)
                # zypper patches removed — contacts repos and hangs on SLES10/11.
                # Capture installed kernel packages from RPM DB (instant, offline).
                echo "--- Installed kernel packages ---"
                rpm -qa 2>/dev/null | grep -iE "^kernel" | sort
                echo ""
                # zypp history log — plain file read, no network, always fast
                echo "--- /var/log/zypp/history (last 60 entries) ---"
                cat /var/log/zypp/history 2>/dev/null | tail -60 \
                    || echo "zypp history not available"
                ;;
            debian)
                grep -E "install|upgrade|remove" /var/log/apt/history.log 2>/dev/null | tail -60 \
                    || cat /var/log/dpkg.log 2>/dev/null | grep "installed\|upgraded" | tail -60
                ;;
        esac
        echo ""
        echo "=== REPOSITORIES (config files — no network calls) ==="
        # Read .repo / sources files directly — no repolist/zypper commands
        # which contact the network and can hang on unreachable repos.
        case "$OS_FAMILY" in
            rhel)
                ls /etc/yum.repos.d/*.repo 2>/dev/null | while read r; do echo "--- $r ---"; cat "$r"; echo ""; done \
                    || echo "No .repo files found in /etc/yum.repos.d/"
                ;;
            suse)
                ls /etc/zypp/repos.d/*.repo 2>/dev/null | while read r; do echo "--- $r ---"; cat "$r"; echo ""; done \
                    || echo "No .repo files found in /etc/zypp/repos.d/"
                ;;
            debian)
                cat /etc/apt/sources.list 2>/dev/null
                ls /etc/apt/sources.list.d/*.list 2>/dev/null | while read r; do echo "--- $r ---"; cat "$r"; echo ""; done
                ;;
        esac
    } > "$f" 2>&1
    local pkgcount
    case "$OS_FAMILY" in
        rhel|suse) pkgcount=$(rpm -qa 2>/dev/null | wc -l) ;;
        debian)    pkgcount=$(dpkg -l 2>/dev/null | grep '^ii' | wc -l) ;;
        *)         pkgcount="?" ;;
    esac
    print_status "Packages & Repos" "OK" "${pkgcount} packages | kernels + repos captured"
}

# 12 — Services (systemd + SysV + upstart)
capture_services() {
    local f="${SNAPSHOT_DIR}/12_services.txt"
    {
        echo "=== INIT SYSTEM: ${INIT_SYSTEM} ==="
        echo ""
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            echo "=== ENABLED SERVICES ==="
            systemctl list-unit-files --type=service --state=enabled 2>/dev/null
            echo ""
            echo "=== RUNNING SERVICES ==="
            systemctl list-units --type=service --state=running 2>/dev/null
            echo ""
            echo "=== FAILED SERVICES ==="
            systemctl list-units --state=failed 2>/dev/null
            echo ""
            echo "=== ALL UNIT FILES ==="
            systemctl list-unit-files 2>/dev/null
            echo ""
            echo "=== SYSTEMD TIMERS ==="
            systemctl list-timers --all 2>/dev/null
        fi
        # SysV (RHEL5/6, SLES9/10/11)
        if command -v chkconfig >/dev/null 2>&1; then
            echo "=== CHKCONFIG --LIST ==="
            chkconfig --list 2>/dev/null
            echo ""
        fi
        if command -v service >/dev/null 2>&1 && [ "$INIT_SYSTEM" != "systemd" ]; then
            echo "=== SERVICE --STATUS-ALL ==="
            service --status-all 2>/dev/null || true
            echo ""
        fi
        echo "=== CURRENT RUNLEVEL ==="
        compat_runlevel
        echo ""
        echo "=== /etc/init.d SCRIPTS ==="
        ls -la /etc/init.d/ 2>/dev/null || ls -la /etc/rc.d/init.d/ 2>/dev/null || echo "None"
    } > "$f" 2>&1
    local running=0
    [ "$INIT_SYSTEM" = "systemd" ] && running=$(systemctl list-units --type=service --state=running 2>/dev/null | grep -c "running" || echo 0)
    print_status "Services (${INIT_SYSTEM})" "OK" "${running} running"
}

# 13 — Security Policy (SELinux / AppArmor)
capture_security_policy() {
    local f="${SNAPSHOT_DIR}/13_security_policy.txt"
    {
        echo "=== SELinux STATUS ==="
        if command -v getenforce >/dev/null 2>&1; then
            getenforce
            sestatus 2>/dev/null || true
            echo ""
            echo "SELinux Config:"
            cat /etc/selinux/config 2>/dev/null || echo "Not found"
        else
            echo "SELinux not installed"
        fi
        echo ""
        echo "=== AppArmor STATUS ==="
        if command -v apparmor_status >/dev/null 2>&1; then
            apparmor_status 2>/dev/null
        elif command -v aa-status >/dev/null 2>&1; then
            aa-status 2>/dev/null
        else
            echo "AppArmor not installed"
        fi
        echo ""
        echo "=== PAM CONFIGURATION ==="
        echo "--- /etc/pam.d directory listing ---"
        ls -la /etc/pam.d/ 2>/dev/null
        echo ""
        echo "--- Key PAM files ---"
        for pf in /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/su /etc/pam.d/sudo /etc/pam.d/system-auth /etc/pam.d/common-auth; do
            [ -f "$pf" ] && { echo "=== $pf ==="; cat "$pf"; echo ""; }
        done
        echo ""
        echo "=== SSH DAEMON CONFIG ==="
        cat /etc/ssh/sshd_config 2>/dev/null | grep -v "^#" | grep -v "^$" \
            || echo "sshd_config not found"
        echo ""
        echo "=== LIMITS (ulimit / limits.conf) ==="
        cat /etc/security/limits.conf 2>/dev/null | grep -v "^#" | grep -v "^$"
        ls /etc/security/limits.d/*.conf 2>/dev/null | while read lf; do
            echo "--- $lf ---"; cat "$lf" 2>/dev/null
        done
    } > "$f" 2>&1
    local sel="N/A"
    command -v getenforce >/dev/null 2>&1 && sel=$(getenforce 2>/dev/null || echo "N/A")
    print_status "SELinux / AppArmor / PAM" "OK" "SELinux: ${sel}"
}

# 14 — Cron & Timers
capture_cron() {
    local f="${SNAPSHOT_DIR}/14_cron.txt"
    {
        echo "=== SYSTEM CRONTAB (/etc/crontab) ==="
        cat /etc/crontab 2>/dev/null || echo "Not found"
        echo ""
        echo "=== /etc/cron.d/ ==="
        ls -la /etc/cron.d/ 2>/dev/null
        for cf in /etc/cron.d/*; do
            [ -f "$cf" ] && { echo "--- $cf ---"; cat "$cf"; echo ""; }
        done
        echo ""
        echo "=== CRON DIRECTORIES (listings) ==="
        for d in hourly daily weekly monthly; do
            echo "-- cron.${d} --"
            ls -la /etc/cron.${d}/ 2>/dev/null || echo "Not found"
        done
        echo ""
        echo "=== ROOT CRONTAB ==="
        crontab -l 2>/dev/null || echo "No root crontab"
        echo ""
        echo "=== ALL USER CRONTABS ==="
        for user in $(cut -d: -f1 /etc/passwd 2>/dev/null); do
            local uctab
            uctab=$(crontab -l -u "$user" 2>/dev/null)
            [ -n "$uctab" ] && { echo "[user: $user]"; echo "$uctab"; echo ""; }
        done
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            echo "=== SYSTEMD TIMERS ==="
            systemctl list-timers --all 2>/dev/null
        fi
        echo ""
        echo "=== AT JOBS ==="
        atq 2>/dev/null || echo "at not available"
    } > "$f" 2>&1
    print_status "Cron Jobs & Timers" "OK" "system + user crontabs + timers captured"
}

# 15 — Users & Access (no /etc/shadow)
capture_users() {
    local f="${SNAPSHOT_DIR}/15_users.txt"
    {
        echo "=== ALL USER ACCOUNTS (/etc/passwd) ==="
        cat /etc/passwd
        echo ""
        echo "=== ALL GROUPS (/etc/group) ==="
        cat /etc/group
        echo ""
        echo "=== USERS WITH LOGIN SHELL ==="
        grep -vE '/nologin|/false|/sync|/halt|/shutdown' /etc/passwd | grep -v '^#'
        echo ""
        echo "=== USERS WITH UID 0 (root-equivalent) ==="
        awk -F: '$3==0 {print $1}' /etc/passwd
        echo ""
        echo "=== SUDO CONFIGURATION ==="
        cat /etc/sudoers 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "Not accessible"
        echo ""
        echo "=== SUDOERS.D ==="
        ls -la /etc/sudoers.d/ 2>/dev/null
        for sf in /etc/sudoers.d/*; do
            [ -f "$sf" ] && { echo "--- $sf ---"; cat "$sf" 2>/dev/null; echo ""; }
        done
        echo ""
        echo "=== LAST LOGINS ==="
        last 2>/dev/null | head -30
        echo ""
        echo "=== LASTB (failed logins) ==="
        lastb 2>/dev/null | head -20 || echo "lastb not available or empty"
        echo ""
        echo "=== CURRENTLY LOGGED IN ==="
        who 2>/dev/null; w 2>/dev/null || true
        echo ""
        echo "=== SSH AUTHORIZED KEYS (root) ==="
        if [ -f /root/.ssh/authorized_keys ]; then
            echo "Keys present: $(wc -l < /root/.ssh/authorized_keys)"
            cat /root/.ssh/authorized_keys | grep -v "PRIVATE KEY" | head -20
        else
            echo "None or not accessible"
        fi
        echo ""
        echo "=== PASSWORD POLICY ==="
        cat /etc/login.defs 2>/dev/null | grep -v "^#" | grep -v "^$"
    } > "$f" 2>&1
    local uc
    uc=$(grep -vE '/nologin|/false' /etc/passwd | grep -v '^#' | wc -l)
    print_status "User Accounts & Access" "OK" "${uc} login-capable accounts"
}

# 16 — /etc Checksums (excluding sensitive files)
capture_etc_checksums() {
    local f="${SNAPSHOT_DIR}/16_etc_checksums.txt"
    {
        echo "=== /etc CONFIGURATION FILE CHECKSUMS (MD5) ==="
        echo "Generated: $(date)"
        echo "Note: /etc/shadow, /etc/gshadow, ssl/private excluded for security"
        echo ""
        find /etc -type f -readable 2>/dev/null \
            ! -path "/etc/shadow" \
            ! -path "/etc/gshadow" \
            ! -path "*/ssl/private/*" \
            ! -path "*/ssl/private" \
            ! -name "*.key" \
            | sort \
            | while read fpath; do
                md5sum "$fpath" 2>/dev/null
            done
    } > "$f" 2>&1
    local count
    count=$(grep -c "^[a-f0-9]" "$f" 2>/dev/null || echo 0)
    print_status "/etc Config Checksums" "OK" "${count} files checksummed"
}

# 17 — Processes
capture_processes() {
    local f="${SNAPSHOT_DIR}/17_processes.txt"
    {
        echo "=== FULL PROCESS LIST ==="
        ps auxf 2>/dev/null || ps -ef 2>/dev/null || ps aux 2>/dev/null
        echo ""
        echo "=== PROCESS COUNT ==="
        ps aux 2>/dev/null | wc -l || ps -ef 2>/dev/null | wc -l
        echo ""
        echo "=== TOP CPU CONSUMERS ==="
        ps aux 2>/dev/null | sort -rk3 | head -15
        echo ""
        echo "=== TOP MEMORY CONSUMERS ==="
        ps aux 2>/dev/null | sort -rk4 | head -15
        echo ""
        echo "=== ZOMBIE PROCESSES ==="
        ps aux 2>/dev/null | awk '$8=="Z"' || echo "None"
    } > "$f" 2>&1
    local pcount
    pcount=$(ps aux 2>/dev/null | tail -n +2 | wc -l || echo "?")
    print_status "Process Snapshot" "OK" "${pcount} processes"
}

# 18 — Log Baseline
capture_logs() {
    local f="${SNAPSHOT_DIR}/18_logs.txt"
    {
        echo "=== SYSTEM LOG (last 80 lines) ==="
        tail -80 /var/log/messages 2>/dev/null \
            || tail -80 /var/log/syslog 2>/dev/null \
            || echo "Not available"
        echo ""
        echo "=== KERNEL RING BUFFER (dmesg, last 80) ==="
        dmesg 2>/dev/null | tail -80
        echo ""
        echo "=== JOURNAL (last 80, if systemd) ==="
        compat_recent_logs
        echo ""
        echo "=== AUTH LOG (last 40) ==="
        tail -40 /var/log/secure 2>/dev/null \
            || tail -40 /var/log/auth.log 2>/dev/null \
            || echo "Not available"
        echo ""
        echo "=== BOOT LOG ==="
        tail -30 /var/log/boot.log 2>/dev/null \
            || tail -30 /var/log/boot 2>/dev/null \
            || echo "boot log not available"
        echo ""
        echo "=== DMESG ERRORS ==="
        dmesg 2>/dev/null | grep -iE "error|fail|warn|panic|oops|bug:" | tail -40 || true
    } > "$f" 2>&1
    print_status "System Log Baseline" "OK" "syslog/dmesg/journal/auth captured"
}

# 19 — Boot History
capture_reboot_history() {
    local f="${SNAPSHOT_DIR}/19_boot_history.txt"
    {
        echo "=== BOOT / STARTUP HISTORY ==="
        # Using 'last | grep boot' intentionally — avoids passing 'reboot' or
        # 'shutdown' as arguments to last, which could be misread by associates
        # as a command to actually reboot or shutdown the server.
        last 2>/dev/null | grep "boot" | head -20 \
            || echo "boot history not available"
        echo ""
        echo "=== SYSTEM START EVENTS (wtmp) ==="
        # Extract all system start/stop events without using shutdown/reboot keywords
        last -F 2>/dev/null | grep "boot" | head -20 \
            || last 2>/dev/null | grep "boot" | head -20 \
            || echo "Not available"
        echo ""
        echo "=== CURRENT UPTIME ==="
        uptime
        echo ""
        echo "=== BOOT TIME ==="
        who -b 2>/dev/null \
            || systemctl show --property=UserspaceTimestamp 2>/dev/null \
            || cat /proc/uptime 2>/dev/null
        echo ""
        echo "=== TIME SINCE LAST BOOT (/proc/uptime) ==="
        cat /proc/uptime 2>/dev/null
        echo ""
        echo "=== DMESG BOOT TIMESTAMP ==="
        dmesg 2>/dev/null | head -3
    } > "$f" 2>&1
    local upt
    upt=$(compat_uptime_pretty)
    print_status "Boot & Uptime History" "OK" "${upt}"
}

# =============================================================================
#  HTML REPORT GENERATOR
# =============================================================================
generate_html_report() {
    echo ""
    echo -e "  ${BOLD}${YELLOW}▶  Generating HTML Report...${RESET}"
    echo -e "  ${DIM}  ──────────────────────────────────────────${RESET}"

    # Gather summary stats
    local diskcount pkgcount running_svc failed_svc mem_total mem_used mem_pct
    local cpu_count cpu_model disk_root selinux_s load_avg open_ports kernel_ver uptime_val

    diskcount=$(lsblk -d -o TYPE 2>/dev/null | grep -c disk || echo "?")
    case "$OS_FAMILY" in
        rhel|suse) pkgcount=$(rpm -qa 2>/dev/null | wc -l) ;;
        debian)    pkgcount=$(dpkg -l 2>/dev/null | grep '^ii' | wc -l) ;;
        *) pkgcount="?" ;;
    esac
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        running_svc=$(systemctl list-units --type=service --state=running 2>/dev/null | grep -c "running" || echo 0)
        failed_svc=$(systemctl list-units --state=failed 2>/dev/null | grep -c "failed" || echo 0)
    else
        running_svc="N/A"; failed_svc="N/A"
    fi
    mem_total=$(free -h 2>/dev/null | grep Mem | awk '{print $2}')
    mem_used=$(free -h 2>/dev/null | grep Mem | awk '{print $3}')
    mem_pct=$(free 2>/dev/null | grep Mem | awk '{printf "%.0f", $3/$2*100}' || echo 0)
    cpu_count=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo || echo "?")
    cpu_model=$(lscpu 2>/dev/null | grep "Model name" | head -1 | sed 's/Model name.*: *//' | xargs || \
                grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    disk_root=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    selinux_s="N/A"
    command -v getenforce >/dev/null 2>&1 && selinux_s=$(getenforce 2>/dev/null || echo "N/A")
    load_avg=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    open_ports=$(count_listen_ports)
    kernel_ver=$(uname -r)
    uptime_val=$(compat_uptime_pretty)

    # Mode-based accent colour
    local accent_main accent_glow badge_label
    if [ "$MODE" = "pre" ]; then
        accent_main="#00c9ff"
        accent_glow="rgba(0,201,255,0.15)"
        badge_label="PRE-REBOOT"
    else
        accent_main="#ffd166"
        accent_glow="rgba(255,209,102,0.15)"
        badge_label="POST-REBOOT"
    fi

    # HTML escape helper via sed
    html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g' "$1" 2>/dev/null; }

    cat > "$HTML_REPORT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${MODE_UPPER} Snapshot — $(hostname -s) — $(date '+%Y-%m-%d')</title>
<style>
:root {
  --bg:       #070d18;
  --bg2:      #0d1526;
  --bg3:      #111e36;
  --border:   #1a2d4f;
  --accent:   ${accent_main};
  --glow:     ${accent_glow};
  --ok:       #2ecc71;
  --warn:     #f39c12;
  --danger:   #e74c3c;
  --text:     #b8cde0;
  --muted:    #4a6a8a;
  --hi:       #f0f6ff;
  --mono:     'Consolas','Courier New',monospace;
  --sans:     'Trebuchet MS','Segoe UI',Tahoma,sans-serif;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:var(--sans);min-height:100vh;font-size:14px}
::selection{background:var(--accent);color:#000}

/* HEADER */
.hdr{background:linear-gradient(135deg,#070d18 0%,#0d1a2e 60%,#070d18 100%);
     border-bottom:1px solid var(--border);padding:32px 48px 28px;position:relative;overflow:hidden}
.hdr::after{content:'';position:absolute;top:-60px;right:-60px;width:320px;height:320px;
    border-radius:50%;background:var(--glow);filter:blur(60px);pointer-events:none}
.hdr-top{display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:20px}
.hdr-badge{display:inline-flex;align-items:center;gap:7px;
    background:var(--glow);border:1px solid var(--accent);
    color:var(--accent);font-size:11px;font-weight:700;letter-spacing:2px;
    padding:5px 14px;border-radius:4px;text-transform:uppercase;margin-bottom:12px}
.hdr-dot{width:7px;height:7px;border-radius:50%;background:var(--accent);
    box-shadow:0 0 8px var(--accent);animation:pulse 2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.hdr h1{font-size:32px;font-weight:800;color:var(--hi);letter-spacing:-0.5px;line-height:1}
.hdr h1 span{color:var(--accent)}
.hdr-sub{color:var(--muted);font-size:13px;margin-top:6px;font-family:var(--mono)}
.hdr-meta{display:flex;flex-direction:column;gap:8px;align-items:flex-end}
.meta-pill{background:var(--bg3);border:1px solid var(--border);border-radius:6px;
    padding:8px 14px;text-align:right;min-width:140px}
.meta-pill strong{display:block;color:var(--hi);font-size:13px;font-family:var(--mono)}
.meta-pill span{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px}

/* STAT BAR */
.statbar{background:var(--bg2);border-bottom:1px solid var(--border);padding:0 48px}
.stats-inner{display:flex;flex-wrap:wrap;max-width:1400px;margin:0 auto}
.stat{padding:16px 20px;border-right:1px solid var(--border);flex:1;min-width:110px}
.stat:last-child{border-right:none}
.stat-lbl{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:6px}
.stat-val{font-size:22px;font-weight:800;color:var(--accent);font-family:var(--mono)}
.stat-val.ok{color:var(--ok)}.stat-val.warn{color:var(--warn)}.stat-val.danger{color:var(--danger)}
.stat-sub{font-size:10px;color:var(--muted);margin-top:3px;font-family:var(--mono)}
.bar{height:3px;background:var(--bg3);border-radius:2px;margin-top:6px;overflow:hidden}
.bar-fill{height:100%;border-radius:2px;transition:width .6s ease}

/* LAYOUT */
.layout{display:grid;grid-template-columns:220px 1fr;gap:0;max-width:1400px;margin:0 auto;min-height:80vh}
.nav{background:var(--bg2);border-right:1px solid var(--border);padding:20px 0;position:sticky;top:0;height:100vh;overflow-y:auto}
.nav::-webkit-scrollbar{width:4px}
.nav::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}
.nav-grp{padding:12px 16px 4px;font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1.5px;font-weight:700}
.nav a{display:flex;align-items:center;gap:8px;padding:7px 16px;color:var(--muted);
    text-decoration:none;font-size:12px;border-left:2px solid transparent;
    transition:all .15s}
.nav a:hover{color:var(--text);background:var(--bg3);border-left-color:var(--border)}
.nav a.active{color:var(--accent);background:var(--glow);border-left-color:var(--accent)}
.nav-ic{width:15px;text-align:center;font-size:12px}

/* CONTENT */
.content{padding:24px 32px;min-width:0}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:10px;
    margin-bottom:18px;overflow:hidden;scroll-margin-top:20px}
.card-hdr{display:flex;align-items:center;justify-content:space-between;
    padding:13px 20px;background:var(--bg3);border-bottom:1px solid var(--border);
    cursor:pointer;user-select:none;transition:background .15s}
.card-hdr:hover{background:rgba(26,45,79,0.7)}
.card-title-row{display:flex;align-items:center;gap:10px}
.card-ic{width:30px;height:30px;border-radius:7px;display:flex;align-items:center;justify-content:center;
    font-size:14px;background:var(--glow);border:1px solid var(--accent);flex-shrink:0;opacity:.9}
.card-title{font-size:13px;font-weight:700;color:var(--hi)}
.card-sub{font-family:var(--mono);font-size:10px;color:var(--muted);margin-top:2px}
.card-toggle{font-size:16px;color:var(--muted);transition:transform .2s}
.card-toggle.open{transform:rotate(180deg)}
.card-body{display:none;padding:18px 20px}
.card-body.open{display:block}
.card-body pre{font-family:var(--mono);font-size:11.5px;line-height:1.75;color:var(--text);
    white-space:pre-wrap;word-break:break-word;background:var(--bg);
    border:1px solid var(--border);border-radius:6px;padding:14px 18px;
    max-height:520px;overflow-y:auto}
.card-body pre::-webkit-scrollbar{width:5px}
.card-body pre::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
.info-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px;margin-bottom:14px}
.info-card{background:var(--bg);border:1px solid var(--border);border-radius:7px;padding:12px 16px}
.info-row{display:flex;justify-content:space-between;align-items:baseline;
    padding:4px 0;border-bottom:1px solid rgba(26,45,79,.5);font-family:var(--mono);font-size:11.5px}
.info-row:last-child{border:none}
.info-key{color:var(--muted)}
.info-val{color:var(--hi);font-weight:600;text-align:right;max-width:58%;word-break:break-all}
.info-val.ok{color:var(--ok)}.info-val.warn{color:var(--warn)}.info-val.danger{color:var(--danger)}

/* FOOTER */
.footer{border-top:1px solid var(--border);padding:20px 48px;
    display:flex;justify-content:space-between;align-items:center;
    font-family:var(--mono);font-size:11px;color:var(--muted)}

@media(max-width:900px){
  .layout{grid-template-columns:1fr}
  .nav{position:static;height:auto}
  .hdr,.statbar{padding-left:16px;padding-right:16px}
  .content{padding:16px}
}
</style>
</head>
<body>

<!-- HEADER -->
<div class="hdr">
  <div class="hdr-top">
    <div>
      <div class="hdr-badge"><span class="hdr-dot"></span>${badge_label} SNAPSHOT</div>
      <h1>$(hostname -s 2>/dev/null || hostname)<span>.</span></h1>
      <div class="hdr-sub">$(hostname -f 2>/dev/null || hostname) &nbsp;·&nbsp; ${OS_PRETTY} &nbsp;·&nbsp; Kernel ${kernel_ver}</div>
    </div>
    <div class="hdr-meta">
      <div class="meta-pill"><strong>$(date '+%Y-%m-%d %H:%M:%S')</strong><span>Captured At</span></div>
      <div class="meta-pill"><strong>${OS_FAMILY_UPPER} / ${INIT_UPPER}</strong><span>OS Family / Init</span></div>
      <div class="meta-pill"><strong>$(date +%Z)</strong><span>Timezone</span></div>
    </div>
  </div>
</div>

<!-- STAT BAR -->
<div class="statbar">
  <div class="stats-inner">
    <div class="stat">
      <div class="stat-lbl">vCPUs</div>
      <div class="stat-val">${cpu_count}</div>
      <div class="stat-sub">${cpu_model:0:20}...</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Memory</div>
      <div class="stat-val $([ "${mem_pct:-0}" -gt 85 ] 2>/dev/null && echo danger || [ "${mem_pct:-0}" -gt 65 ] 2>/dev/null && echo warn || echo ok)">${mem_used}/${mem_total}</div>
      <div class="bar"><div class="bar-fill" style="width:${mem_pct:-0}%;background:$([ "${mem_pct:-0}" -gt 85 ] 2>/dev/null && echo 'var(--danger)' || [ "${mem_pct:-0}" -gt 65 ] 2>/dev/null && echo 'var(--warn)' || echo 'var(--ok)')"></div></div>
      <div class="stat-sub">${mem_pct}% used</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Disks</div>
      <div class="stat-val">${diskcount}</div>
      <div class="stat-sub">block device(s)</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Root Disk</div>
      <div class="stat-val $([ "${disk_root:-0}" -gt 85 ] 2>/dev/null && echo danger || [ "${disk_root:-0}" -gt 65 ] 2>/dev/null && echo warn || echo ok)">${disk_root}%</div>
      <div class="bar"><div class="bar-fill" style="width:${disk_root:-0}%;background:$([ "${disk_root:-0}" -gt 85 ] 2>/dev/null && echo 'var(--danger)' || [ "${disk_root:-0}" -gt 65 ] 2>/dev/null && echo 'var(--warn)' || echo 'var(--ok)')"></div></div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Packages</div>
      <div class="stat-val">${pkgcount}</div>
      <div class="stat-sub">installed</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Services</div>
      <div class="stat-val ok">${running_svc}</div>
      <div class="stat-sub">running · <span style="color:$([ "${failed_svc:-0}" != "0" ] && [ "${failed_svc:-0}" != "N/A" ] && echo 'var(--danger)' || echo 'var(--muted)')">${failed_svc} failed</span></div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Open Ports</div>
      <div class="stat-val warn">${open_ports}</div>
      <div class="stat-sub">listening</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Load Avg</div>
      <div class="stat-val">${load_avg%% *}</div>
      <div class="stat-sub">${load_avg}</div>
    </div>
  </div>
</div>

<!-- MAIN LAYOUT -->
<div class="layout">
  <!-- SIDEBAR NAV -->
  <nav class="nav">
    <div class="nav-grp">System</div>
    <a class="active" href="#s01" onclick="act(this)"><span class="nav-ic">🖥</span>OS & System</a>
    <a href="#s02" onclick="act(this)"><span class="nav-ic">⚙</span>Kernel & Boot</a>
    <a href="#s03" onclick="act(this)"><span class="nav-ic">🔲</span>CPU</a>
    <a href="#s04" onclick="act(this)"><span class="nav-ic">💾</span>Memory</a>
    <a href="#s05" onclick="act(this)"><span class="nav-ic">🖧</span>Hardware</a>
    <a href="#s06" onclick="act(this)"><span class="nav-ic">🗄</span>Disk & Storage</a>
    <div class="nav-grp">Network</div>
    <a href="#s07" onclick="act(this)"><span class="nav-ic">🌐</span>Network</a>
    <a href="#s08" onclick="act(this)"><span class="nav-ic">🕒</span>NTP / Time</a>
    <a href="#s09" onclick="act(this)"><span class="nav-ic">🔌</span>Open Ports</a>
    <a href="#s10" onclick="act(this)"><span class="nav-ic">🛡</span>Firewall</a>
    <div class="nav-grp">Software</div>
    <a href="#s11" onclick="act(this)"><span class="nav-ic">📦</span>Packages</a>
    <a href="#s12" onclick="act(this)"><span class="nav-ic">⚡</span>Services</a>
    <div class="nav-grp">Security</div>
    <a href="#s13" onclick="act(this)"><span class="nav-ic">🔒</span>SELinux/PAM</a>
    <a href="#s14" onclick="act(this)"><span class="nav-ic">🕐</span>Cron & Timers</a>
    <a href="#s15" onclick="act(this)"><span class="nav-ic">👤</span>Users & Access</a>
    <a href="#s16" onclick="act(this)"><span class="nav-ic">🔐</span>/etc Checksums</a>
    <div class="nav-grp">Runtime</div>
    <a href="#s17" onclick="act(this)"><span class="nav-ic">🔄</span>Processes</a>
    <div class="nav-grp">Audit</div>
    <a href="#s18" onclick="act(this)"><span class="nav-ic">📋</span>Log Baseline</a>
    <a href="#s19" onclick="act(this)"><span class="nav-ic">♻</span>Boot History</a>
  </nav>

  <!-- CONTENT -->
  <div class="content">

    <div class="card" id="s01">
      <div class="card-hdr" onclick="tog(this)">
        <div class="card-title-row"><div class="card-ic">🖥</div>
          <div><div class="card-title">OS &amp; System Information</div>
               <div class="card-sub">$(hostname -f 2>/dev/null||hostname) &nbsp;·&nbsp; ${OS_PRETTY}</div></div></div>
        <div class="card-toggle open">▼</div></div>
      <div class="card-body open">
        <div class="info-grid">
          <div class="info-card">
            <div class="info-row"><span class="info-key">Hostname</span><span class="info-val">$(hostname -s 2>/dev/null||hostname)</span></div>
            <div class="info-row"><span class="info-key">FQDN</span><span class="info-val">$(hostname -f 2>/dev/null||hostname)</span></div>
            <div class="info-row"><span class="info-key">OS</span><span class="info-val">${OS_PRETTY}</span></div>
            <div class="info-row"><span class="info-key">Family</span><span class="info-val ok">${OS_FAMILY_UPPER}</span></div>
            <div class="info-row"><span class="info-key">Version</span><span class="info-val">${OS_VERSION}</span></div>
          </div>
          <div class="info-card">
            <div class="info-row"><span class="info-key">Kernel</span><span class="info-val ok">${kernel_ver}</span></div>
            <div class="info-row"><span class="info-key">Init System</span><span class="info-val">${INIT_SYSTEM}</span></div>
            <div class="info-row"><span class="info-key">Uptime</span><span class="info-val">${uptime_val}</span></div>
            <div class="info-row"><span class="info-key">Load Avg</span><span class="info-val">${load_avg}</span></div>
            <div class="info-row"><span class="info-key">Snapshot Mode</span><span class="info-val">${MODE_UPPER}</span></div>
          </div>
        </div>
        <pre>$(html_escape "${SNAPSHOT_DIR}/01_os_info.txt")</pre>
      </div>
    </div>

    <div class="card" id="s02"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">⚙</div><div><div class="card-title">Kernel &amp; Boot Configuration</div><div class="card-sub">${kernel_ver} &nbsp;·&nbsp; grub + modules + sysctl</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/02_kernel.txt")</pre></div></div>

    <div class="card" id="s03"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🔲</div><div><div class="card-title">CPU Information</div><div class="card-sub">${cpu_count} vCPU(s) &nbsp;·&nbsp; ${cpu_model:0:50}</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/03_cpu.txt")</pre></div></div>

    <div class="card" id="s04"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">💾</div><div><div class="card-title">Memory &amp; Swap</div><div class="card-sub">${mem_used} / ${mem_total} &nbsp;·&nbsp; ${mem_pct}% utilization</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/04_memory.txt")</pre></div></div>

    <div class="card" id="s05"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🖧</div><div><div class="card-title">Hardware</div><div class="card-sub">BIOS · dmidecode · PCI · SCSI · RAID</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/05_hardware.txt")</pre></div></div>

    <div class="card" id="s06"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🗄</div><div><div class="card-title">Disk &amp; Storage</div><div class="card-sub">${diskcount} disk(s) &nbsp;·&nbsp; LVM · multipath · mounts · fstab</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/06_disk.txt")</pre></div></div>

    <div class="card" id="s07"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🌐</div><div><div class="card-title">Network Configuration</div><div class="card-sub">interfaces · routing · bonding · config files · VLANs</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/07_network.txt")</pre></div></div>

    <div class="card" id="s08"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🕒</div><div><div class="card-title">NTP / Time Sync</div><div class="card-sub">chrony · ntp · hwclock · $(date '+%Y-%m-%d %H:%M:%S %Z')</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/08_ntp.txt")</pre></div></div>

    <div class="card" id="s09"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🔌</div><div><div class="card-title">Open Ports &amp; Connections</div><div class="card-sub">${open_ports} listening ports</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/09_ports.txt")</pre></div></div>

    <div class="card" id="s10"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🛡</div><div><div class="card-title">Firewall Rules</div><div class="card-sub">firewalld · iptables · ip6tables · ufw</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/10_firewall.txt")</pre></div></div>

    <div class="card" id="s11"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">📦</div><div><div class="card-title">Packages &amp; Repositories</div><div class="card-sub">${pkgcount} packages · installed kernels · repo files · history</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/11_packages.txt")</pre></div></div>

    <div class="card" id="s12"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">⚡</div><div><div class="card-title">Services (${INIT_SYSTEM})</div><div class="card-sub">${running_svc} running · ${failed_svc} failed · chkconfig/systemctl</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/12_services.txt")</pre></div></div>

    <div class="card" id="s13"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🔒</div><div><div class="card-title">Security Policy</div><div class="card-sub">SELinux: ${selinux_s} · AppArmor · PAM · SSH · limits</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/13_security_policy.txt")</pre></div></div>

    <div class="card" id="s14"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🕐</div><div><div class="card-title">Cron Jobs &amp; Timers</div><div class="card-sub">crontabs · cron.d · systemd timers · at jobs</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/14_cron.txt")</pre></div></div>

    <div class="card" id="s15"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">👤</div><div><div class="card-title">User Accounts &amp; Access</div><div class="card-sub">passwd · groups · sudo · SSH keys · last logins</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/15_users.txt")</pre></div></div>

    <div class="card" id="s16"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🔐</div><div><div class="card-title">/etc Configuration Checksums</div><div class="card-sub">MD5 hashes · sensitive files excluded</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/16_etc_checksums.txt")</pre></div></div>

    <div class="card" id="s17"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">🔄</div><div><div class="card-title">Process Snapshot</div><div class="card-sub">ps tree · top CPU/MEM · zombies</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/17_processes.txt")</pre></div></div>

    <div class="card" id="s18"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">📋</div><div><div class="card-title">System Log Baseline</div><div class="card-sub">syslog · dmesg · journal · auth · boot</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/18_logs.txt")</pre></div></div>

    <div class="card" id="s19"><div class="card-hdr" onclick="tog(this)"><div class="card-title-row"><div class="card-ic">♻</div><div><div class="card-title">Boot &amp; Uptime History</div><div class="card-sub">last | grep boot · uptime · /proc/uptime · dmesg</div></div></div><div class="card-toggle">▼</div></div><div class="card-body"><pre>$(html_escape "${SNAPSHOT_DIR}/19_boot_history.txt")</pre></div></div>

  </div><!-- /content -->
</div><!-- /layout -->

<div class="footer">
  <span>Config Snapshot Tool v2.0 &nbsp;·&nbsp; $(hostname -f 2>/dev/null||hostname) &nbsp;·&nbsp; ${MODE_UPPER} &nbsp;·&nbsp; $(date '+%Y-%m-%d %H:%M:%S')</span>
  <span>${SNAPSHOT_DIR}</span>
</div>

<script>
function tog(h){
  var b=h.nextElementSibling,t=h.querySelector('.card-toggle');
  b.classList.toggle('open');t.classList.toggle('open');
}
function act(a){
  document.querySelectorAll('.nav a').forEach(function(x){x.classList.remove('active')});
  a.classList.add('active');
  var id=a.getAttribute('href');
  var el=document.querySelector(id);
  if(el){
    el.scrollIntoView({behavior:'smooth',block:'start'});
    var b=el.querySelector('.card-body'),t=el.querySelector('.card-toggle');
    if(b&&!b.classList.contains('open')){b.classList.add('open');if(t)t.classList.add('open');}
  }
  return false;
}
</script>
</body></html>
HTMLEOF

    echo -e "  ${GREEN}[✔]${RESET} ${WHITE}HTML Report Generated${RESET}  ${DIM}${HTML_REPORT}${RESET}"
}

# =============================================================================
#  ARCHIVE
# =============================================================================
create_archive() {
    if [ "$ARCHIVE" -eq 1 ]; then
        local tarfile="${SNAPSHOT_DIR}.tar.gz"
        echo ""
        echo -e "  ${BOLD}${YELLOW}▶  Creating archive...${RESET}"
        tar -czf "$tarfile" -C "${BASE_DIR}" "$(basename "$SNAPSHOT_DIR")" 2>/dev/null \
            && echo -e "  ${GREEN}[✔]${RESET} Archive: ${tarfile}" \
            || echo -e "  ${RED}[✘]${RESET} Archive failed"
    fi
}

# =============================================================================
#  FIND LATEST PRE SNAPSHOT
# =============================================================================
find_pre_snapshot() {
    if [ -n "$PRE_DIR_OVERRIDE" ]; then
        [ -d "$PRE_DIR_OVERRIDE" ] && echo "$PRE_DIR_OVERRIDE" || echo ""
        return
    fi
    # Auto-locate most recent pre snapshot for this host
    local latest
    latest=$(ls -dt "${BASE_DIR}/${HOSTNAME_SHORT}_pre_"* 2>/dev/null | head -1)
    echo "$latest"
}

# =============================================================================
#  META JSON
# =============================================================================
write_meta() {
    local pkgcount
    case "$OS_FAMILY" in
        rhel|suse) pkgcount=$(rpm -qa 2>/dev/null | wc -l) ;;
        debian)    pkgcount=$(dpkg -l 2>/dev/null | grep '^ii' | wc -l) ;;
        *) pkgcount=0 ;;
    esac

    cat > "${SNAPSHOT_DIR}/snapshot_meta.json" << METAEOF
{
  "schema_version" : "2.0",
  "mode"           : "${MODE}",
  "hostname"       : "$(hostname -f 2>/dev/null || hostname)",
  "hostname_short" : "${HOSTNAME_SHORT}",
  "os_pretty"      : "${OS_PRETTY}",
  "os_family"      : "${OS_FAMILY}",
  "os_version"     : "${OS_VERSION}",
  "os_major"       : "${OS_MAJOR}",
  "init_system"    : "${INIT_SYSTEM}",
  "kernel"         : "$(uname -r)",
  "arch"           : "$(uname -m)",
  "timestamp"      : "$(date '+%Y-%m-%d %H:%M:%S')",
  "timestamp_epoch": "$(date +%s)",
  "snapshot_dir"   : "${SNAPSHOT_DIR}",
  "html_report"    : "${HTML_REPORT}",
  "packages"       : ${pkgcount}
}
METAEOF
}

# =============================================================================
#  DISK SPACE GUARD
# =============================================================================
check_tmp_space() {
    local avail_kb
    avail_kb=$(df /tmp 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 102400 ]; then
        echo -e "${YELLOW}WARNING: Less than 100MB free in /tmp (${avail_kb} KB). Snapshot may be incomplete.${RESET}"
    fi
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    detect_os
    # Pre-compute uppercase strings — tr works on bash 2.x through 5.x
    # Replaces ${VAR^^} which is bash 4+ only and breaks SLES9/10/11, RHEL5/6
    MODE_UPPER=$(echo "$MODE" | tr '[:lower:]' '[:upper:]')
    OS_FAMILY_UPPER=$(echo "$OS_FAMILY" | tr '[:lower:]' '[:upper:]')
    INIT_UPPER=$(echo "$INIT_SYSTEM" | tr '[:lower:]' '[:upper:]')
    check_tmp_space
    print_banner

    # Show active skip settings
    if [ -n "$SKIP_MODULES" ]; then
        echo -e "  ${YELLOW}⚠  Skipping modules : ${SKIP_MODULES}${RESET}"
    fi
    echo ""

    print_section "System & Hardware"
    should_skip "01" "os_info"    || capture_os_info
    should_skip "02" "kernel"     || capture_kernel
    should_skip "03" "cpu"        || capture_cpu
    should_skip "04" "memory"     || capture_memory
    should_skip "05" "hardware"   || capture_hardware

    print_section "Storage"
    should_skip "06" "disk"       || capture_disk

    print_section "Network & Time"
    should_skip "07" "network"    || capture_network
    should_skip "08" "ntp"        || capture_ntp
    should_skip "09" "ports"      || capture_ports
    should_skip "10" "firewall"   || capture_firewall

    print_section "Software & Services"
    should_skip "11" "packages"   || capture_packages
    should_skip "12" "services"   || capture_services

    print_section "Security & Users"
    should_skip "13" "security"   || capture_security_policy
    should_skip "14" "cron"       || capture_cron
    should_skip "15" "users"      || capture_users
    should_skip "16" "checksums"  || capture_etc_checksums

    print_section "Runtime & Audit"
    should_skip "17" "processes"  || capture_processes
    should_skip "18" "logs"       || capture_logs
    should_skip "19" "boot"       || capture_reboot_history

    generate_html_report
    write_meta
    create_archive

    local END_TIME DURATION
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    local mode_color
    [ "$MODE" = "pre" ] && mode_color="$CYAN" || mode_color="$YELLOW"

    echo ""
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "  ${BOLD}${mode_color}✔  ${MODE_UPPER}-REBOOT SNAPSHOT COMPLETE${RESET}"
    echo ""
    echo -e "  ${WHITE}Snapshot Dir  :${RESET} ${DIM}${SNAPSHOT_DIR}${RESET}"
    echo -e "  ${WHITE}HTML Report   :${RESET} ${mode_color}${HTML_REPORT}${RESET}"
    echo -e "  ${WHITE}Duration      :${RESET} ${CYAN}${DURATION} second(s)${RESET}"
    echo -e "  ${WHITE}Captured At   :${RESET} $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    if [ "$MODE" = "pre" ]; then
        echo -e "  ${CYAN}★  PRE snapshot saved. Before rebooting, note this path:${RESET}"
        echo -e "  ${WHITE}   ${SNAPSHOT_DIR}${RESET}"
        echo ""
        echo -e "  ${CYAN}  After reboot, run:${RESET}"
        echo -e "  ${DIM}  sudo bash config_snapshot.sh --mode post${RESET}"
        echo -e "  ${DIM}  sudo bash diff_report.sh --pre ${SNAPSHOT_DIR} --post <post_dir>${RESET}"
    else
        local pre_snap
        pre_snap=$(find_pre_snapshot)
        if [ -n "$pre_snap" ]; then
            echo -e "  ${GREEN}★  Pre-snapshot found. Generate diff report:${RESET}"
            echo -e "  ${CYAN}  sudo bash diff_report.sh \\${RESET}"
            echo -e "  ${CYAN}    --pre  ${pre_snap} \\${RESET}"
            echo -e "  ${CYAN}    --post ${SNAPSHOT_DIR}${RESET}"
        else
            echo -e "  ${YELLOW}⚠  No pre-snapshot found automatically.${RESET}"
            echo -e "  ${YELLOW}  Run: sudo bash diff_report.sh --pre <pre_dir> --post ${SNAPSHOT_DIR}${RESET}"
        fi
    fi
    echo ""
}

main "$@"
