#!/usr/bin/env bash
#######################################################################################
#                                                                                     #
#  Gentoo-Linux-Installer (GLI) v2.3.0 - Unofficial Installer for Gentoo Linux        #
#                                                                                     #
#  Refactored for robust error handling, modularity, and modern bash practices.       #
#                                                                                     #
#######################################################################################

# Stop execution on error, undefined variables, and pipe failures
set -euo pipefail

#################################### Globals & Colors #################################

GLCHROOT="/mnt/gentoo"
STAGE3_MIRROR=""
STAGE_ARCH=""
STAGE_INIT=""
BOOT_MODE="legacy"
INSTALL_DISK="hdd"

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

#################################### Helper Functions #################################

msg_step() { echo -e "\n${MAGENTA}>>> $1${NC}\n"; sleep 1; }
msg_info() { echo -e "${BLUE}INFO:${NC} $1"; }
msg_ok()   { echo -e "${GREEN}SUCCESS:${NC} $1"; }
msg_warn() { echo -e "${YELLOW}WARNING:${NC} $1"; }
msg_err()  { echo -e "\n${RED}ERROR:${NC} $1\n"; exit 1; }

# Function to cleanly unmount on exit or error
cleanup() {
    msg_info "Cleaning up mounts (if any)..."
    umount -lR "${GLCHROOT}" 2>/dev/null || true
}

# Function to handle force stop (Ctrl+C)
force_abort() {
    echo -e "\n${RED}=========================================${NC}"
    echo -e "${RED}  INSTALLATION ABORTED BY USER (Ctrl+C)  ${NC}"
    echo -e "${RED}=========================================${NC}\n"
    # O exit 130 acionará automaticamente a função cleanup() mapeada no EXIT
    exit 130
}

# Configurando os Traps (Gatilhos)
trap force_abort INT TERM  # Se o usuário apertar Ctrl+C (INT) ou o script for morto (TERM)
trap cleanup EXIT          # Sempre executa ao sair do script (seja por sucesso, erro ou Ctrl+C)

# Prompt user for yes/no
ask_yes_no() {
    local prompt="$1"
    while true; do
        read -r -p "$(echo -e "${YELLOW}${prompt} (y/n): ${NC}")" choice
        case "$choice" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) msg_warn "Please answer yes or no.";;
        esac
    done
}

#################################### Core Functions ###################################

ensure_mirrorselect() {
    msg_info "Checking if 'mirrorselect' is installed on the live system..."
    if ! command -v mirrorselect >/dev/null 2>&1; then
        msg_warn "'mirrorselect' not found! Installing it now (this may take a moment)..."
        # Executa o comando de instalação solicitado
        emerge -q mirrorselect || msg_err "Failed to install mirrorselect! Please check your live environment."
        msg_ok "'mirrorselect' installed successfully!"
    else
        msg_ok "'mirrorselect' is already installed."
    fi
}

ensure_mirrors() {
    msg_info "Checking for selected mirrors..."
    
    # Se o arquivo não existir ou não contiver URLs válidas, abre o mirrorselect interativamente
    if ! [[ -f mirrors.conf ]] || ! grep -qE 'http|https|ftp|rsync' mirrors.conf; then
        msg_warn "No valid mirrors.conf found. Launching mirrorselect..."
        sleep 2
        
        # Roda o mirrorselect e salva no arquivo. O '|| true' previne crash caso o usuário cancele
        mirrorselect -i -o > mirrors.conf || true
        
        # Verifica novamente se o usuário selecionou de fato algum mirror ou se abortou
        if [[ -f mirrors.conf ]] && grep -qE 'http|https|ftp|rsync' mirrors.conf; then
            msg_ok "Mirror(s) successfully selected and saved to mirrors.conf"
        else
            msg_err "No mirror was selected! Installation cannot proceed."
        fi
    else
        msg_ok "Mirror(s) detected in mirrors.conf"
    fi

    # Extrai o primeiro mirror da lista para usar no download do stage3
    # O '|| true' protege o script do 'set -e' caso o grep não ache a regex exata
    STAGE3_MIRROR=$(grep -Po '(?<=GENTOO_MIRRORS=")[^"]*' mirrors.conf | awk '{print $1}' | sed 's,/$,,' || true)

    if [[ -z "$STAGE3_MIRROR" ]]; then
        msg_err "Failed to parse the selected mirror. Please check mirrors.conf formatting."
    fi
}

