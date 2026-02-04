#!/bin/bash
# Two-stage root script: Custom Bazzite kernel, MTU 9000 tuning, GRUB hardening, 
# and BC-250 specific hardware governors/sensors.

STATE_FILE="$HOME/.install_stage"
REPO_URL="https://github.com/bazzite-org/kernel-bazzite/releases/download/6.17.7-ba22"
KERNEL_VER="6.17.7-ba22.fc43.x86_64"

log() { echo -e "\e[32m[LOG]\e[0m $1"; }

if [[ $EUID -ne 0 ]]; then
   echo "Please run as root/sudo"
   exit 1
fi

STAGE=$(cat "$STATE_FILE" 2>/dev/null || echo "1")

# --- PHASE 1: KERNEL, NETWORKING & GRUB ---
if [ "$STAGE" == "1" ]; then
    log "Starting Phase 1: Kernel & System Tuning..."

    mkdir -p ~/bazzite-kernel-update && cd ~/bazzite-kernel-update
    
    # Download Kernel Components
    files=("kernel" "kernel-core" "kernel-modules" "kernel-modules-core" "kernel-modules-extra")
    for file in "${files[@]}"; do
        wget -q --show-progress "${REPO_URL}/${file}-${KERNEL_VER}.rpm"
    done

    dnf install -y ./*.rpm
    
    # Patch GRUB (Performance tuning: mitigations=off)
    log "Applying GRUB command line optimizations..."
    sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="rd.lvm.lv=fedora\/root rhgb quiet mitigations=off"/' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg

    # Lock Kernel & Set Default
    dnf install -y 'dnf-command(versionlock)'
    dnf versionlock add kernel*${KERNEL_VER}*
    grubby --set-default=/boot/vmlinuz-${KERNEL_VER}
    
    # --- NETWORK TUNING ---
    log "Applying P2P RPC buffer tuning..."
    {
        echo "net.core.rmem_max=7500000"
        echo "net.core.wmem_max=7500000"
    } | tee /etc/sysctl.d/10-localai-p2p.conf
    sysctl --system

    # --- GLOBAL MTU 9000 SETUP ---
    log "Setting MTU 9000 on all physical interfaces..."
    for interface in /sys/class/net/*; do
        IFACE_NAME=$(basename "$interface")
        if [ "$IFACE_NAME" != "lo" ]; then
            ip link set dev "$IFACE_NAME" mtu 9000 2>/dev/null || log "Skip $IFACE_NAME: MTU 9000 not supported"
            if command -v nmcli &> /dev/null; then
                nmcli connection modify "$IFACE_NAME" 802-3-ethernet.mtu 9000 2>/dev/null || true
            fi
        fi
    done

    log "Phase 1 Complete. Rebooting in 10 seconds. Run this script again after login."
    echo "2" > "$STATE_FILE"
    sleep 10
    reboot
fi

# --- PHASE 2: DRIVERS & LOCALAI PREP ---
if [ "$STAGE" == "2" ]; then
    log "Starting Phase 2: Hardware Support & Container Tools..."

    # Governor & Sensors (BC-250 specific)
    dnf copr enable -y filippor/bazzite
    dnf install -y cyan-skillfish-governor-tt git cmake make gcc-c++ libdrm-devel \
                   lm_sensors vulkan-tools mesa-vulkan-drivers nvtop glxinfo
    
    systemctl enable --now cyan-skillfish-governor-tt
    
    # Force Sensor Module for BC-250 Mainboards
    log "Configuring hardware sensor modules..."
    echo 'nct6683' | tee /etc/modules-load.d/99-sensors.conf
    echo 'options nct6683 force=true' | tee /etc/modprobe.d/options-sensors.conf
    dracut --regenerate-all --force

    # Directory Setup
    mkdir -p ~/localai
    log "Phase 2 Complete. Hardware is tuned and ready."
    log "NEXT STEP: Place your 'localai.sh' in ~/localai and run: ./localai.sh install"
    
    echo "FINISH" > "$STATE_FILE"
fi
