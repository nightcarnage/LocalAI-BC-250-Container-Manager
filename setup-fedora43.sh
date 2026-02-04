#!/bin/bash
# Professional Two-Stage Host Setup for Fedora 43 / BC-250
# Focus: Kernel Optimization, Storage Expansion, and Hardware Telemetry.
# This script provides an automated, two-stage deployment to optimize Fedora 43 Server for high-performance LocalAI clustering. 
# It is specifically tuned for the ASUS BC-250 mining APU and high-bandwidth P2P networking.

STATE_FILE="$HOME/.install_stage"
REPO_URL="https://github.com/bazzite-org/kernel-bazzite/releases/download/6.17.7-ba22"
KERNEL_VER="6.17.7-ba22.fc43.x86_64"

log() { echo -e "\e[32m[LOG]\e[0m $1"; }

if [[ $EUID -ne 0 ]]; then
   echo "Please run as root/sudo"
   exit 1
fi

STAGE=$(cat "$STATE_FILE" 2>/dev/null || echo "1")

# --- PHASE 1: STORAGE, KERNEL & NETWORKING ---
if [ "$STAGE" == "1" ]; then
    log "Starting Phase 1: Core System & Kernel Optimization..."

    # 1. LVM Detection & Expansion
    # Fedora Server defaults to 50% disk allocation; this recovers the full SSD capacity.
    
 # --- CLONING & REPLICATION WARNING ---
    # NOTE: Expanding LVM to 100% capacity is recommended for standalone nodes.
    # However, if you plan to 'dd' or sector-clone an LVM drive to other nodes in your 
    # cluster it will most likely fail to duplicate. If you plan to use replication, 
    # a manual partition layout using ext4 or xfs or literally anything else during OS installation is preferred.
    if command -v lvs &> /dev/null; then
        FREE_SPACE=$(vgs --noheadings -o vg_free | xargs)
        if [[ ! -z "$FREE_SPACE" && "$FREE_SPACE" != "0" ]]; then
            echo -e "\n[!] STORAGE NOTICE: Fedora 43 often installs with 50% unallocated space."
            read -p "[?] Detected $FREE_SPACE free. Expand /dev/mapper/fedora-root to 100%? [y/N]: " EXPAND_LVM
            if [[ "$EXPAND_LVM" =~ ^[Yy]$ ]]; then
                log "Extending Logical Volume and resizing XFS filesystem..."
                lvextend -l +100%FREE /dev/mapper/fedora-root && xfs_growfs / || log "Storage expansion failed."
            fi
        fi
    fi

    # 2. Bazzite Kernel Deployment
    # This kernel is required for proper RDNA2/BC-250 support on Fedora 43.
    log "Downloading Bazzite Kernel components (ver: $KERNEL_VER)..."
    mkdir -p ~/bazzite-kernel-update && cd ~/bazzite-kernel-update
    files=("kernel" "kernel-core" "kernel-modules" "kernel-modules-core" "kernel-modules-extra")
    for file in "${files[@]}"; do
        wget -q --show-progress "${REPO_URL}/${file}-${KERNEL_VER}.rpm"
    done
    
    log "Installing Kernel and locking version to prevent accidental updates..."
    dnf install -y ./*.rpm
    dnf install -y 'dnf-command(versionlock)'
    dnf versionlock add kernel*${KERNEL_VER}*
    grubby --set-default=/boot/vmlinuz-${KERNEL_VER}
    
    # 3. GRUB & Performance Tuning
    log "Disabling CPU security mitigations for maximum inference throughput..."
    sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="rd.lvm.lv=fedora\/root rhgb quiet mitigations=off"/' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg
    
    # 4. Network P2P Tuning
    log "Applying high-bandwidth network buffer tuning (7.5MB)..."
    { echo "net.core.rmem_max=7500000"; echo "net.core.wmem_max=7500000"; } | tee /etc/sysctl.d/10-localai-p2p.conf
    sysctl --system

    # 5. Optional MTU 9000 (Jumbo Frames)
    echo -e "\n[!] NETWORK NOTICE: MTU 9000 requires support from your physical switch."
    read -t 15 -p "[?] Enable Jumbo Frames (MTU 9000)? [y/N]: " USE_JUMBO || USE_JUMBO="n"
    if [[ "$USE_JUMBO" =~ ^[Yy]$ ]]; then
        log "Applying MTU 9000 to all physical interfaces..."
        for interface in /sys/class/net/*; do
            IFACE_NAME=$(basename "$interface")
            if [ "$IFACE_NAME" != "lo" ]; then
                ip link set dev "$IFACE_NAME" mtu 9000 2>/dev/null && \
                nmcli connection modify "$IFACE_NAME" 802-3-ethernet.mtu 9000 2>/dev/null || true
            fi
        done
    fi

    log "Phase 1 Complete. Rebooting in 10s to initialize the Bazzite Kernel."
    echo "2" > "$STATE_FILE"
    sleep 10
    reboot
fi

# --- PHASE 2: HARDWARE DRIVERS & MONITORING ---
if [ "$STAGE" == "2" ]; then
    log "Starting Phase 2: Hardware-Specific Drivers & Tools..."

    # 1. Skillfish Power Management & Telemetry
    log "Enabling Bazzite COPR repository..."
    dnf copr enable -y filippor/bazzite
    
    log "Installing hardware-level packages:"
    log " - cyan-skillfish-governor-tt: Critical power management for BC-250"
    log " - nvtop: GPU/APU resource monitoring"
    log " - mesa-vulkan-drivers: Required for LocalAI Vulkan offloading"
    log " - lm_sensors: Thermal telemetry"
    
    dnf install -y cyan-skillfish-governor-tt nvtop lm_sensors \
                   vulkan-tools mesa-vulkan-drivers libdrm-devel \
                   git cmake make gcc-c++
    
    log "Starting Cyan Skillfish Governor..."
    systemctl enable --now cyan-skillfish-governor-tt
    
    # 2. Sensor Module Configuration
    # Forces nct6683 for fan and temp visibility on BC-250 mainboards.
    log "Forcing nct6683 sensor modules..."
    echo 'nct6683' | tee /etc/modules-load.d/99-sensors.conf
    echo 'options nct6683 force=true' | tee /etc/modprobe.d/options-sensors.conf
    dracut --regenerate-all --force

    mkdir -p ~/localai
    echo "FINISH" > "$STATE_FILE"
    log "Optimization Complete. Host is fully tuned for LocalAI clustering."
fi


