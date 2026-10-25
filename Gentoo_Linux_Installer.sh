#!/usr/bin/env bash
#######################################################################################
#                                                                                     #
#  Gentoo-Linux-Installer (GLI) v3.0.0 - TUI Edition                                  #
#                                                                                     #
#  Refactored with dialog for a fully interactive Text User Interface (TUI) wizard.   #
#                                                                                     #
#######################################################################################

# Stop execution on error, undefined variables, and pipe failures
set -euo pipefail

#################################### Globals & Settings ###############################

GLCHROOT="/mnt/gentoo"
BACKTITLE="Gentoo Linux Automated Installer (GLI v3.0)"

# Variables to be populated by the Wizard
STAGE3_MIRROR=""
STAGE_ARCH=""
STAGE_INIT=""
USE_BINPKGS="no"
STAGE3_NAME=""
HD_DEV=""
INSTALL_DISK="hdd"
PART_BOOT=""
PART_SWAP=""
PART_ROOT=""
FS_TYPE=""
FORMAT_BOOT="no"
HOSTNAME=""
ROOT_PASS1=""
USER_NAME=""
USER_PASS1=""
BOOT_MODE="legacy"
GRUB_REMOVABLE=""

# Colors for text-mode execution
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

#################################### Base Functions ###################################

msg_step() { echo -e "\n${MAGENTA}>>> $1${NC}\n"; sleep 1; }
msg_info() { echo -e "${BLUE}INFO:${NC} $1"; }
msg_ok()   { echo -e "${GREEN}SUCCESS:${NC} $1"; }
msg_err()  { echo -e "\n${RED}ERROR:${NC} $1\n"; exit 1; }

cleanup() {
    tput cnorm 2>/dev/null || true
    clear 2>/dev/null || true
    msg_info "Cleaning up mounts (if any)..."
    umount -lR "${GLCHROOT}" 2>/dev/null || true
}

force_abort() {
    clear
    echo -e "\n${RED}=========================================${NC}"
    echo -e "${RED}  INSTALLATION ABORTED BY USER (Cancel/Esc) ${NC}"
    echo -e "${RED}=========================================${NC}\n"
    exit 130
}

trap force_abort INT TERM
trap cleanup EXIT

#################################### TUI Wrappers #####################################

ask_menu() {
    local title="$1"
    local text="$2"
    shift 2
    local choice
    choice=$(dialog --clear --backtitle "$BACKTITLE" --title "$title" --menu "$text" 15 65 8 "$@" 3>&1 1>&2 2>&3)
    local ret=$?
    [ $ret -eq 0 ] || force_abort
    echo "$choice"
}

ask_input() {
    local title="$1"
    local text="$2"
    local default="$3"
    local choice
    choice=$(dialog --clear --backtitle "$BACKTITLE" --title "$title" --inputbox "$text" 8 50 "$default" 3>&1 1>&2 2>&3)
    local ret=$?
    [ $ret -eq 0 ] || force_abort
    echo "$choice"
}

ask_password() {
    local title="$1"
    local text="$2"
    local choice
    choice=$(dialog --clear --backtitle "$BACKTITLE" --title "$title" --insecure --passwordbox "$text" 8 50 3>&1 1>&2 2>&3)
    local ret=$?
    [ $ret -eq 0 ] || force_abort
    echo "$choice"
}

ask_yesno() {
    local title="$1"
    local text="$2"
    dialog --clear --backtitle "$BACKTITLE" --title "$title" --yesno "$text" 8 60
    local ret=$?
    if [ $ret -eq 0 ]; then
        return 0
    elif [ $ret -eq 1 ]; then
        return 1
    else
        force_abort
    fi
}

#################################### Pre-Wizard Checks ################################

