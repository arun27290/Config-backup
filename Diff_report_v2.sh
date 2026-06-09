#!/bin/bash
# =============================================================================
#  DIFF REPORT TOOL  —  Pre vs Post Reboot Comparison
#  Supports: All OS families captured by config_snapshot.sh v2.0
#  Author  : Linux Infrastructure Team
#  Version : 2.0
#
#  Usage:
#    sudo bash diff_report.sh --pre <pre_dir> --post <post_dir>
#    sudo bash diff_report.sh --pre /tmp/snapshots/srv01_pre_20250601_120000 \
#                             --post /tmp/snapshots/srv01_post_20250601_140000
#
#  Output:  /tmp/snapshots/<hostname>_diff_<timestamp>.html
# =============================================================================

set -uo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    : # allow non-root for diff report
fi

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; WHITE='\033[1;37m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; BOLD=''; DIM=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
PRE_DIR=""
POST_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pre)  PRE_DIR="$2";  shift 2 ;;
        --post) POST_DIR="$2"; shift 2 ;;
        --help|-h) grep '^#  ' "$0" | sed 's/^#  //'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$PRE_DIR" ] || [ -z "$POST_DIR" ]; then
    echo "ERROR: --pre and --post are required." >&2
    exit 1
fi
for d in "$PRE_DIR" "$POST_DIR"; do
    [ -d "$d" ] || { echo "ERROR: Directory not found: $d" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
BASE_DIR="/tmp/snapshots"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
DIFF_DIR="${BASE_DIR}/${HOSTNAME_SHORT}_diff_${TIMESTAMP}"
HTML_REPORT="${BASE_DIR}/${HOSTNAME_SHORT}_diff_${TIMESTAMP}.html"
DIFF_LOG="${DIFF_DIR}/diff.log"
START_TIME=$(date +%s)

mkdir -p "$DIFF_DIR"

log() { echo "$1" | tee -a "$DIFF_LOG"; }

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════════════╗"
echo "  ║        PRE vs POST REBOOT DIFF REPORT GENERATOR                ║"
echo "  ║                Linux Infrastructure Team                       ║"
echo -e "  ╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${WHITE}Pre  :${RESET} ${DIM}${PRE_DIR}${RESET}"
echo -e "  ${WHITE}Post :${RESET} ${DIM}${POST_DIR}${RESET}"
echo -e "  ${WHITE}Out  :${RESET} ${DIM}${HTML_REPORT}${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Read meta JSON (simple key:value grep — no jq dependency)
# ---------------------------------------------------------------------------
meta_get() {
    local file="$1" key="$2"
    grep "\"${key}\"" "$file" 2>/dev/null | head -1 | sed 's/.*: *"\(.*\)".*/\1/'
}

PRE_META="${PRE_DIR}/snapshot_meta.json"
POST_META="${POST_DIR}/snapshot_meta.json"

PRE_HOST=$(meta_get "$PRE_META" "hostname")
PRE_OS=$(meta_get "$PRE_META" "os_pretty")
PRE_KERNEL=$(meta_get "$PRE_META" "kernel")
PRE_INIT=$(meta_get "$PRE_META" "init_system")
PRE_TIME=$(meta_get "$PRE_META" "timestamp")
PRE_PKGS=$(meta_get "$PRE_META" "packages")

POST_HOST=$(meta_get "$POST_META" "hostname")
POST_OS=$(meta_get "$POST_META" "os_pretty")
POST_KERNEL=$(meta_get "$POST_META" "kernel")
POST_INIT=$(meta_get "$POST_META" "init_system")
POST_TIME=$(meta_get "$POST_META" "timestamp")
POST_PKGS=$(meta_get "$POST_META" "packages")

HOSTNAME_DISPLAY="${POST_HOST:-${HOSTNAME_SHORT}}"

# ---------------------------------------------------------------------------
# Diff helper — produces structured lines  ADDED/REMOVED/CHANGED
# ---------------------------------------------------------------------------
run_diff() {
    local pre_file="$1"
    local post_file="$2"
    local out_file="$3"

    if [ ! -f "$pre_file" ] && [ ! -f "$post_file" ]; then
        echo "BOTH_MISSING" > "$out_file"
        return
    fi
    if [ ! -f "$pre_file" ]; then
        echo "PRE_MISSING" > "$out_file"
        return
    fi
    if [ ! -f "$post_file" ]; then
        echo "POST_MISSING" > "$out_file"
        return
    fi

    diff --unified=3 "$pre_file" "$post_file" > "$out_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Package diff — returns structured added/removed lists
# ---------------------------------------------------------------------------
diff_packages() {
    local pre_pkg="${PRE_DIR}/11_packages.txt"
    local post_pkg="${POST_DIR}/11_packages.txt"

    # Extract just the package list lines (NAME|VER|REL|ARCH format)
    grep -E "^[a-zA-Z0-9_\.\-]+\|" "$pre_pkg"  2>/dev/null | sort > "${DIFF_DIR}/pkgs_pre.txt"
    grep -E "^[a-zA-Z0-9_\.\-]+\|" "$post_pkg" 2>/dev/null | sort > "${DIFF_DIR}/pkgs_post.txt"

    comm -23 "${DIFF_DIR}/pkgs_pre.txt"  "${DIFF_DIR}/pkgs_post.txt" > "${DIFF_DIR}/pkgs_removed.txt" 2>/dev/null || true
    comm -13 "${DIFF_DIR}/pkgs_pre.txt"  "${DIFF_DIR}/pkgs_post.txt" > "${DIFF_DIR}/pkgs_added.txt"   2>/dev/null || true

    # Upgraded = same name, different version
    local pre_names post_names
    awk -F'|' '{print $1}' "${DIFF_DIR}/pkgs_pre.txt"  | sort > "${DIFF_DIR}/pkg_names_pre.txt"
    awk -F'|' '{print $1}' "${DIFF_DIR}/pkgs_post.txt" | sort > "${DIFF_DIR}/pkg_names_post.txt"
    comm -12 "${DIFF_DIR}/pkg_names_pre.txt" "${DIFF_DIR}/pkg_names_post.txt" > "${DIFF_DIR}/pkg_names_common.txt" 2>/dev/null || true

    > "${DIFF_DIR}/pkgs_upgraded.txt"
    while IFS= read -r name; do
        local pre_line post_line
        pre_line=$(grep "^${name}|" "${DIFF_DIR}/pkgs_pre.txt"  | head -1)
        post_line=$(grep "^${name}|" "${DIFF_DIR}/pkgs_post.txt" | head -1)
        if [ "$pre_line" != "$post_line" ]; then
            echo "FROM: $pre_line" >> "${DIFF_DIR}/pkgs_upgraded.txt"
            echo "  TO: $post_line" >> "${DIFF_DIR}/pkgs_upgraded.txt"
        fi
    done < "${DIFF_DIR}/pkg_names_common.txt"
}

# ---------------------------------------------------------------------------
# Service diff
# ---------------------------------------------------------------------------
diff_services() {
    local pre_svc="${PRE_DIR}/12_services.txt"
    local post_svc="${POST_DIR}/12_services.txt"

    # Extract running service names
    grep -E "running" "$pre_svc"  2>/dev/null | awk '{print $1}' | sort > "${DIFF_DIR}/svc_running_pre.txt"
    grep -E "running" "$post_svc" 2>/dev/null | awk '{print $1}' | sort > "${DIFF_DIR}/svc_running_post.txt"

    comm -23 "${DIFF_DIR}/svc_running_pre.txt"  "${DIFF_DIR}/svc_running_post.txt" > "${DIFF_DIR}/svc_stopped.txt"  2>/dev/null || true
    comm -13 "${DIFF_DIR}/svc_running_pre.txt"  "${DIFF_DIR}/svc_running_post.txt" > "${DIFF_DIR}/svc_started.txt"  2>/dev/null || true

    # Enabled units
    grep -E "enabled" "$pre_svc"  2>/dev/null | awk '{print $1}' | sort > "${DIFF_DIR}/svc_enabled_pre.txt"
    grep -E "enabled" "$post_svc" 2>/dev/null | awk '{print $1}' | sort > "${DIFF_DIR}/svc_enabled_post.txt"
    comm -23 "${DIFF_DIR}/svc_enabled_pre.txt"  "${DIFF_DIR}/svc_enabled_post.txt" > "${DIFF_DIR}/svc_disabled.txt"  2>/dev/null || true
    comm -13 "${DIFF_DIR}/svc_enabled_pre.txt"  "${DIFF_DIR}/svc_enabled_post.txt" > "${DIFF_DIR}/svc_newly_enabled.txt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Checksum diff — which /etc files changed
# ---------------------------------------------------------------------------
diff_checksums() {
    local pre_cs="${PRE_DIR}/16_etc_checksums.txt"
    local post_cs="${POST_DIR}/16_etc_checksums.txt"

    grep -E "^[a-f0-9]{32}" "$pre_cs"  2>/dev/null | sort -k2 > "${DIFF_DIR}/cs_pre.txt"
    grep -E "^[a-f0-9]{32}" "$post_cs" 2>/dev/null | sort -k2 > "${DIFF_DIR}/cs_post.txt"

    # Extract just file paths into separate sorted temp files.
    # Using explicit temp files instead of <() process substitution —
    # <() requires bash 3.1+ and fails on SLES9 (bash 2.05b).
    awk '{print $2}' "${DIFF_DIR}/cs_pre.txt"  | sort > "${DIFF_DIR}/cs_pre_paths.txt"
    awk '{print $2}' "${DIFF_DIR}/cs_post.txt" | sort > "${DIFF_DIR}/cs_post_paths.txt"

    # Files only in pre (removed)
    comm -23 "${DIFF_DIR}/cs_pre_paths.txt" "${DIFF_DIR}/cs_post_paths.txt" \
        > "${DIFF_DIR}/cs_removed_files.txt" 2>/dev/null || true

    # Files only in post (new)
    comm -13 "${DIFF_DIR}/cs_pre_paths.txt" "${DIFF_DIR}/cs_post_paths.txt" \
        > "${DIFF_DIR}/cs_new_files.txt" 2>/dev/null || true

    # Files present in both — write common paths to temp file
    comm -12 "${DIFF_DIR}/cs_pre_paths.txt" "${DIFF_DIR}/cs_post_paths.txt" \
        > "${DIFF_DIR}/cs_common_paths.txt" 2>/dev/null || true

    # Files in both but hash changed — compare hashes for each common path
    > "${DIFF_DIR}/cs_modified.txt"
    while IFS= read -r filepath; do
        local pre_hash post_hash
        pre_hash=$(grep " ${filepath}$" "${DIFF_DIR}/cs_pre.txt"  | awk '{print $1}')
        post_hash=$(grep " ${filepath}$" "${DIFF_DIR}/cs_post.txt" | awk '{print $1}')
        if [ -n "$pre_hash" ] && [ -n "$post_hash" ] && [ "$pre_hash" != "$post_hash" ]; then
            echo "$filepath" >> "${DIFF_DIR}/cs_modified.txt"
        fi
    done < "${DIFF_DIR}/cs_common_paths.txt"
}

# ---------------------------------------------------------------------------
# Port diff
# ---------------------------------------------------------------------------
diff_ports() {
    local pre_p="${PRE_DIR}/09_ports.txt"
    local post_p="${POST_DIR}/09_ports.txt"

    grep -E "LISTEN" "$pre_p"  2>/dev/null | awk '{print $(NF-0)}' | grep -oE ':[0-9]+' | sort -u > "${DIFF_DIR}/ports_pre.txt"
    grep -E "LISTEN" "$post_p" 2>/dev/null | awk '{print $(NF-0)}' | grep -oE ':[0-9]+' | sort -u > "${DIFF_DIR}/ports_post.txt"

    comm -23 "${DIFF_DIR}/ports_pre.txt"  "${DIFF_DIR}/ports_post.txt" > "${DIFF_DIR}/ports_closed.txt"  2>/dev/null || true
    comm -13 "${DIFF_DIR}/ports_pre.txt"  "${DIFF_DIR}/ports_post.txt" > "${DIFF_DIR}/ports_opened.txt"  2>/dev/null || true
}

# ---------------------------------------------------------------------------
# User diff
# ---------------------------------------------------------------------------
diff_users() {
    local pre_u="${PRE_DIR}/15_users.txt"
    local post_u="${POST_DIR}/15_users.txt"

    grep -v "^#" "$pre_u"  2>/dev/null | grep "^[a-zA-Z]" | grep -A9999 "ALL USER ACCOUNTS" | grep -B9999 "ALL GROUPS" | grep ":" | sort > "${DIFF_DIR}/users_pre.txt" 2>/dev/null || \
    grep -v "^[=#]" "$pre_u"  2>/dev/null | grep ":" | head -60 | sort > "${DIFF_DIR}/users_pre.txt"

    grep -v "^#" "$post_u" 2>/dev/null | grep "^[a-zA-Z]" | grep -A9999 "ALL USER ACCOUNTS" | grep -B9999 "ALL GROUPS" | grep ":" | sort > "${DIFF_DIR}/users_post.txt" 2>/dev/null || \
    grep -v "^[=#]" "$post_u" 2>/dev/null | grep ":" | head -60 | sort > "${DIFF_DIR}/users_post.txt"

    comm -23 "${DIFF_DIR}/users_pre.txt"  "${DIFF_DIR}/users_post.txt" > "${DIFF_DIR}/users_removed.txt" 2>/dev/null || true
    comm -13 "${DIFF_DIR}/users_pre.txt"  "${DIFF_DIR}/users_post.txt" > "${DIFF_DIR}/users_added.txt"   2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run all diffs
# ---------------------------------------------------------------------------
echo -e "  ${YELLOW}▶  Computing diffs...${RESET}"

SECTIONS=(
    "01_os_info.txt"      "02_kernel.txt"      "03_cpu.txt"
    "04_memory.txt"       "05_hardware.txt"    "06_disk.txt"
    "07_network.txt"      "08_ntp.txt"         "09_ports.txt"
    "10_firewall.txt"     "11_packages.txt"    "12_services.txt"
    "13_security_policy.txt" "14_cron.txt"     "15_users.txt"
    "16_etc_checksums.txt" "17_processes.txt"  "18_logs.txt"
    "19_boot_history.txt"
)

for sec in "${SECTIONS[@]}"; do
    run_diff "${PRE_DIR}/${sec}" "${POST_DIR}/${sec}" "${DIFF_DIR}/diff_${sec}"
    echo -e "  ${GREEN}[✔]${RESET} Diff: ${sec}"
done

echo ""
echo -e "  ${YELLOW}▶  Analysing packages, services, users, checksums...${RESET}"
diff_packages
diff_services
diff_checksums
diff_ports
diff_users

# ---------------------------------------------------------------------------
# Compute summary counts
# ---------------------------------------------------------------------------
pkgs_added_count=$(wc -l < "${DIFF_DIR}/pkgs_added.txt" 2>/dev/null || echo 0)
pkgs_removed_count=$(wc -l < "${DIFF_DIR}/pkgs_removed.txt" 2>/dev/null || echo 0)
pkgs_upgraded_count=$(grep -c "^FROM:" "${DIFF_DIR}/pkgs_upgraded.txt" 2>/dev/null || echo 0)
svc_started_count=$(wc -l < "${DIFF_DIR}/svc_started.txt" 2>/dev/null | tr -d ' ' || echo 0)
svc_stopped_count=$(wc -l < "${DIFF_DIR}/svc_stopped.txt" 2>/dev/null | tr -d ' ' || echo 0)
cs_modified_count=$(wc -l < "${DIFF_DIR}/cs_modified.txt" 2>/dev/null | tr -d ' ' || echo 0)
cs_new_count=$(wc -l < "${DIFF_DIR}/cs_new_files.txt" 2>/dev/null | tr -d ' ' || echo 0)
ports_opened_count=$(wc -l < "${DIFF_DIR}/ports_opened.txt" 2>/dev/null | tr -d ' ' || echo 0)
ports_closed_count=$(wc -l < "${DIFF_DIR}/ports_closed.txt" 2>/dev/null | tr -d ' ' || echo 0)

kernel_changed="no"
[ "${PRE_KERNEL}" != "${POST_KERNEL}" ] && kernel_changed="yes"

# Overall risk: any changed /etc files + new open ports = flag for review
risk_score=0
[ "$kernel_changed" = "yes" ] && risk_score=$((risk_score + 20))
[ "$ports_opened_count" -gt 0 ] 2>/dev/null && risk_score=$((risk_score + ports_opened_count * 10))
[ "$cs_modified_count" -gt 20 ] 2>/dev/null && risk_score=$((risk_score + 15))
[ "$pkgs_added_count" -gt 0 ]   2>/dev/null && risk_score=$((risk_score + 5))

risk_label="LOW"
risk_color="#2ecc71"
[ "$risk_score" -gt 20 ] && { risk_label="MEDIUM"; risk_color="#f39c12"; }
[ "$risk_score" -gt 50 ] && { risk_label="HIGH";   risk_color="#e74c3c"; }

# ---------------------------------------------------------------------------
# Helper — read file, escape HTML
# ---------------------------------------------------------------------------
html_escape_file() {
    cat "$1" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | head -300
}

html_list() {
    local file="$1" limit="${2:-200}"
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        echo "<span class='none'>— none —</span>"
        return
    fi
    echo "<ul class='diff-list'>"
    head -"$limit" "$file" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | while IFS= read -r line; do
        echo "<li>${line}</li>"
    done
    echo "</ul>"
    local total
    total=$(wc -l < "$file")
    [ "$total" -gt "$limit" ] && echo "<div class='more'>... and $((total - limit)) more lines</div>"
}

html_diff_block() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "<pre class='diff-pre'>(diff file not found)</pre>"
        return
    fi
    if grep -q "^BOTH_MISSING\|^PRE_MISSING\|^POST_MISSING" "$file" 2>/dev/null; then
        echo "<pre class='diff-pre'>$(cat "$file")</pre>"
        return
    fi
    if [ ! -s "$file" ]; then
        echo "<div class='no-change'>✔ No differences detected</div>"
        return
    fi
    echo "<pre class='diff-pre'>"
    head -400 "$file" | sed \
        's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | \
        sed 's/^+/<span class="d-add">+/; s/$/<\/span>/' | \
        sed 's/^-/<span class="d-rem">-/; s/$/<\/span>/' | \
        sed 's/^@@/<span class="d-hunk">@@/; s/$/<\/span>/' | \
        sed 's/^---/<span class="d-meta">---/; s/$/<\/span>/' | \
        sed 's/^+++/<span class="d-meta">+++/; s/$/<\/span>/'
    local total
    total=$(wc -l < "$file")
    [ "$total" -gt 400 ] && echo "... (truncated — $((total - 400)) more lines)"
    echo "</pre>"
}

# ---------------------------------------------------------------------------
# Generate HTML
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${YELLOW}▶  Generating HTML Diff Report...${RESET}"

cat > "$HTML_REPORT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Diff Report — ${HOSTNAME_DISPLAY} — $(date '+%Y-%m-%d')</title>
<style>
:root{
  --bg:#06101f;--bg2:#0c1a30;--bg3:#111f3a;--border:#1a2d4f;
  --ok:#27ae60;--warn:#e67e22;--danger:#c0392b;--info:#2980b9;
  --add:#1a3a1a;--add-border:#27ae60;--add-text:#5ddb6e;
  --rem:#3a1a1a;--rem-border:#c0392b;--rem-text:#db5d5d;
  --hunk:#1a2a3a;--hunk-text:#5d9adb;--meta:#2a2a1a;--meta-text:#ddb85d;
  --text:#b0c8e0;--muted:#3a5a7a;--hi:#eaf2ff;
  --mono:'Consolas','Courier New',monospace;--sans:'Trebuchet MS','Segoe UI',Tahoma,sans-serif;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:var(--sans);font-size:14px;min-height:100vh}
::selection{background:#2980b9;color:#fff}

.hdr{background:linear-gradient(135deg,#06101f,#0d1e38,#06101f);
     border-bottom:1px solid var(--border);padding:30px 48px 26px}
.hdr-badge{display:inline-flex;align-items:center;gap:7px;
    background:rgba(41,128,185,.15);border:1px solid #2980b9;
    color:#5db3e8;font-size:11px;font-weight:700;letter-spacing:2px;
    padding:4px 12px;border-radius:4px;margin-bottom:12px}
.hdr h1{font-size:28px;font-weight:800;color:var(--hi)}
.hdr h1 span{color:#5db3e8}
.hdr-sub{color:var(--muted);font-size:12px;margin-top:6px;font-family:var(--mono)}

/* COMPARE BAR */
.cmpbar{display:grid;grid-template-columns:1fr auto 1fr;gap:0;
    background:var(--bg2);border-bottom:1px solid var(--border);padding:20px 48px;align-items:center}
.cmp-side{background:var(--bg3);border:1px solid var(--border);border-radius:8px;padding:14px 18px}
.cmp-label{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1.5px;margin-bottom:6px}
.cmp-host{font-size:15px;font-weight:700;color:var(--hi)}
.cmp-detail{font-family:var(--mono);font-size:11px;color:var(--text);margin-top:4px}
.cmp-time{font-family:var(--mono);font-size:10px;color:var(--muted);margin-top:2px}
.cmp-arrow{text-align:center;font-size:30px;color:var(--muted);padding:0 24px}

/* STAT BAR */
.statbar{background:var(--bg2);border-bottom:2px solid var(--border);padding:0 48px}
.stats{display:flex;flex-wrap:wrap;max-width:100%}
.stat{padding:14px 18px;border-right:1px solid var(--border);flex:1;min-width:100px;text-align:center}
.stat:last-child{border-right:none}
.stat-lbl{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1px;margin-bottom:5px}
.stat-n{font-size:24px;font-weight:800;font-family:var(--mono)}
.stat-n.ok{color:var(--ok)}.stat-n.warn{color:var(--warn)}.stat-n.danger{color:var(--danger)}.stat-n.info{color:var(--info)}
.stat-sub{font-size:10px;color:var(--muted);margin-top:2px}
.risk-pill{display:inline-block;padding:3px 12px;border-radius:20px;font-weight:700;font-size:11px}

/* LAYOUT */
.layout{display:grid;grid-template-columns:210px 1fr;min-height:80vh}
.nav{background:var(--bg2);border-right:1px solid var(--border);padding:16px 0;
     position:sticky;top:0;height:100vh;overflow-y:auto}
.nav::-webkit-scrollbar{width:4px}
.nav::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}
.nav-grp{padding:10px 14px 4px;font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:1.5px;font-weight:700}
.nav a{display:flex;align-items:center;justify-content:space-between;padding:6px 14px;color:var(--muted);
    text-decoration:none;font-size:11.5px;border-left:2px solid transparent;transition:all .15s}
.nav a:hover{color:var(--text);background:var(--bg3);border-left-color:var(--border)}
.nav a.active{color:#5db3e8;background:rgba(41,128,185,.1);border-left-color:#2980b9}
.nav-ic{margin-right:6px}
.nav-badge{font-size:9px;padding:1px 6px;border-radius:10px;font-weight:700;font-family:var(--mono)}
.nb-ok{background:rgba(39,174,96,.2);color:var(--ok)}
.nb-warn{background:rgba(230,126,34,.2);color:var(--warn)}
.nb-danger{background:rgba(192,57,43,.2);color:var(--danger)}
.nb-info{background:rgba(41,128,185,.2);color:var(--info)}

/* CONTENT */
.content{padding:24px 32px;min-width:0}
.section-card{background:var(--bg2);border:1px solid var(--border);border-radius:10px;
    margin-bottom:16px;overflow:hidden;scroll-margin-top:20px}
.sc-hdr{display:flex;align-items:center;justify-content:space-between;
    padding:12px 18px;background:var(--bg3);border-bottom:1px solid var(--border);
    cursor:pointer;user-select:none}
.sc-hdr:hover{background:rgba(26,45,79,.7)}
.sc-left{display:flex;align-items:center;gap:10px}
.sc-ic{width:28px;height:28px;border-radius:6px;display:flex;align-items:center;justify-content:center;
    font-size:13px;background:rgba(41,128,185,.1);border:1px solid rgba(41,128,185,.25)}
.sc-title{font-size:13px;font-weight:700;color:var(--hi)}
.sc-sub{font-family:var(--mono);font-size:10px;color:var(--muted)}
.sc-right{display:flex;align-items:center;gap:8px}
.sc-toggle{color:var(--muted);font-size:14px;transition:transform .2s}
.sc-toggle.open{transform:rotate(180deg)}
.sc-body{display:none;padding:16px 18px}
.sc-body.open{display:block}

/* DIFF CONTENT */
.diff-pre{font-family:var(--mono);font-size:11.5px;line-height:1.7;
    white-space:pre-wrap;word-break:break-word;
    background:var(--bg);border:1px solid var(--border);border-radius:6px;
    padding:12px 16px;max-height:480px;overflow-y:auto}
.diff-pre::-webkit-scrollbar{width:5px}
.diff-pre::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
span.d-add{display:block;background:var(--add);color:var(--add-text);
    border-left:3px solid var(--add-border);padding-left:6px;margin:-0px -16px;padding-right:8px}
span.d-rem{display:block;background:var(--rem);color:var(--rem-text);
    border-left:3px solid var(--rem-border);padding-left:6px;margin:-0px -16px;padding-right:8px}
span.d-hunk{display:block;background:var(--hunk);color:var(--hunk-text);font-style:italic}
span.d-meta{display:block;background:var(--meta);color:var(--meta-text)}
.no-change{display:flex;align-items:center;gap:8px;padding:14px;
    background:rgba(39,174,96,.08);border:1px solid rgba(39,174,96,.2);
    border-radius:6px;color:var(--ok);font-size:13px}
.diff-list{list-style:none;padding:0;font-family:var(--mono);font-size:11.5px}
.diff-list li{padding:4px 10px;border-bottom:1px solid var(--border);color:var(--text)}
.diff-list li:last-child{border:none}
.none{color:var(--muted);font-style:italic;font-size:12px;padding:8px}
.more{color:var(--muted);font-size:11px;padding:6px 10px;font-style:italic}

/* SUMMARY TABLES */
.sum-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
.sum-box{background:var(--bg);border:1px solid var(--border);border-radius:7px;padding:12px}
.sum-title{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:1px;margin-bottom:8px}
.sum-title.add{color:var(--ok)}.sum-title.rem{color:var(--danger)}
.sum-title.chg{color:var(--warn)}.sum-title.info{color:var(--info)}

/* KERNEL DIFF */
.kernel-diff{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
.kd-box{background:var(--bg);border-radius:7px;padding:14px;text-align:center}
.kd-lbl{font-size:10px;color:var(--muted);text-transform:uppercase;margin-bottom:6px}
.kd-val{font-family:var(--mono);font-size:14px;font-weight:700}
.kd-val.changed{color:var(--warn)}
.kd-val.same{color:var(--ok)}
.kd-box.pre{border:1px solid var(--rem-border)}
.kd-box.post{border:1px solid var(--add-border)}

.footer{border-top:1px solid var(--border);padding:18px 48px;
    display:flex;justify-content:space-between;
    font-family:var(--mono);font-size:11px;color:var(--muted)}
@media(max-width:900px){.layout{grid-template-columns:1fr}.nav{position:static;height:auto}.cmpbar,.hdr,.statbar{padding:16px}.sum-grid,.kernel-diff{grid-template-columns:1fr}.cmpbar{grid-template-columns:1fr}}
</style>
</head>
<body>

<!-- HEADER -->
<div class="hdr">
  <div class="hdr-badge">▲ DIFF REPORT</div>
  <h1>${HOSTNAME_DISPLAY}<span>.</span></h1>
  <div class="hdr-sub">Pre vs Post Reboot Comparison &nbsp;·&nbsp; Generated $(date '+%Y-%m-%d %H:%M:%S') &nbsp;·&nbsp; Risk: <strong style="color:${risk_color}">${risk_label}</strong></div>
</div>

<!-- COMPARE BAR -->
<div class="cmpbar">
  <div class="cmp-side">
    <div class="cmp-label">🔵 PRE-REBOOT</div>
    <div class="cmp-host">${PRE_HOST:-unknown}</div>
    <div class="cmp-detail">Kernel: ${PRE_KERNEL:-?} &nbsp;·&nbsp; Pkgs: ${PRE_PKGS:-?}</div>
    <div class="cmp-time">${PRE_TIME:-?}</div>
  </div>
  <div class="cmp-arrow">→</div>
  <div class="cmp-side">
    <div class="cmp-label">🟡 POST-REBOOT</div>
    <div class="cmp-host">${POST_HOST:-unknown}</div>
    <div class="cmp-detail">Kernel: ${POST_KERNEL:-?} &nbsp;·&nbsp; Pkgs: ${POST_PKGS:-?}</div>
    <div class="cmp-time">${POST_TIME:-?}</div>
  </div>
</div>

<!-- STAT BAR -->
<div class="statbar">
  <div class="stats">
    <div class="stat">
      <div class="stat-lbl">Risk Level</div>
      <div class="stat-n" style="color:${risk_color};font-size:18px">${risk_label}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Kernel Changed</div>
      <div class="stat-n $([ "$kernel_changed" = "yes" ] && echo warn || echo ok)">$([ "$kernel_changed" = "yes" ] && echo "YES" || echo "NO")</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Pkgs Added</div>
      <div class="stat-n $([ "$pkgs_added_count" -gt 0 ] 2>/dev/null && echo info || echo ok)">${pkgs_added_count}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Pkgs Removed</div>
      <div class="stat-n $([ "$pkgs_removed_count" -gt 0 ] 2>/dev/null && echo warn || echo ok)">${pkgs_removed_count}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Upgraded</div>
      <div class="stat-n info">${pkgs_upgraded_count}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Svcs Started</div>
      <div class="stat-n ok">${svc_started_count}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Svcs Stopped</div>
      <div class="stat-n $([ "$svc_stopped_count" -gt 0 ] 2>/dev/null && echo warn || echo ok)">${svc_stopped_count}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">/etc Changed</div>
      <div class="stat-n $([ "$cs_modified_count" -gt 0 ] 2>/dev/null && echo warn || echo ok)">${cs_modified_count}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">New /etc Files</div>
      <div class="stat-n $([ "$cs_new_count" -gt 0 ] 2>/dev/null && echo info || echo ok)">${cs_new_count}</div>
    </div>
    <div class="stat">
      <div class="stat-lbl">Ports Opened</div>
      <div class="stat-n $([ "$ports_opened_count" -gt 0 ] 2>/dev/null && echo danger || echo ok)">${ports_opened_count}</div>
    </div>
  </div>
</div>

<!-- LAYOUT -->
<div class="layout">
  <nav class="nav">
    <div class="nav-grp">Summary</div>
    <a class="active" href="#d-summary" onclick="act(this)"><span class="nav-ic">📊</span>Executive Summary</a>
    <div class="nav-grp">Key Changes</div>
    <a href="#d-kernel"   onclick="act(this)"><span class="nav-ic">⚙</span>Kernel
      $([ "$kernel_changed" = "yes" ] && echo '<span class="nav-badge nb-warn">CHANGED</span>')</a>
    <a href="#d-packages" onclick="act(this)"><span class="nav-ic">📦</span>Packages
      $([ "$((pkgs_added_count + pkgs_removed_count))" -gt 0 ] 2>/dev/null && echo "<span class='nav-badge nb-info'>$((pkgs_added_count + pkgs_removed_count))</span>")</a>
    <a href="#d-services" onclick="act(this)"><span class="nav-ic">⚡</span>Services
      $([ "$svc_stopped_count" -gt 0 ] 2>/dev/null && echo "<span class='nav-badge nb-warn'>${svc_stopped_count}</span>")</a>
    <a href="#d-ports"    onclick="act(this)"><span class="nav-ic">🔌</span>Ports
      $([ "$ports_opened_count" -gt 0 ] 2>/dev/null && echo "<span class='nav-badge nb-danger'>${ports_opened_count}</span>")</a>
    <a href="#d-etc"      onclick="act(this)"><span class="nav-ic">🔐</span>/etc Files
      $([ "$cs_modified_count" -gt 0 ] 2>/dev/null && echo "<span class='nav-badge nb-warn'>${cs_modified_count}</span>")</a>
    <div class="nav-grp">Full Diffs</div>
    <a href="#d-01" onclick="act(this)"><span class="nav-ic">🖥</span>OS Info</a>
    <a href="#d-02" onclick="act(this)"><span class="nav-ic">⚙</span>Kernel</a>
    <a href="#d-04" onclick="act(this)"><span class="nav-ic">💾</span>Memory</a>
    <a href="#d-06" onclick="act(this)"><span class="nav-ic">🗄</span>Disk</a>
    <a href="#d-07" onclick="act(this)"><span class="nav-ic">🌐</span>Network</a>
    <a href="#d-08" onclick="act(this)"><span class="nav-ic">🕒</span>NTP</a>
    <a href="#d-09" onclick="act(this)"><span class="nav-ic">🔌</span>Ports</a>
    <a href="#d-10" onclick="act(this)"><span class="nav-ic">🛡</span>Firewall</a>
    <a href="#d-13" onclick="act(this)"><span class="nav-ic">🔒</span>Security/PAM</a>
    <a href="#d-14" onclick="act(this)"><span class="nav-ic">🕐</span>Cron</a>
    <a href="#d-15" onclick="act(this)"><span class="nav-ic">👤</span>Users</a>
    <a href="#d-17" onclick="act(this)"><span class="nav-ic">🔄</span>Processes</a>
    <a href="#d-18" onclick="act(this)"><span class="nav-ic">📋</span>Logs</a>
  </nav>

  <div class="content">

    <!-- EXECUTIVE SUMMARY -->
    <div class="section-card" id="d-summary">
      <div class="sc-hdr" onclick="tog(this)">
        <div class="sc-left"><div class="sc-ic">📊</div>
          <div><div class="sc-title">Executive Summary</div>
               <div class="sc-sub">High-level changes — Review before signing off</div></div></div>
        <div class="sc-right">
          <span class="risk-pill" style="background:$(echo ${risk_color}22);color:${risk_color};border:1px solid ${risk_color}44">${risk_label} RISK</span>
          <span class="sc-toggle open">▼</span></div></div>
      <div class="sc-body open">
        <div class="sum-grid">
          <div class="sum-box">
            <div class="sum-title info">Kernel</div>
            <div class="diff-list">$([ "$kernel_changed" = "yes" ] && echo "<li>⚠ Kernel changed: <strong>${PRE_KERNEL}</strong> → <strong>${POST_KERNEL}</strong></li>" || echo "<li>✔ Kernel unchanged: ${POST_KERNEL}</li>")</div>
          </div>
          <div class="sum-box">
            <div class="sum-title chg">Packages</div>
            <div class="diff-list">
              <li>Added: <strong>${pkgs_added_count}</strong></li>
              <li>Removed: <strong>${pkgs_removed_count}</strong></li>
              <li>Upgraded: <strong>${pkgs_upgraded_count}</strong></li>
            </div>
          </div>
          <div class="sum-box">
            <div class="sum-title add">Services</div>
            <div class="diff-list">
              <li>Newly running: <strong>${svc_started_count}</strong></li>
              <li>No longer running: <strong>${svc_stopped_count}</strong></li>
            </div>
          </div>
          <div class="sum-box">
            <div class="sum-title $([ "$ports_opened_count" -gt 0 ] 2>/dev/null && echo rem || echo add)">Ports &amp; /etc</div>
            <div class="diff-list">
              <li>New listening ports: <strong>${ports_opened_count}</strong></li>
              <li>Closed ports: <strong>${ports_closed_count}</strong></li>
              <li>/etc files modified: <strong>${cs_modified_count}</strong></li>
              <li>New /etc files: <strong>${cs_new_count}</strong></li>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- KERNEL DETAIL -->
    <div class="section-card" id="d-kernel">
      <div class="sc-hdr" onclick="tog(this)">
        <div class="sc-left"><div class="sc-ic">⚙</div>
          <div><div class="sc-title">Kernel Change</div>
               <div class="sc-sub">Running kernel before and after</div></div></div>
        <div class="sc-right"><span class="sc-toggle">▼</span></div></div>
      <div class="sc-body">
        <div class="kernel-diff">
          <div class="kd-box pre"><div class="kd-lbl">PRE-REBOOT</div>
            <div class="kd-val $([ "$kernel_changed" = "yes" ] && echo changed || echo same)">${PRE_KERNEL:-unknown}</div></div>
          <div class="kd-box post"><div class="kd-lbl">POST-REBOOT</div>
            <div class="kd-val $([ "$kernel_changed" = "yes" ] && echo changed || echo same)">${POST_KERNEL:-unknown}</div></div>
        </div>
        $(html_diff_block "${DIFF_DIR}/diff_02_kernel.txt")
      </div>
    </div>

    <!-- PACKAGES -->
    <div class="section-card" id="d-packages">
      <div class="sc-hdr" onclick="tog(this)">
        <div class="sc-left"><div class="sc-ic">📦</div>
          <div><div class="sc-title">Package Changes</div>
               <div class="sc-sub">${pkgs_added_count} added · ${pkgs_removed_count} removed · ${pkgs_upgraded_count} upgraded</div></div></div>
        <div class="sc-right"><span class="sc-toggle">▼</span></div></div>
      <div class="sc-body">
        <div class="sum-grid">
          <div class="sum-box"><div class="sum-title add">Added (${pkgs_added_count})</div>
            $(html_list "${DIFF_DIR}/pkgs_added.txt" 100)</div>
          <div class="sum-box"><div class="sum-title rem">Removed (${pkgs_removed_count})</div>
            $(html_list "${DIFF_DIR}/pkgs_removed.txt" 100)</div>
        </div>
        <div class="sum-box" style="margin-top:12px">
          <div class="sum-title chg">Upgraded / Version Changed (${pkgs_upgraded_count})</div>
          $(html_list "${DIFF_DIR}/pkgs_upgraded.txt" 100)
        </div>
      </div>
    </div>

    <!-- SERVICES -->
    <div class="section-card" id="d-services">
      <div class="sc-hdr" onclick="tog(this)">
        <div class="sc-left"><div class="sc-ic">⚡</div>
          <div><div class="sc-title">Service Changes</div>
               <div class="sc-sub">${svc_started_count} started · ${svc_stopped_count} stopped</div></div></div>
        <div class="sc-right"><span class="sc-toggle">▼</span></div></div>
      <div class="sc-body">
        <div class="sum-grid">
          <div class="sum-box"><div class="sum-title add">Newly Running (${svc_started_count})</div>
            $(html_list "${DIFF_DIR}/svc_started.txt")</div>
          <div class="sum-box"><div class="sum-title rem">No Longer Running (${svc_stopped_count})</div>
            $(html_list "${DIFF_DIR}/svc_stopped.txt")</div>
        </div>
        <div class="sum-grid" style="margin-top:12px">
          <div class="sum-box"><div class="sum-title add">Newly Enabled</div>
            $(html_list "${DIFF_DIR}/svc_newly_enabled.txt")</div>
          <div class="sum-box"><div class="sum-title rem">Newly Disabled</div>
            $(html_list "${DIFF_DIR}/svc_disabled.txt")</div>
        </div>
        $(html_diff_block "${DIFF_DIR}/diff_12_services.txt")
      </div>
    </div>

    <!-- PORTS -->
    <div class="section-card" id="d-ports">
      <div class="sc-hdr" onclick="tog(this)">
        <div class="sc-left"><div class="sc-ic">🔌</div>
          <div><div class="sc-title">Port Changes</div>
               <div class="sc-sub">${ports_opened_count} new · ${ports_closed_count} closed</div></div></div>
        <div class="sc-right"><span class="sc-toggle">▼</span></div></div>
      <div class="sc-body">
        <div class="sum-grid">
          <div class="sum-box"><div class="sum-title rem">New Listening Ports ⚠</div>
            $(html_list "${DIFF_DIR}/ports_opened.txt")</div>
          <div class="sum-box"><div class="sum-title chg">Closed Ports</div>
            $(html_list "${DIFF_DIR}/ports_closed.txt")</div>
        </div>
        $(html_diff_block "${DIFF_DIR}/diff_09_ports.txt")
      </div>
    </div>

    <!-- /ETC CHECKSUMS -->
    <div class="section-card" id="d-etc">
      <div class="sc-hdr" onclick="tog(this)">
        <div class="sc-left"><div class="sc-ic">🔐</div>
          <div><div class="sc-title">/etc Configuration Changes</div>
               <div class="sc-sub">${cs_modified_count} modified · ${cs_new_count} new files</div></div></div>
        <div class="sc-right"><span class="sc-toggle">▼</span></div></div>
      <div class="sc-body">
        <div class="sum-grid">
          <div class="sum-box"><div class="sum-title chg">Modified Files (${cs_modified_count})</div>
            $(html_list "${DIFF_DIR}/cs_modified.txt" 150)</div>
          <div class="sum-box"><div class="sum-title add">New Files (${cs_new_count})</div>
            $(html_list "${DIFF_DIR}/cs_new_files.txt" 80)</div>
        </div>
        <div class="sum-box" style="margin-top:12px"><div class="sum-title rem">Removed Files</div>
          $(html_list "${DIFF_DIR}/cs_removed_files.txt" 80)</div>
      </div>
    </div>

    <!-- FULL DIFFS (collapsible) -->
    <div class="section-card" id="d-01"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🖥</div><div><div class="sc-title">OS & System Info — Full Diff</div><div class="sc-sub">01_os_info.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_01_os_info.txt")</div></div>

    <div class="section-card" id="d-02"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">⚙</div><div><div class="sc-title">Kernel — Full Diff</div><div class="sc-sub">02_kernel.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_02_kernel.txt")</div></div>

    <div class="section-card" id="d-04"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">💾</div><div><div class="sc-title">Memory — Full Diff</div><div class="sc-sub">04_memory.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_04_memory.txt")</div></div>

    <div class="section-card" id="d-06"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🗄</div><div><div class="sc-title">Disk & Storage — Full Diff</div><div class="sc-sub">06_disk.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_06_disk.txt")</div></div>

    <div class="section-card" id="d-07"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🌐</div><div><div class="sc-title">Network — Full Diff</div><div class="sc-sub">07_network.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_07_network.txt")</div></div>

    <div class="section-card" id="d-08"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🕒</div><div><div class="sc-title">NTP / Time — Full Diff</div><div class="sc-sub">08_ntp.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_08_ntp.txt")</div></div>

    <div class="section-card" id="d-09"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🔌</div><div><div class="sc-title">Ports — Full Diff</div><div class="sc-sub">09_ports.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_09_ports.txt")</div></div>

    <div class="section-card" id="d-10"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🛡</div><div><div class="sc-title">Firewall — Full Diff</div><div class="sc-sub">10_firewall.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_10_firewall.txt")</div></div>

    <div class="section-card" id="d-13"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🔒</div><div><div class="sc-title">Security Policy / PAM — Full Diff</div><div class="sc-sub">13_security_policy.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_13_security_policy.txt")</div></div>

    <div class="section-card" id="d-14"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🕐</div><div><div class="sc-title">Cron Jobs — Full Diff</div><div class="sc-sub">14_cron.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_14_cron.txt")</div></div>

    <div class="section-card" id="d-15"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">👤</div><div><div class="sc-title">Users &amp; Access — Full Diff</div><div class="sc-sub">15_users.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_15_users.txt")</div></div>

    <div class="section-card" id="d-17"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">🔄</div><div><div class="sc-title">Process Snapshot — Full Diff</div><div class="sc-sub">17_processes.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_17_processes.txt")</div></div>

    <div class="section-card" id="d-18"><div class="sc-hdr" onclick="tog(this)"><div class="sc-left"><div class="sc-ic">📋</div><div><div class="sc-title">Log Baseline — Full Diff</div><div class="sc-sub">18_logs.txt</div></div></div><div class="sc-right"><span class="sc-toggle">▼</span></div></div><div class="sc-body">$(html_diff_block "${DIFF_DIR}/diff_18_logs.txt")</div></div>

  </div><!-- /content -->
</div><!-- /layout -->

<div class="footer">
  <span>Diff Report v2.0 &nbsp;·&nbsp; ${HOSTNAME_DISPLAY} &nbsp;·&nbsp; $(date '+%Y-%m-%d %H:%M:%S')</span>
  <span>${DIFF_DIR}</span>
</div>

<script>
function tog(h){var b=h.nextElementSibling,t=h.querySelector('.sc-toggle');b.classList.toggle('open');t.classList.toggle('open');}
function act(a){
  document.querySelectorAll('.nav a').forEach(function(x){x.classList.remove('active')});
  a.classList.add('active');
  var id=a.getAttribute('href');var el=document.querySelector(id);
  if(el){el.scrollIntoView({behavior:'smooth',block:'start'});
    var b=el.querySelector('.sc-body'),t=el.querySelector('.sc-toggle');
    if(b&&!b.classList.contains('open')){b.classList.add('open');if(t)t.classList.add('open');}
  }return false;
}
</script>
</body></html>
HTMLEOF

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "  ${GREEN}[✔]${RESET} HTML Diff Report generated"
echo ""
echo -e "  ${DIM}──────────────────────────────────────────────────────────────────${RESET}"
echo ""
echo -e "  ${BOLD}${CYAN}✔  DIFF REPORT COMPLETE${RESET}"
echo ""
echo -e "  ${WHITE}HTML Report   :${RESET} ${CYAN}${HTML_REPORT}${RESET}"
echo -e "  ${WHITE}Diff Data Dir :${RESET} ${DIM}${DIFF_DIR}${RESET}"
echo -e "  ${WHITE}Duration      :${RESET} ${CYAN}${DURATION} second(s)${RESET}"
echo ""
echo -e "  ${BOLD}Summary:${RESET}"
echo -e "  Kernel Changed   : $([ "$kernel_changed" = "yes" ] && echo -e "${YELLOW}YES (${PRE_KERNEL} → ${POST_KERNEL})${RESET}" || echo -e "${GREEN}No${RESET}")"
echo -e "  Pkgs Added       : ${pkgs_added_count}"
echo -e "  Pkgs Removed     : ${pkgs_removed_count}"
echo -e "  Pkgs Upgraded    : ${pkgs_upgraded_count}"
echo -e "  Services Started : ${svc_started_count}"
echo -e "  Services Stopped : $([ "$svc_stopped_count" -gt 0 ] 2>/dev/null && echo -e "${YELLOW}${svc_stopped_count}${RESET}" || echo "${svc_stopped_count}")"
echo -e "  Ports Opened     : $([ "$ports_opened_count" -gt 0 ] 2>/dev/null && echo -e "${RED}${ports_opened_count}${RESET}" || echo "${ports_opened_count}")"
echo -e "  /etc Modified    : $([ "$cs_modified_count" -gt 0 ] 2>/dev/null && echo -e "${YELLOW}${cs_modified_count}${RESET}" || echo "${cs_modified_count}")"
echo -e "  Risk Level       : $(printf "${risk_color}") ${risk_label}${RESET:+${RESET}}"
echo ""