check_prerequisites() {
    msg_step "Checking Prerequisites"
    
    if [[ $EUID -ne 0 ]]; then
        msg_err "This script must be run as root!"
    fi

    msg_info "Testing internet connection..."
    if ! curl -s --connect-timeout 5 https://www.google.com/ > /dev/null; then
        msg_err "No Internet connection detected! Check your network settings."
    fi
    msg_ok "Internet connection active!"

    # Garante que o pacote mirrorselect está instalado
    ensure_mirrorselect

    # Pede para o usuário escolher o espelho ou carrega o existente
    ensure_mirrors

    if [ -d /sys/firmware/efi/efivars ]; then
        BOOT_MODE='uefi'
        msg_ok "UEFI boot mode detected."
    else
        msg_ok "Legacy BIOS boot mode detected."
    fi
}

select_architecture_and_init() {
    msg_step "System Configuration"
    
    while true; do
        read -r -p "$(echo -e "${YELLOW}Architecture: amd64 (a) or x86 (x)? ${NC}")" arch_choice
        case "$arch_choice" in
            [Aa]*|amd64) STAGE_ARCH="amd64"; break;;
            [Xx]*|x86) STAGE_ARCH="x86"; break;;
            *) msg_warn "Invalid option.";;
        esac
    done

    while true; do
        read -r -p "$(echo -e "${YELLOW}Init System: OpenRC (o) or Systemd (s)? ${NC}")" init_choice
        case "$init_choice" in
            [Oo]*|openrc) STAGE_INIT="openrc"; break;;
            [Ss]*|systemd) STAGE_INIT="systemd"; break;;
            *) msg_warn "Invalid option.";;
        esac
    done
}

select_stage3() {
    msg_step "Selecting Stage3"
    
    local list_url="${STAGE3_MIRROR}/releases/${STAGE_ARCH}/autobuilds/latest-stage3.txt"
    msg_info "Fetching stage3 list from ${list_url}"
    
    wget -q "${list_url}" -O latest-stage3.txt || msg_err "Failed to download latest-stage3.txt"

    if [ "${STAGE_INIT}" = 'openrc' ]; then
        grep -w 'stage3' latest-stage3.txt | grep -v 'systemd' | awk -F"/" '{print $2}' | nl > stage3-list.txt
    else
        grep -w 'systemd' latest-stage3.txt | awk -F"/" '{print $2}' | nl > stage3-list.txt
    fi

    cat stage3-list.txt
    echo
    
    local num_lines=$(wc -l < stage3-list.txt)
    while true; do
        read -r -p "Enter the number of the Stage3 to use (1-$num_lines): " STAGE_NUM
        if [[ "$STAGE_NUM" =~ ^[0-9]+$ ]] && [ "$STAGE_NUM" -ge 1 ] && [ "$STAGE_NUM" -le "$num_lines" ]; then
            STAGE3_NAME=$(awk "NR==$STAGE_NUM {print \$2}" stage3-list.txt | rev | cut -d '-' -f2- | rev)
            msg_ok "Selected Stage3: ${STAGE3_NAME}"
            break
        else
            msg_warn "Invalid selection."
        fi
    done
    rm -f latest-stage3.txt stage3-list.txt
}