ensure_live_tools() {
    msg_info "Checking for required live environment tools (dialog, mirrorselect, genfstab)..."
    local missing_tools=""

    command -v dialog >/dev/null 2>&1 || missing_tools="dev-util/dialog"
    command -v mirrorselect >/dev/null 2>&1 || missing_tools="${missing_tools} app-portage/mirrorselect"
    command -v genfstab >/dev/null 2>&1 || missing_tools="${missing_tools} sys-fs/genfstab"

    if [[ -n "${missing_tools}" ]]; then
        echo -e "${YELLOW}Missing tools detected. Installing: ${missing_tools}${NC}"
        emerge -q ${missing_tools} || msg_err "Failed to install required tools!"
    fi
}

ensure_mirrors() {
    if ! [[ -f mirrors.conf ]] || ! grep -qE 'http|https|ftp|rsync' mirrors.conf; then
        mirrorselect -i -o > mirrors.conf || true
        if ! grep -qE 'http|https|ftp|rsync' mirrors.conf; then
            msg_err "No mirror was selected! Installation cannot proceed."
        fi
    fi
    STAGE3_MIRROR=$(grep -Po '(?<=GENTOO_MIRRORS=")[^"]*' mirrors.conf | awk '{print $1}' | sed 's,/$,,' || true)
}

check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then msg_err "This script must be run as root!"; fi
    if ! curl -s --connect-timeout 5 https://www.google.com/ > /dev/null; then
        msg_err "No Internet connection detected! Check your network settings."
    fi
    
    if [ -d /sys/firmware/efi/efivars ]; then BOOT_MODE='uefi'; fi

    ensure_live_tools
    ensure_mirrors
}

#################################### TUI Wizard #######################################

