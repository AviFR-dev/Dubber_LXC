#!/bin/bash
#================================================================
#  Plex AI Dubber — Proxmox LXC Installer
#  Author: Avi Fridlindas | License: MIT
#
#  Creates a dedicated LXC for AI movie dubbing with voice cloning.
#  Auto-detects GPU, storage, templates, and media mounts.
#
#  Usage:  bash setup_dubber_lxc.sh
#================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

CTID=""
CT_NAME="dubber"
CT_STORAGE=""
CT_DISK_SIZE="50"
CT_RAM="8192"
CT_SWAP="4096"
CT_CORES="4"
CT_TEMPLATE=""
SKIP_GPU=false
NVIDIA_LIB_DIR="/opt/nvidia-libs"
MEDIA_MOUNTS=()

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}[$1]${NC} $2"; }

ask() {
    local prompt="$1" default="$2" var_name="$3" input=""
    if [ -n "$default" ]; then
        read -rp "  $prompt [$default]: " input || true
        eval "$var_name=\"${input:-$default}\""
    else
        read -rp "  $prompt: " input || true
        eval "$var_name=\"${input:-}\""
    fi
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" input=""
    read -rp "  $prompt [${default}]: " input || true
    [[ "${input:-$default}" =~ ^[Yy] ]]
}

# ─── Pre-flight ───
check_proxmox() {
    log_step "0" "Pre-flight checks"
    if ! command -v pct &>/dev/null; then log_error "Must run on Proxmox host."; exit 1; fi
    if [ "$(id -u)" -ne 0 ]; then log_error "Must run as root."; exit 1; fi
    log_ok "Proxmox detected: $(pveversion 2>/dev/null | head -1)"
}

# ─── GPU ───
detect_gpu() {
    log_step "1" "Detecting NVIDIA GPU"
    local gpu_info=$(lspci | grep -i "nvidia" | grep -iE "vga|3d|display" | head -1 || true)
    if [ -z "$gpu_info" ]; then
        log_warn "No NVIDIA GPU found."
        SKIP_GPU=true; return
    fi
    log_ok "GPU: $(echo "$gpu_info" | sed 's/.*: //')"
    if ! command -v nvidia-smi &>/dev/null; then
        log_error "nvidia-smi not found. Install NVIDIA drivers first."; exit 1
    fi
    local drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    local vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    log_ok "Driver: $drv | VRAM: ${vram}MB"
}

collect_nvidia_libs() {
    [ "$SKIP_GPU" = true ] && return
    log_step "2" "Collecting NVIDIA libraries"
    mkdir -p "$NVIDIA_LIB_DIR"
    while IFS= read -r lib; do
        [ -f "$lib" ] && cp -n "$lib" "$NVIDIA_LIB_DIR/" 2>/dev/null || true
    done < <(ldconfig -p 2>/dev/null | grep -i nvidia | awk '{print $NF}' | sort -u)
    for dir in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
        for lib in "$dir"/libnvidia*.so* "$dir"/libcuda*.so* "$dir"/libnvcuvid*.so*; do
            [ -f "$lib" ] && cp -n "$lib" "$NVIDIA_LIB_DIR/" 2>/dev/null || true
        done
    done
    for bin in nvidia-smi nvidia-debugdump; do
        local p=$(which "$bin" 2>/dev/null || true)
        [ -n "$p" ] && [ -f "$p" ] && cp -n "$p" "$NVIDIA_LIB_DIR/" 2>/dev/null || true
    done
    local cnt=$(find "$NVIDIA_LIB_DIR" -name "*.so*" 2>/dev/null | wc -l)
    log_ok "Collected $cnt libraries in $NVIDIA_LIB_DIR"
}

# ─── Resources ───
detect_resources() {
    log_step "3" "Detecting resources"
    local cores=$(nproc); CT_CORES=$(( cores / 2 ))
    [ "$CT_CORES" -lt 2 ] && CT_CORES=2; [ "$CT_CORES" -gt 8 ] && CT_CORES=8
    log_ok "CPU: $cores cores (assigning $CT_CORES)"
    local avail_mb=$(free -m | awk '/^Mem:/{print $7}')
    CT_RAM=8192; [ "$avail_mb" -lt 8192 ] && CT_RAM=$(( avail_mb - 1024 ))
    [ "$CT_RAM" -lt 4096 ] && CT_RAM=4096
    log_ok "RAM: ${avail_mb}MB available (assigning ${CT_RAM}MB)"
    echo ""; pvesm status 2>/dev/null; echo ""
}

