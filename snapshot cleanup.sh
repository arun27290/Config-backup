#!/bin/bash
# =============================================================================
#  SNAPSHOT CLEANUP TOOL  —  /tmp Space Manager
#  Author  : Linux Infrastructure Team
#  Version : 2.0
#
#  Usage:
#    sudo bash snapshot_cleanup.sh               # Interactive mode
#    sudo bash snapshot_cleanup.sh --days 7      # Remove snapshots older than 7 days
#    sudo bash snapshot_cleanup.sh --keep 5      # Keep only 5 most recent snapshot sets
#    sudo bash snapshot_cleanup.sh --dry-run     # Show what would be removed, don't delete
#    sudo bash snapshot_cleanup.sh --list        # List all snapshots with sizes
#    sudo bash snapshot_cleanup.sh --days 3 --dry-run
# =============================================================================

set -uo pipefail

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; BOLD=''; DIM=''; RESET=''
fi

BASE_DIR="/tmp/snapshots"
DRY_RUN=0
LIST_ONLY=0
DAYS=""
KEEP=""

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1;     shift ;;
        --list)     LIST_ONLY=1;   shift ;;
        --days)     DAYS="$2";     shift 2 ;;
        --keep)     KEEP="$2";     shift 2 ;;
        --help|-h)  grep '^#  ' "$0" | sed 's/^#  //'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