run_wizard() {
    dialog --clear --backtitle "$BACKTITLE" --title "Welcome" \
        --msgbox "Welcome to the Gentoo Linux Installer (TUI Edition).\n\nFollow the interactive steps to configure your system. Installation will only begin after you confirm all choices at the end." 10 65

    # 1. Arch & Init
    STAGE_ARCH=$(ask_menu "Architecture" "Choose the target architecture:" "amd64" "64-bit (Recommended)" "x86" "32-bit")
    STAGE_INIT=$(ask_menu "Init System" "Choose the init system:" "openrc" "OpenRC (Gentoo Default)" "systemd" "Systemd")

    # 2. Binary Packages
    if ask_yesno "Binary Packages" "Use official binary packages to dramatically speed up installation? (Highly Recommended)"; then
        USE_BINPKGS="yes"
    fi

    # 3. Stage3 Selection
    dialog --backtitle "$BACKTITLE" --infobox "Fetching latest Stage3 list from mirror..." 5 45
    local list_url="${STAGE3_MIRROR}/releases/${STAGE_ARCH}/autobuilds/latest-stage3.txt"
    wget -q "${list_url}" -O latest-stage3.txt || force_abort

    local stage3_lines=()
    if [ "$STAGE_INIT" = "openrc" ]; then
        mapfile -t stage3_lines < <(grep -w 'stage3' latest-stage3.txt | grep -v 'systemd')
    else
        mapfile -t stage3_lines < <(grep -w 'systemd' latest-stage3.txt)
    fi

    local stage3_items=()
    for line in "${stage3_lines[@]}"; do
        local name=$(echo "$line" | awk -F"/" '{print $2}')
        stage3_items+=("$name" "")
    done

    STAGE3_NAME=$(ask_menu "Stage3 Selection" "Select the Stage3 tarball:" "${stage3_items[@]}")
    rm -f latest-stage3.txt

    # 4. Disk Selection
    local disk_items=()
    while read -r name size model; do
        disk_items+=("/dev/$name" "$size - $model")
    done < <(lsblk -d -n -p -o NAME,SIZE,MODEL | grep -v 'loop')

    HD_DEV=$(ask_menu "Target Disk" "Select the disk to install Gentoo:" "${disk_items[@]}")
    if [[ $(lsblk -d -n -o ROTA "$HD_DEV") == "0" ]]; then INSTALL_DISK="ssd"; fi

    # 5. Partitioning Loop
    while true; do
        if ask_yesno "Partitioning" "Do you want to run cfdisk to create/edit partitions on $HD_DEV?\n\nIf you haven't partitioned the disk yet, answer YES."; then
            clear
            cfdisk "$HD_DEV"
        fi

        local part_array=()
        while read -r name size fstype; do
            if [ "$name" != "$HD_DEV" ]; then
                part_array+=("$name" "$size ${fstype:-Unknown}")
            fi
        done < <(lsblk -n -p -l -o NAME,SIZE,FSTYPE "$HD_DEV")

        if [ ${#part_array[@]} -eq 0 ]; then
            dialog --msgbox "No partitions found on $HD_DEV! You must create them." 6 50
            continue
        fi
        break
    done

    # 6. Partition Mapping
    PART_BOOT=$(ask_menu "Boot Partition" "Select EFI/Boot Partition:" "${part_array[@]}")
    PART_SWAP=$(ask_menu "Swap Partition" "Select Swap Partition (or None):" "none" "No Swap" "${part_array[@]}")
    PART_ROOT=$(ask_menu "Root Partition" "Select Root Partition:" "${part_array[@]}")

    FS_TYPE=$(ask_menu "Root Filesystem" "Choose root filesystem type:" "ext4" "Standard Linux FS" "xfs" "High performance" "btrfs" "Advanced FS with subvolumes" "jfs" "" "f2fs" "Flash-friendly")

    if ask_yesno "Format Boot" "Format EFI/Boot partition ($PART_BOOT)?\n\nWARNING: This destroys existing bootloaders!"; then
        FORMAT_BOOT="yes"
    fi

    # 7. Hostname & Passwords
    HOSTNAME=$(ask_input "Hostname" "Enter a hostname for the system:" "gentoo")

    while true; do
        ROOT_PASS1=$(ask_password "Root Password" "Enter ROOT password:")
        local rp2=$(ask_password "Root Password" "Confirm ROOT password:")
        if [ "$ROOT_PASS1" == "$rp2" ] && [ -n "$ROOT_PASS1" ]; then break; fi
        dialog --msgbox "Passwords do not match or are empty!" 6 40
    done

    if ask_yesno "User Creation" "Would you like to create a standard user?"; then
        USER_NAME=$(ask_input "User Creation" "Enter username:" "gentoo_user")
        while true; do
            USER_PASS1=$(ask_password "User Password" "Enter password for $USER_NAME:")
            local up2=$(ask_password "User Password" "Confirm password:")
            if [ "$USER_PASS1" == "$up2" ] && [ -n "$USER_PASS1" ]; then break; fi
            dialog --msgbox "Passwords do not match or are empty!" 6 40
        done
    fi

    if [ "$BOOT_MODE" = "uefi" ]; then
        if ask_yesno "GRUB Removable" "Are you installing this on a removable USB flash drive?\n\n(Sets the --removable flag for GRUB EFI)"; then
            GRUB_REMOVABLE="--removable"
        fi
    fi

    # 8. Final Confirmation
    local summary="Please review your installation settings:\n\n"
    summary+="Architecture:   $STAGE_ARCH\n"
    summary+="Init System:    $STAGE_INIT\n"
    summary+="Use BinPkgs:    $USE_BINPKGS\n"
    summary+="Target Disk:    $HD_DEV\n"
    summary+="Boot Part:      $PART_BOOT (Format: $FORMAT_BOOT)\n"
    summary+="Swap Part:      $PART_SWAP\n"
    summary+="Root Part:      $PART_ROOT (FS: $FS_TYPE)\n"
    summary+="Hostname:       $HOSTNAME\n"
    summary+="Standard User:  ${USER_NAME:-None}\n\n"
    summary+="Proceed with formatting and installation?"

    if ! ask_yesno "Confirm Installation" "$summary"; then
        force_abort
    fi
    clear
}

#################################### Execution Phase ##################################

apply_disk_formatting() {
    msg_step "Applying Disk Formatting and Mounting"

    if [ "$FORMAT_BOOT" = "yes" ]; then
        msg_info "Formatting Boot Partition ($PART_BOOT)..."
        if [ "$BOOT_MODE" = 'uefi' ]; then
            mkfs.fat -c -F 32 "$PART_BOOT"
        else
            [[ "$FS_TYPE" == "btrfs" ]] && mkfs.btrfs -f "$PART_BOOT" || mkfs.ext4 -F "$PART_BOOT"
        fi
    fi

    if [ "$PART_SWAP" != 'none' ]; then
        msg_info "Formatting SWAP ($PART_SWAP)..."
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

    if [ "$STAGE_INIT" = 'openrc' ]; then
        cp -f openrc/make.conf "$GLCHROOT/etc/portage/make.conf"
    else
        cp -f systemd/make.conf "$GLCHROOT/etc/portage/make.conf"
    fi
    
    cat mirrors.conf >> "$GLCHROOT/etc/portage/make.conf"

    if [ "$USE_BINPKGS" = "yes" ]; then
        echo 'FEATURES="${FEATURES} getbinpkg"' >> "$GLCHROOT/etc/portage/make.conf"
    fi

    local cores=$(nproc)
    local make_opts=$(( cores > 4 ? cores - 2 : (cores / 2) ))
    [ "$make_opts" -lt 1 ] && make_opts=1

    sed -i "s/xCPU_FLAGS_X86x/$(cpuid2cpuflags | cut -d':' -f2 | sed 's/^ *//')/" "$GLCHROOT/etc/portage/make.conf"
    sed -i "s/xMAKEOPTSx/${make_opts}/" "$GLCHROOT/etc/portage/make.conf"

    local video_cards="intel"
    if lspci -k | grep -EA3 'VGA|3D|Display' | grep -iq 'nvidia'; then video_cards="nvidia nouveau";
    elif lspci -k | grep -EA3 'VGA|3D|Display' | grep -iq 'amd\|radeon'; then video_cards="amdgpu radeonsi radeon";
    elif lspci -k | grep -EA3 'VGA|3D|Display' | grep -iq 'virtualbox\|vmware'; then video_cards="vmware virtualbox"; fi
    sed -i "s/xVIDEO_CARDSx/${video_cards}/" "$GLCHROOT/etc/portage/make.conf"

    msg_info "Generating fstab..."
    echo -e "### File generated by genfstab\n" > "$GLCHROOT/etc/fstab"
    if [ "$BOOT_MODE" = 'uefi' ]; then
        genfstab -U "$GLCHROOT" >> "$GLCHROOT/etc/fstab"
    else
        genfstab -L "$GLCHROOT" >> "$GLCHROOT/etc/fstab"
    fi
    sed -i 's/,subvolid=[0-9]*//g' "$GLCHROOT/etc/fstab"

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
    
    cat << 'EOF' > "$GLCHROOT/tmp/chroot_script.sh"
#!/bin/bash
set -euo pipefail
source /etc/profile

echo ">>> Syncing portage..."
emerge-webrsync

mkdir -p /etc/portage/package.use
echo "sys-kernel/installkernel dracut grub" > /etc/portage/package.use/installkernel
echo "sys-kernel/linux-firmware initramfs" >> /etc/portage/package.use/linux-firmware
EOF

    if [ "$USE_BINPKGS" = "yes" ]; then
        echo "getuto" >> "$GLCHROOT/tmp/chroot_script.sh"
    fi

    cat << 'EOF' >> "$GLCHROOT/tmp/chroot_script.sh"
echo ">>> Emerging @world (this will take time)..."
emerge -aquDN --with-bdeps=y @world
emerge -aq --depclean

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

echo ">>> Installing pre-compiled Kernel and Firmware..."
emerge -q sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware

echo ">>> Installing System Utilities..."
emerge -q app-admin/sudo net-misc/networkmanager sys-boot/grub
EOF
    
    if [ "$STAGE_INIT" = 'openrc' ]; then
        echo 'emerge -q app-admin/sysklogd sys-power/acpid sys-process/cronie net-misc/chrony' >> "$GLCHROOT/tmp/chroot_script.sh"
        echo 'rc-update add sysklogd default; rc-update add cronie default; rc-update add NetworkManager default; rc-update add acpid default; rc-update add chronyd default; rc-update add udev sysinit' >> "$GLCHROOT/tmp/chroot_script.sh"
    else
        echo 'systemctl enable NetworkManager.service acpid.service' >> "$GLCHROOT/tmp/chroot_script.sh"
    fi

    chmod +x "$GLCHROOT/tmp/chroot_script.sh"
    chroot "$GLCHROOT" /tmp/chroot_script.sh
    rm -f "$GLCHROOT/tmp/chroot_script.sh"
}

post_install_config() {
    msg_step "Post-Installation Setup"
    
    msg_info "Applying Root and User Passwords..."
    echo "root:${ROOT_PASS1}" | chroot "$GLCHROOT" chpasswd

    if [ -n "$USER_NAME" ]; then
        chroot "$GLCHROOT" useradd -m -G wheel,users,video,audio,portage -s /bin/bash "$USER_NAME"
        echo "${USER_NAME}:${USER_PASS1}" | chroot "$GLCHROOT" chpasswd
        echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$GLCHROOT/etc/sudoers.d/$USER_NAME"
        chmod 0440 "$GLCHROOT/etc/sudoers.d/$USER_NAME"
    fi

    msg_info "Configuring Hostname..."
    if [ "$STAGE_INIT" = 'openrc' ]; then
        sed -i "s/localhost/$HOSTNAME/" "$GLCHROOT/etc/conf.d/hostname"
        sed -i "s/127.0.0.1\slocalhost/127.0.0.1       $HOSTNAME localhost/" "$GLCHROOT/etc/hosts"
    else
        echo "$HOSTNAME" > "$GLCHROOT/etc/hostname"
        chroot "$GLCHROOT" systemd-machine-id-setup
    fi

    msg_info "Installing GRUB Bootloader..."
    sed -i '/#GRUB_GFXMODE=/c\GRUB_GFXMODE=auto' "$GLCHROOT/etc/default/grub"
    
    if [[ -f "grub/gentoo-wallpaper.png" ]]; then
        mkdir -p "$GLCHROOT/boot/grub"
        cp grub/gentoo-wallpaper.png "$GLCHROOT/boot/grub/"
        sed -i '/#GRUB_BACKGROUND=/c\GRUB_BACKGROUND="/boot/grub/gentoo-wallpaper.png"' "$GLCHROOT/etc/default/grub"
    fi

    if [ "$STAGE_INIT" = 'systemd' ]; then
        sed -i '/#GRUB_CMDLINE_LINUX_DEFAULT=/c\GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"' "$GLCHROOT/etc/default/grub"
    fi

    if [ "$BOOT_MODE" = 'uefi' ]; then
        chroot "$GLCHROOT" grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Gentoo" $GRUB_REMOVABLE --recheck
    else
        chroot "$GLCHROOT" grub-install "$HD_DEV"
    fi
    chroot "$GLCHROOT" grub-mkconfig -o /boot/grub/grub.cfg
}

#################################### Main Execution ###################################

check_prerequisites
run_wizard

# At this point, the user confirmed everything in the TUI. We run silently through the execution phases.
apply_disk_formatting
install_stage3
configure_base
execute_in_chroot
post_install_config

msg_step "Installation Finished!"
msg_info "The trap cleanup will now unmount the directories safely."
cleanup
trap - EXIT INT TERM 

msg_ok "System is ready! You can now reboot."
exit 0