# ─── Template ───
find_template() {
    log_step "4" "Finding template"
    # Check existing
    while IFS= read -r storage; do
        local ct=$(pvesm get "$storage" 2>/dev/null | grep "^content" | awk '{print $2}' || true)
        echo "$ct" | grep -q "vztmpl" || continue
        local found=$(pveam list "$storage" 2>/dev/null | grep -i "debian-12" | head -1 | awk '{print $1}' || true)
        if [ -n "$found" ]; then CT_TEMPLATE="$found"; log_ok "Found: $CT_TEMPLATE"; return; fi
    done < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}')
    # Download
    log_info "Downloading Debian 12 template..."
    local dl="local" tpl=""
    tpl=$(pveam available --section system 2>/dev/null | grep -i "debian-12" | sort -V | tail -1 | awk '{print $2}' || true)
    [ -z "$tpl" ] && tpl=$(pveam available 2>/dev/null | grep -i "debian-12" | sort -V | tail -1 | awk '{print $2}' || true)
    [ -z "$tpl" ] && { log_error "No Debian 12 template found."; exit 1; }
    if ! pveam download "$dl" "$tpl"; then log_error "Download failed."; exit 1; fi
    CT_TEMPLATE="${dl}:vztmpl/${tpl}"
    log_ok "Template: $CT_TEMPLATE"
}

# ─── Find CTID ───
find_ctid() {
    local id=200
    while pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; do ((id++)); done
    echo "$id"
}

