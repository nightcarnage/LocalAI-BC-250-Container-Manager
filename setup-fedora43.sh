#!/bin/bash
# Professional Two-Stage Host Setup for Fedora 43 / BC-250
# Optimizes Kernel, Networking (MTU 9000), and Hardware Telemetry.

STATE_FILE="$HOME/.install_stage"
REPO_URL="https://github.com/bazzite-org/kernel-bazzite/releases/download/6.17.7-ba22"
KERNEL_VER="6.17.7-ba22.fc43.x86_64"

log() { echo -e "\e[32m[LOG]\e[0m $1"; }

if [[ $EUID -ne 0 ]]; then
   echo "Please run as root/sudo"
   exit 1
fi

STAGE=$(cat "$STATE_FILE" 2>/dev/null || echo "1")

# --- PHASE 1: KERNEL, NETWORKING & STORAGE ---
if [ "$STAGE" == "1" ]; then
    log "Starting Phase 1: Core System Optimization..."

    # 1. LVM Expansion (Optional)
    if command -v lvs &> /dev/null; then
        FREE_SPACE=$(vgs --noheadings -o vg_free | xargs)
        if [[ ! -z "$FREE_SPACE" && "$FREE_SPACE" != "0" ]]; then
            read -p "[?] Detected $FREE_SPACE free in Volume Group. Expand root to 100%? [y/N]: " EXPAND_LVM
            if [[ "$EXPAND_LVM" =~ ^[Yy]$ ]]; then
                log "Expanding LVM partition..."
                lvextend -l +100%FREE /dev/mapper/fedora-root && xfs_growfs / || log "Expansion failed."
            fi
        fi
    fi

    # 2. Kernel Installation
    mkdir -p ~/bazzite-kernel-update && cd ~/bazzite-kernel-update
    files=("kernel" "kernel-core" "kernel-modules" "kernel-modules-core" "kernel-modules-extra")
    for file in "${files[@]}"; do
        wget -q --show-progress "${REPO_URL}/${file}-${KERNEL_VER}.rpm"
    done
    dnf install -y ./*.rpm
    
    # 3. GRUB Tuning (Performance)
    sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="rd.lvm.lv=fedora\/root rhgb quiet mitigations=off"/' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg
    dnf install -y 'dnf-command(versionlock)'
    dnf versionlock add kernel*${KERNEL_VER}*
    grubby --set-default=/boot/vmlinuz-${KERNEL_VER}
    
    # 4. Network Buffers
    { echo "net.core.rmem_max=7500000"; echo "net.core.wmem_max=7500000"; } | tee /etc/sysctl.d/10-localai-p2p.conf
    sysctl --system

    # 5. Optional MTU 9000
    read -t 15 -p "[?] Enable Jumbo Frames (MTU 9000)? Requires Switch Support. [y/N]: " USE_JUMBO || USE_JUMBO="n"
    if [[ "$USE_JUMBO" =~ ^[Yy]$ ]]; then
        for interface in /sys/class/net/*; do
            IFACE_NAME=$(basename "$interface")
            if [ "$IFACE_NAME" != "lo" ]; then
                ip link set dev "$IFACE_NAME" mtu 9000 2>/dev/null && \
                nmcli connection modify "$IFACE_NAME" 802-3-ethernet.mtu 9000 2>/dev/null || true
            fi
        done
        log "MTU 9000 applied where supported."
    fi

    log "Phase 1 Complete. Rebooting in 10s..."
    echo "2" > "$STATE_FILE"
    sleep 10
    reboot
fi

# --- PHASE 2: HARDWARE & DRIVERS ---
if [ "$STAGE" == "2" ]; then
    log "Starting Phase 2: Hardware Support..."

    dnf copr enable -y filippor/bazzite
    dnf install -y cyan-skillfish-governor-tt git cmake make gcc-c++ libdrm-devel \
                   lm_sensors vulkan-tools mesa-vulkan-drivers nvtop
    
    systemctl enable --now cyan-skillfish-governor-tt
    
    # Force BC-250 Sensor Telemetry
    echo 'nct6683' | tee /etc/modules-load.d/99-sensors.conf
    echo 'options nct6683 force=true' | tee /etc/modprobe.d/options-sensors.conf
    dracut --regenerate-all --force

    mkdir -p ~/localai
    echo "FINISH" > "$STATE_FILE"
    log "Setup Complete. Host is ready for localai.sh"
fi