configure_disks() {
    msg_step "Disk and Partitioning"
    
    lsblk -d -p -o NAME,SIZE,MODEL,ROTA | grep -v 'loop'
    echo
    while true; do
        read -r -p "Type the device path (e.g., /dev/sda, /dev/nvme0n1): " HD_DEV
        if lsblk "$HD_DEV" >/dev/null 2>&1; then
            break
        else
            msg_warn "Device $HD_DEV not found."
        fi
    done

    # Check if SSD
    if [[ $(lsblk -d -n -o ROTA "$HD_DEV") == "0" ]]; then
        INSTALL_DISK="ssd"
        msg_info "SSD detected. Optimizations will be applied."
    fi

    if ask_yes_no "Run cfdisk to create/edit partitions on $HD_DEV?"; then
        if ask_yes_no "Start with an empty (zeroed) partition table?"; then
            cfdisk -z "$HD_DEV"
        else
            cfdisk "$HD_DEV"
        fi
        sync
    fi

    echo -e "\n${CYAN}Available partitions:${NC}"
    lsblk -p "$HD_DEV"
    echo

    if [ "$BOOT_MODE" = 'uefi' ]; then
        read -r -p "EFI Partition (e.g., /dev/sda1): " PART_BOOT
    else
        read -r -p "Boot Partition (e.g., /dev/sda1): " PART_BOOT
    fi

    read -r -p "Swap Partition (type 'none' if empty): " PART_SWAP
    read -r -p "Root Partition (e.g., /dev/sda3): " PART_ROOT

    # Formatting
    msg_step "Formatting Partitions"
    
    FS_TYPE=""
    while [[ ! "$FS_TYPE" =~ ^(ext4|xfs|jfs|f2fs|btrfs)$ ]]; do
        read -r -p "Choose root filesystem (ext4, xfs, jfs, f2fs, btrfs): " FS_TYPE
    done

    if [ "$BOOT_MODE" = 'uefi' ]; then
        if ask_yes_no "Format EFI partition ($PART_BOOT) as FAT32? (WARNING: Destroys existing bootloaders)"; then
            mkfs.fat -c -F 32 "$PART_BOOT"
        fi
    else
        if ask_yes_no "Format Boot partition ($PART_BOOT)?"; then
            [[ "$FS_TYPE" == "btrfs" ]] && mkfs.btrfs -f "$PART_BOOT" || mkfs.ext4 -F "$PART_BOOT"
        fi
    fi

    if [ "$PART_SWAP" != 'none' ]; then
        msg_info "Formatting SWAP..."
        mkswap "$PART_SWAP"
        swapon "$PART_SWAP"
    fi

    msg_info "Formatting Root partition ($PART_ROOT) as $FS_TYPE..."
    case "$FS_TYPE" in
        ext4) mkfs.ext4 -L "Gentoo" -F "$PART_ROOT" ;;
        xfs)  mkfs.xfs -L "Gentoo" -f "$PART_ROOT" ;;
        jfs)  mkfs.jfs -q -L "Gentoo" "$PART_ROOT" ;;
        f2fs) mkfs.f2fs -l "Gentoo" -f "$PART_ROOT" ;;
        btrfs) mkfs.btrfs -L "Gentoo" -f "$PART_ROOT" ;;
    esac

    # Mounting
    msg_step "Mounting Partitions"
    mkdir -p "$GLCHROOT"

    if [ "$FS_TYPE" = 'btrfs' ]; then
        mount "$PART_ROOT" "$GLCHROOT"
        btrfs subvol create "$GLCHROOT/@"
        btrfs subvol create "$GLCHROOT/@home"
        btrfs subvol create "$GLCHROOT/@snapshots"
        btrfs subvol create "$GLCHROOT/@var_log"
        umount -lR "$GLCHROOT"

        local BTRFS_OPTS="defaults,noatime,compress=zstd"
        [[ "$INSTALL_DISK" == "ssd" ]] && BTRFS_OPTS="${BTRFS_OPTS},ssd,autodefrag"
        
        mount -t btrfs -o "${BTRFS_OPTS},subvol=@" "$PART_ROOT" "$GLCHROOT"
        mkdir -p "$GLCHROOT"/{home,.snapshots,var/log}
        mount -t btrfs -o "${BTRFS_OPTS},subvol=@home" "$PART_ROOT" "$GLCHROOT/home"
        mount -t btrfs -o "${BTRFS_OPTS},subvol=@snapshots" "$PART_ROOT" "$GLCHROOT/.snapshots"
        mount -t btrfs -o "${BTRFS_OPTS},subvol=@var_log" "$PART_ROOT" "$GLCHROOT/var/log"
    else
        mount "$PART_ROOT" "$GLCHROOT"
    fi

    if [ "$BOOT_MODE" = 'uefi' ]; then
        mkdir -p "$GLCHROOT/efi"
        mount "$PART_BOOT" "$GLCHROOT/efi"
    else
        mkdir -p "$GLCHROOT/boot"
        mount "$PART_BOOT" "$GLCHROOT/boot"
    fi
}

install_stage3() {
    msg_step "Downloading and Extracting Stage3"
    
    local stage3_url="${STAGE3_MIRROR}/releases/${STAGE_ARCH}/autobuilds/current-${STAGE3_NAME}/"
    
    cd "$GLCHROOT"
    msg_info "Downloading Stage3 tarball and verification files..."
    wget -nv -nd -np -r -A "*.tar.xz,*.tar.xz.sha256" "${stage3_url}"

    msg_info "Verifying cryptographic signatures..."
    wget -qO - https://qa-reports.gentoo.org/output/service-keys.gpg | gpg --quiet --import
    if ! gpg --verify --output - stage3-*.tar.xz.sha256 | sha256sum -c --quiet; then
        msg_err "Verification failed! Corrupted Stage3 file."
    fi
    msg_ok "Verification successful."

    msg_info "Extracting Stage3 (This takes a while)..."
    tar xpf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
    rm -f stage3-*.tar.xz*
    cd - >/dev/null
}