# ─── Media mount detection ───
detect_media_mounts() {
    local -a found_mounts=() found_display=() seen=()
    log_info "Scanning LXC configs for media mounts..."
    while IFS= read -r conf; do
        local vmid=$(basename "$conf" .conf)
        local name=$(grep "^hostname:" "$conf" 2>/dev/null | awk '{print $2}' || echo "LXC-$vmid")
        while IFS= read -r line; do
            local val=$(echo "$line" | sed 's/^mp[0-9]*: //')
            local mp=$(echo "$val" | grep -o 'mp=[^,]*' | sed 's/mp=//')
            local src=$(echo "$val" | cut -d',' -f1)
            [ -n "$src" ] && [ -n "$mp" ] || continue
            local key="${src}|${mp}" already=false
            for s in "${seen[@]:-}"; do [ "$s" = "$key" ] && already=true; done
            [ "$already" = true ] && continue
            seen+=("$key")
            found_mounts+=("${src}|${mp}|LXC $vmid ($name)")
            found_display+=("${src} → ${mp}  (from LXC $vmid: $name)")
        done < <(grep "^mp[0-9]*:" "$conf" 2>/dev/null || true)
    done < <(find /etc/pve/lxc/ -name "*.conf" 2>/dev/null)

    log_info "Scanning host mounts..."
    while IFS= read -r line; do
        local mnt=$(echo "$line" | awk '{print $3}')
        [ -n "$mnt" ] || continue
        local key="${mnt}|${mnt}" already=false
        for s in "${seen[@]:-}"; do [ "$s" = "$key" ] && already=true; done
        [ "$already" = true ] && continue
        seen+=("$key")
        local nfssrc=$(echo "$line" | awk '{print $1}')
        found_mounts+=("${mnt}|${mnt}|host (${nfssrc})")
        found_display+=("${mnt}  (host: ${nfssrc})")
    done < <(mount 2>/dev/null | grep -E "type nfs|type cifs" || true)

    [ ${#found_mounts[@]} -eq 0 ] && { log_warn "No mounts found."; return; }
    echo ""; log_ok "Found ${#found_mounts[@]} mount(s):"
    for i in "${!found_display[@]}"; do echo -e "    ${BOLD}[$((i+1))]${NC} ${found_display[$i]}"; done
    echo -e "    ${BOLD}[A]${NC} Select all"; echo -e "    ${BOLD}[S]${NC} Skip"; echo ""
    local sel=""; ask "Select (e.g. 1,2 or A)" "A" "sel"
    [[ "$sel" =~ ^[Ss]$ ]] && return
    local indices=()
    if [[ "$sel" =~ ^[Aa]$ ]]; then
        for i in "${!found_mounts[@]}"; do indices+=("$i"); done
    else
        IFS=',' read -ra parts <<< "$sel"
        for p in "${parts[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le ${#found_mounts[@]} ] && indices+=("$((p-1))")
        done
    fi
    local midx=0
    for idx in "${indices[@]}"; do
        local src=$(echo "${found_mounts[$idx]}" | cut -d'|' -f1)
        local mp=$(echo "${found_mounts[$idx]}" | cut -d'|' -f2)
        local newmp="$mp"; read -rp "  Mount point for $src [$mp]: " input || true
        newmp="${input:-$mp}"
        MEDIA_MOUNTS+=("mp${midx}: ${src},mp=${newmp}")
        log_ok "Added: $src → $newmp"; ((midx++))
    done
}

# ─── Configure ───
configure() {
    log_step "5" "Configuration"
    local suggested=$(find_ctid); ask "LXC ID" "$suggested" "CTID"
    if pct status "$CTID" &>/dev/null 2>&1; then log_error "ID $CTID in use."; exit 1; fi
    ask "Container name" "$CT_NAME" "CT_NAME"
    local default_storage=$(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active"{avail=$5/1024/1024; if(avail>60){print $1; exit}}')
    [ -z "$default_storage" ] && default_storage="local-lvm"
    ask "Storage" "$default_storage" "CT_STORAGE"
    ask "Disk size GB" "$CT_DISK_SIZE" "CT_DISK_SIZE"
    ask "RAM MB" "$CT_RAM" "CT_RAM"
    ask "CPU cores" "$CT_CORES" "CT_CORES"
    echo ""; log_info "Media mounts:"; detect_media_mounts
    echo -e "\n${BOLD}  Summary:${NC} LXC $CTID ($CT_NAME) | ${CT_DISK_SIZE}GB | ${CT_RAM}MB RAM | $CT_CORES cores"
    for m in "${MEDIA_MOUNTS[@]:-}"; do [ -n "$m" ] && echo "    Mount: $m"; done
    echo ""; ask_yes_no "Proceed? [Y/n]" "y" || exit 0
}

# ─── Create ───
create_lxc() {
    log_step "6" "Creating LXC $CTID"
    if ! pct create "$CTID" "$CT_TEMPLATE" --hostname "$CT_NAME" --storage "$CT_STORAGE" \
        --rootfs "${CT_STORAGE}:${CT_DISK_SIZE}" --memory "$CT_RAM" --swap "$CT_SWAP" \
        --cores "$CT_CORES" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
        --unprivileged 0 --features nesting=1 --onboot 0 --start 0; then
        log_error "Failed to create LXC."; exit 1
    fi
    log_ok "LXC $CTID created."
}

configure_lxc() {
    log_step "7" "Configuring LXC"
    local conf="/etc/pve/lxc/${CTID}.conf"
    if [ "$SKIP_GPU" = false ]; then
        local dev_idx=0
        for dev in /dev/nvidia0 /dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm \
                   /dev/nvidia-uvm-tools /dev/nvidia-caps/nvidia-cap1 /dev/nvidia-caps/nvidia-cap2 /dev/nvidia-modeset; do
            if [ -e "$dev" ]; then
                sed -i "/^swap:/a dev${dev_idx}: ${dev},gid=44" "$conf"; ((dev_idx++))
            fi
        done
        cat >> "$conf" << EOF
lxc.mount.entry: ${NVIDIA_LIB_DIR} opt/nvidia-libs none bind,ro,create=dir
EOF
        log_ok "GPU passthrough ($dev_idx devices)"
    fi
    if [ ${#MEDIA_MOUNTS[@]} -gt 0 ]; then
        for m in "${MEDIA_MOUNTS[@]}"; do sed -i "/^net0:/i ${m}" "$conf"; done
        log_ok "Media mounts (${#MEDIA_MOUNTS[@]})"
    fi
}

start_lxc() {
    log_step "8" "Starting LXC"
    if ! pct start "$CTID"; then
        log_error "Start failed. Check: pct config $CTID"; exit 1
    fi
    local r=0; while ! pct exec "$CTID" -- echo "ready" &>/dev/null; do
        sleep 2; ((r++)); [ "$r" -gt 15 ] && { log_error "LXC not responding."; exit 1; }
    done
    log_ok "Running."
}

install_software() {
    log_step "9" "Installing software (10-20 min)"

    log_info "System packages..."
    pct exec "$CTID" -- bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get upgrade -y -qq
        apt-get install -y -qq python3-pip python3-venv python3-dev ffmpeg espeak-ng mkvtoolnix curl wget nfs-common build-essential 2>&1 | tail -3
    '

    if [ "$SKIP_GPU" = false ]; then
        log_info "GPU setup..."
        pct exec "$CTID" -- bash -c '
            echo "/opt/nvidia-libs" > /etc/ld.so.conf.d/nvidia.conf; ldconfig 2>/dev/null || true
            [ -f /opt/nvidia-libs/nvidia-smi ] && cp /opt/nvidia-libs/nvidia-smi /usr/bin/nvidia-smi && chmod +x /usr/bin/nvidia-smi
            nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "nvidia-smi not working (normal in some LXCs)"
        '
    fi

    log_info "Python environment..."
    pct exec "$CTID" -- bash -c '
        python3 -m venv /opt/dubber
        source /opt/dubber/bin/activate
        pip install --quiet --upgrade pip setuptools wheel 2>&1 | tail -1
    '

    log_info "PyTorch (large download)..."
    pct exec "$CTID" -- bash -c '
        source /opt/dubber/bin/activate
        pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 2>&1 | tail -3
    '

    log_info "Open Dubbing + dependencies..."
    pct exec "$CTID" -- bash -c '
        source /opt/dubber/bin/activate
        pip install --quiet open_dubbing plexapi matplotlib TTS nvidia-cudnn-cu12 2>&1 | tail -3
    '

    log_info "Testing..."
    pct exec "$CTID" -- bash -c '
        source /opt/dubber/bin/activate
        python3 -c "
import torch
print(f\"PyTorch: {torch.__version__}\")
print(f\"CUDA: {torch.cuda.is_available()}\" + (f\" — {torch.cuda.get_device_name(0)}\" if torch.cuda.is_available() else \"\"))
"
    '

    log_info "Setting up commands..."
    pct exec "$CTID" -- bash -c '
        mkdir -p /opt/dubber/output /opt/dubber/scripts
        cat > /usr/bin/dubber << "SHORTCUT"
#!/bin/bash
source /opt/dubber/bin/activate
export COQUI_TOS_AGREED=1
export LD_LIBRARY_PATH=/opt/nvidia-libs:${LD_LIBRARY_PATH:-}
python /opt/dubber/scripts/plex_ai_dubber.py "$@"
SHORTCUT
        chmod +x /usr/bin/dubber
        cat >> /root/.bashrc << "BASHRC"
alias dub="source /opt/dubber/bin/activate && cd /opt/dubber/scripts"
export COQUI_TOS_AGREED=1
export LD_LIBRARY_PATH=/opt/nvidia-libs:${LD_LIBRARY_PATH:-}
echo ""
echo "  Plex AI Dubber LXC"
echo "    dubber --help     Run dubber"
echo "    nvidia-smi        Check GPU"
echo ""
BASHRC
    '
    log_ok "Installation complete!"
}

copy_scripts() {
    log_step "10" "Copying scripts"
    local dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for f in plex_ai_dubber.py apply_patches.sh dubber_watcher.py dubber-watcher.service install_watcher.sh; do
        if [ -f "$dir/$f" ]; then
            pct push "$CTID" "$dir/$f" /opt/dubber/scripts/$f 2>/dev/null || \
            pct push "$CTID" "$dir/$f" /root/$f 2>/dev/null || true
        fi
    done
    # Run patches
    if pct exec "$CTID" -- test -f /opt/dubber/scripts/apply_patches.sh; then
        log_info "Applying patches..."
        pct exec "$CTID" -- bash /opt/dubber/scripts/apply_patches.sh
    elif pct exec "$CTID" -- test -f /root/apply_patches.sh; then
        log_info "Applying patches..."
        pct exec "$CTID" -- bash /root/apply_patches.sh
    fi
    log_ok "Scripts deployed."
}

print_summary() {
    local dip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
    local pip=""
    while IFS= read -r line; do
        local v=$(echo "$line" | awk '{print $1}') n=$(echo "$line" | awk '{print $3}')
        echo "$n" | grep -qi "plex" && pip=$(pct exec "$v" -- hostname -I 2>/dev/null | awk '{print $1}' || true) && break
    done < <(pct list 2>/dev/null | tail -n +2)
    echo -e "\n${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}  SETUP COMPLETE!${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo "  Dubber: $CTID ($CT_NAME) — $dip"
    [ -n "$pip" ] && echo "  Plex: $pip"
    echo ""
    echo "  Get tokens:"
    echo "    Plex: https://support.plex.tv/articles/204059436"
    echo "    HuggingFace: https://hf.co/settings/tokens"
    echo "      Accept: hf.co/pyannote/segmentation-3.0"
    echo "      Accept: hf.co/pyannote/speaker-diarization-3.1"
    echo ""
    echo "  First test:"
    echo "    pct enter $CTID"
    echo "    dubber --plex-url http://${pip:-PLEX_IP}:32400 \\"
    echo "      --plex-token TOKEN --hf-token hf_TOKEN \\"
    echo "      --movie \"Movie Name\" --target-lang spa \\"
    echo "      --tts coqui --no-mux"
    echo ""
}

main() {
    echo -e "\n${CYAN}  Plex AI Dubber — Proxmox LXC Installer${NC}"
    echo -e "${CYAN}  by Avi Fridlindas${NC}\n"
    check_proxmox
    detect_gpu
    collect_nvidia_libs
    detect_resources
    find_template
    configure
    create_lxc
    configure_lxc
    start_lxc
    install_software
    copy_scripts
    print_summary
}

main "$@"