hr() { echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"; }

human_size() {
    local path="$1"
    du -sh "$path" 2>/dev/null | awk '{print $1}' || echo "?"
}

total_snapshot_size() {
    du -sh "${BASE_DIR}" 2>/dev/null | awk '{print $1}' || echo "?"
}

tmp_free() {
    df -h /tmp 2>/dev/null | tail -1 | awk '{print $4}' || echo "?"
}

tmp_used_pct() {
    df /tmp 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || echo "0"
}

list_snapshots() {
    echo ""
    echo -e "  ${BOLD}${CYAN}Snapshot Inventory — ${BASE_DIR}${RESET}"
    hr
    echo ""

    if [ ! -d "$BASE_DIR" ]; then
        echo -e "  ${YELLOW}No snapshot directory found at ${BASE_DIR}${RESET}"
        return
    fi

    local total_dirs=0 total_bytes=0

    # List directories (pre/post/diff)
    for mode in pre post diff; do
        local dirs
        dirs=$(ls -dt "${BASE_DIR}"/*_${mode}_* 2>/dev/null | head -50)
        if [ -z "$dirs" ]; then
            continue
        fi
        echo -e "  ${WHITE}${BOLD}${mode^^} Snapshots:${RESET}"
        echo "$dirs" | while IFS= read -r d; do
            [ -d "$d" ] || [ -f "$d" ] || continue
            local size ts name
            size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
            name=$(basename "$d")
            # Extract timestamp from name
            ts=$(echo "$name" | grep -oE '[0-9]{8}_[0-9]{6}' | head -1)
            if [ -n "$ts" ]; then
                local yr mo dy hr mi
                yr=${ts:0:4}; mo=${ts:4:2}; dy=${ts:6:2}; hr=${ts:9:2}; mi=${ts:11:2}
                ts="${yr}-${mo}-${dy} ${hr}:${mi}"
            fi
            echo -e "    ${DIM}${ts}${RESET}  ${size:-?}  ${DIM}${d}${RESET}"
            total_dirs=$((total_dirs + 1))
        done
    done

    # HTML reports
    local html_count
    html_count=$(ls "${BASE_DIR}"/*.html 2>/dev/null | wc -l)

    echo ""
    echo -e "  ${WHITE}HTML Reports:${RESET} ${html_count}"
    ls "${BASE_DIR}"/*.html 2>/dev/null | while IFS= read -r h; do
        local hsize
        hsize=$(du -sh "$h" 2>/dev/null | awk '{print $1}')
        echo -e "    ${hsize:-?}  ${DIM}${h}${RESET}"
    done

    echo ""
    hr
    local total_sz
    total_sz=$(du -sh "${BASE_DIR}" 2>/dev/null | awk '{print $1}')
    echo -e "  ${WHITE}Total snapshot usage :${RESET} ${YELLOW}${total_sz:-?}${RESET}"
    echo -e "  ${WHITE}/tmp free space      :${RESET} ${GREEN}$(tmp_free)${RESET}"
    local pct
    pct=$(tmp_used_pct)
    local pct_color="$GREEN"
    [ "$pct" -gt 70 ] 2>/dev/null && pct_color="$YELLOW"
    [ "$pct" -gt 85 ] 2>/dev/null && pct_color="$RED"
    echo -e "  ${WHITE}/tmp used            :${RESET} ${pct_color}${pct}%${RESET}"
    echo ""
}

remove_item() {
    local path="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "  ${YELLOW}[DRY-RUN]${RESET} Would remove: ${DIM}${path}${RESET}"
    else
        rm -rf "$path" 2>/dev/null && \
            echo -e "  ${GREEN}[✔]${RESET} Removed: ${DIM}${path}${RESET}" || \
            echo -e "  ${RED}[✘]${RESET} Failed to remove: ${path}"
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║          SNAPSHOT CLEANUP & SPACE MANAGER                      ║"
echo "  ║                Linux Infrastructure Team                       ║"
echo -e "  ╚══════════════════════════════════════════════════════════════╝${RESET}"

# ---------------------------------------------------------------------------
# LIST only
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" -eq 1 ]; then
    list_snapshots
    exit 0
fi

# ---------------------------------------------------------------------------
# Always show inventory first
# ---------------------------------------------------------------------------
list_snapshots

# ---------------------------------------------------------------------------
# Remove by age
# ---------------------------------------------------------------------------
if [ -n "$DAYS" ]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}▶  Removing snapshots older than ${DAYS} days...${RESET}"
    hr
    [ "$DRY_RUN" -eq 1 ] && echo -e "  ${YELLOW}DRY-RUN mode — nothing will be deleted${RESET}"
    echo ""

    # Find snapshot dirs and HTML files older than N days
    if command -v find >/dev/null 2>&1; then
        # Dirs
        find "${BASE_DIR}" -maxdepth 1 -type d -name "*_pre_*" -o \
                                        -type d -name "*_post_*" -o \
                                        -type d -name "*_diff_*" 2>/dev/null | \
        while IFS= read -r d; do
            # Get mtime via stat or ls
            local age_ok=0
            if stat -c "%Y" "$d" >/dev/null 2>&1; then
                local mtime now age_days
                mtime=$(stat -c "%Y" "$d" 2>/dev/null)
                now=$(date +%s)
                age_days=$(( (now - mtime) / 86400 ))
                [ "$age_days" -ge "$DAYS" ] && remove_item "$d"
            else
                # fallback: use find -mtime
                find "$d" -maxdepth 0 -mtime +"${DAYS}" 2>/dev/null | grep -q . && remove_item "$d"
            fi
        done

        # HTML files
        find "${BASE_DIR}" -maxdepth 1 -name "*.html" -mtime +"${DAYS}" 2>/dev/null | \
        while IFS= read -r h; do
            remove_item "$h"
        done
    fi

    echo ""
    echo -e "  ${GREEN}Done.${RESET}  /tmp free: $(tmp_free)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Remove by count — keep N most recent snapshot PAIRS (pre+post)
# ---------------------------------------------------------------------------
if [ -n "$KEEP" ]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}▶  Keeping ${KEEP} most recent snapshot sets, removing the rest...${RESET}"
    hr
    [ "$DRY_RUN" -eq 1 ] && echo -e "  ${YELLOW}DRY-RUN mode — nothing will be deleted${RESET}"
    echo ""

    # Find unique host_timestamp combos for pre snapshots (the base of a set)
    local all_pre
    all_pre=$(ls -dt "${BASE_DIR}"/*_pre_* 2>/dev/null | grep -v "\.html$" | head -100)

    local count=0
    echo "$all_pre" | while IFS= read -r pre_dir; do
        count=$((count + 1))
        if [ "$count" -gt "$KEEP" ]; then
            remove_item "$pre_dir"
            # Try to remove matching post/diff
            local base ts
            base=$(basename "$pre_dir")
            # ts portion: last two _ separated fields
            ts=$(echo "$base" | grep -oE '[0-9]{8}_[0-9]{6}$')
            host=$(echo "$base" | sed "s/_pre_${ts}//")
            for mode in post diff; do
                local match="${BASE_DIR}/${host}_${mode}_${ts}"
                [ -d "$match" ] && remove_item "$match"
                [ -f "${match}.html" ] && remove_item "${match}.html"
            done
            [ -f "${pre_dir}.html" ] && remove_item "${pre_dir}.html"
        fi
    done

    echo ""
    echo -e "  ${GREEN}Done.${RESET}  /tmp free: $(tmp_free)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Interactive mode (no flags)
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${BOLD}Choose cleanup action:${RESET}"
echo ""
echo -e "  ${WHITE}1)${RESET} Remove snapshots older than N days"
echo -e "  ${WHITE}2)${RESET} Keep only N most recent snapshot sets"
echo -e "  ${WHITE}3)${RESET} Remove ALL snapshots (DANGER)"
echo -e "  ${WHITE}4)${RESET} Exit"
echo ""
printf "  Enter choice [1-4]: "
read -r CHOICE </dev/tty

case "$CHOICE" in
    1)
        printf "  Remove snapshots older than how many days? [7]: "
        read -r d </dev/tty
        d=${d:-7}
        echo "$0 --days ${d}"
        exec bash "$0" --days "$d"
        ;;
    2)
        printf "  Keep how many recent snapshot sets? [3]: "
        read -r k </dev/tty
        k=${k:-3}
        exec bash "$0" --keep "$k"
        ;;
    3)
        echo -e "  ${RED}WARNING: This will remove ALL snapshots in ${BASE_DIR}${RESET}"
        printf "  Type YES to confirm: "
        read -r confirm </dev/tty
        if [ "$confirm" = "YES" ]; then
            rm -rf "${BASE_DIR:?}"/*_pre_* "${BASE_DIR:?}"/*_post_* \
                   "${BASE_DIR:?}"/*_diff_* "${BASE_DIR:?}"/*.html 2>/dev/null
            echo -e "  ${GREEN}All snapshots removed.${RESET}"
        else
            echo -e "  ${YELLOW}Cancelled.${RESET}"
        fi
        ;;
    4)
        echo -e "  Exiting."
        exit 0
        ;;
    *)
        echo -e "  ${RED}Invalid choice.${RESET}"
        exit 1
        ;;
esac