configure_base() {
    msg_step "Configuring Base Environment"

    mkdir -p "$GLCHROOT/etc/portage/repos.conf"
    cp "$GLCHROOT/usr/share/portage/config/repos.conf" "$GLCHROOT/etc/portage/repos.conf/gentoo.conf"
    cp --dereference /etc/resolv.conf "$GLCHROOT/etc/"

    # Choose correct make.conf template
    if [ "$STAGE_INIT" = 'openrc' ]; then
        cp -f openrc/make.conf "$GLCHROOT/etc/portage/make.conf"
    else
        cp -f systemd/make.conf "$GLCHROOT/etc/portage/make.conf"
    fi
    cp -f binhost/gentoobinhost.conf "$GLCHROOT/etc/portage/binrepos.conf/"
    cat mirrors.conf >> "$GLCHROOT/etc/portage/make.conf"

    # CPU Makeopts calculation
    local cores=$(nproc)
    local make_opts=1
    if [ "$cores" -le 4 ]; then make_opts=$((cores / 2));
    elif [ "$cores" -le 8 ]; then make_opts=$((cores - 2));
    else make_opts=$((cores - 4)); fi
    [ "$make_opts" -lt 1 ] && make_opts=1

    sed -i "s/xACCEPT_KEYWORDSx/${STAGE_ARCH}/" "$GLCHROOT/etc/portage/make.conf"
    sed -i "s/xCPU_FLAGS_X86x/$(cpuid2cpuflags | cut -d':' -f2 | sed 's/^ *//')/" "$GLCHROOT/etc/portage/make.conf"
    sed -i "s/xMAKEOPTSx/${make_opts}/" "$GLCHROOT/etc/portage/make.conf"

    # Minimal GPU setup for make.conf
    msg_info "Configuring VIDEO_CARDS..."
    local video_cards="intel" # default fallback
    if lspci -k | grep -EA3 'VGA|3D|Display' | grep -iq 'nvidia'; then
        video_cards="nvidia nouveau"
    elif lspci -k | grep -EA3 'VGA|3D|Display' | grep -iq 'amd\|radeon'; then
        video_cards="amdgpu radeonsi radeon"
    elif lspci -k | grep -EA3 'VGA|3D|Display' | grep -iq 'virtualbox\|vmware'; then
        video_cards="vmware virtualbox"
    fi
    sed -i "s/xVIDEO_CARDSx/${video_cards}/" "$GLCHROOT/etc/portage/make.conf"

    msg_info "Generating fstab..."
    echo -e "### File generated by genfstab\n" > "$GLCHROOT/etc/fstab"
    if [ "$BOOT_MODE" = 'uefi' ]; then
        genfstab -U "$GLCHROOT" >> "$GLCHROOT/etc/fstab"
    else
        genfstab -L "$GLCHROOT" >> "$GLCHROOT/etc/fstab"
    fi
    # Remove subvolid for btrfs snapshots
    sed -i 's/,subvolid=[0-9]*//g' "$GLCHROOT/etc/fstab"

    # Mount pseudo-filesystems
    mount --types proc /proc "$GLCHROOT/proc"
    mount --rbind /sys "$GLCHROOT/sys"
    mount --rbind /dev "$GLCHROOT/dev"
    mount --bind /run "$GLCHROOT/run"
    if [ "$STAGE_INIT" = 'systemd' ]; then
        mount --make-rslave "$GLCHROOT/sys"
        mount --make-rslave "$GLCHROOT/dev"
        mount --make-slave "$GLCHROOT/run"
    fi
}

execute_in_chroot() {
    msg_step "Chroot Operations (Portage, Profile, Compiling)"
    
    # Create a script to run inside the chroot
    cat << 'EOF' > "$GLCHROOT/tmp/chroot_script.sh"
#!/bin/bash
set -euo pipefail
source /etc/profile

echo ">>> Syncing portage..."
emerge-webrsync

# Keep default profile unless specified otherwise manually later
echo ">>> Setting basic package uses..."
mkdir -p /etc/portage/package.use
echo "sys-kernel/installkernel dracut grub" > /etc/portage/package.use/kernel
echo "sys-kernel/linux-firmware initramfs" >> /etc/portage/package.use/kernel

echo ">>> Emerging @world (this will take time)..."
emerge -aquDN --with-bdeps=y @world
emerge -aq --depclean

echo ">>> Setting Timezone to UTC (User can change later)..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

echo ">>> Generating locale (en_US.UTF-8)..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

echo ">>> Installing Kernel and Firmware..."
emerge -q sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware

echo ">>> Installing System Utilities..."
emerge -q app-admin/sudo net-misc/networkmanager sys-boot/grub
EOF
    
    # Specific tool based on init
    if [ "$STAGE_INIT" = 'openrc' ]; then
        echo 'emerge -q app-admin/sysklogd sys-power/acpid sys-process/cronie net-misc/chrony' >> "$GLCHROOT/tmp/chroot_script.sh"
        echo 'rc-update add sysklogd default; rc-update add cronie default; rc-update add NetworkManager default; rc-update add acpid default; rc-update add chronyd default; rc-update add udev sysinit' >> "$GLCHROOT/tmp/chroot_script.sh"
    else
        echo 'systemctl enable NetworkManager.service acpid.service' >> "$GLCHROOT/tmp/chroot_script.sh"
    fi

    # Execute the generated script
    chmod +x "$GLCHROOT/tmp/chroot_script.sh"
    chroot "$GLCHROOT" /tmp/chroot_script.sh
    rm -f "$GLCHROOT/tmp/chroot_script.sh"
}

post_install_config() {
    msg_step "Post-Installation Setup"
    
    # Set Root Password
    msg_info "Set ROOT password:"
    chroot "$GLCHROOT" passwd

    # Hostname
    read -r -p "Enter a hostname for the system: " HOSTNAME
    if [ "$STAGE_INIT" = 'openrc' ]; then
        sed -i "s/localhost/$HOSTNAME/" "$GLCHROOT/etc/conf.d/hostname"
        sed -i "s/127.0.0.1\slocalhost/127.0.0.1       $HOSTNAME localhost/" "$GLCHROOT/etc/hosts"
    else
        echo "$HOSTNAME" > "$GLCHROOT/etc/hostname"
        chroot "$GLCHROOT" systemd-machine-id-setup
    fi

    # GRUB Installation
    msg_info "Installing GRUB Bootloader..."
    sed -i '/#GRUB_GFXMODE=/c\GRUB_GFXMODE=auto' "$GLCHROOT/etc/default/grub"
    if [ "$STAGE_INIT" = 'systemd' ]; then
        sed -i '/#GRUB_CMDLINE_LINUX_DEFAULT=/c\GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"' "$GLCHROOT/etc/default/grub"
    fi

    if [ "$BOOT_MODE" = 'uefi' ]; then
        local removable=""
        ask_yes_no "Installing on a USB drive (Removable)?" && removable="--removable"
        chroot "$GLCHROOT" grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Gentoo" $removable --recheck
    else
        chroot "$GLCHROOT" grub-install "$HD_DEV"
    fi
    chroot "$GLCHROOT" grub-mkconfig -o /boot/grub/grub.cfg

    # User Creation
    if ask_yes_no "Would you like to create a standard user?"; then
        read -r -p "Enter username: " USER_NAME
        chroot "$GLCHROOT" useradd -m -G wheel,users,video,audio,portage -s /bin/bash "$USER_NAME"
        echo -e "\n$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" >> "$GLCHROOT/etc/sudoers"
        msg_info "Set password for $USER_NAME:"
        chroot "$GLCHROOT" passwd "$USER_NAME"
    fi
}

#################################### Main Execution ###################################

clear
echo -e "${MAGENTA}"
echo "#####################################################################"
echo "#                                                                   #"
echo "#          Gentoo Linux Automated Installer (GLI v2.3)              #"
echo "#                                                                   #"
echo "#####################################################################"
echo -e "${NC}"

check_prerequisites
select_architecture_and_init
select_stage3
configure_disks
install_stage3
configure_base
execute_in_chroot
post_install_config

msg_step "Installation Finished!"
msg_info "The trap cleanup will now unmount the directories safely."
# Explicit cleanup before natural exit ensures everything is flushed
cleanup

# Remove os gatilhos, pois o script terminou com sucesso e já limpou
trap - EXIT INT TERM 

msg_ok "System is ready! You can now reboot."
exit 0