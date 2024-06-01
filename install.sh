#!/bin/bash

# Copyright (C) 2021-2024 Thien Tran, Tommaso Chiti
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

output(){
    echo -e '\e[36m'"$1"'\e[0m';
}

unpriv(){
    sudo -u nobody "$@"
}

install_mode_selector() {
    output 'Is this a desktop or server installation?'
    output '1) Desktop'
    output '2) Server'
    output 'Insert the number of your selection:'
    read -r choice
    case $choice in
        1 ) install_mode=desktop
            ;;
        2 ) install_mode=server
            ;;
        * ) output 'You did not enter a valid selection.'
            install_mode_selector
    esac
}

luks_password_prompt () {
    output 'Enter your encryption password (the password will not be shown on the screen):'
    read -r -s luks_password

    if [ -z "${luks_password}" ]; then
        output 'You need to enter a password.'
        luks_password_prompt
    fi

    output 'Confirm your encryption password (the password will not be shown on the screen):'
    read -r -s luks_password2
    if [ "${luks_password}" != "${luks_password2}" ]; then
        output 'Passwords do not match, please try again.'
        luks_password_prompt
    fi
}

disk_prompt (){
    lsblk
    output 'Please select the number of the corresponding disk (e.g. 1):'
    select entry in $(lsblk -dpnoNAME|grep -P "/dev/sd|nvme|vd");
    do
        disk="${entry}"
        output "Arch Linux will be installed on the following disk: ${disk}"
        break
    done
}

username_prompt (){
    output 'Enter your username:'
    read -r username

    if [ -z "${username}" ]; then
        output 'You need to enter a username.'
        username_prompt
    fi
}

user_password_prompt () {
    output 'Enter your user password (the password will not be shown on the screen):'
    read -r -s user_password

    if [ -z "${user_password}" ]; then
        output 'You need to enter a password.'
        user_password_prompt
    fi

    output 'Confirm your user password (the password will not be shown on the screen):'
    read -r -s user_password2
    if [ "${user_password}" != "${user_password2}" ]; then
        output 'Passwords do not match, please try again.'
        user_password_prompt
    fi
}

hostname_prompt (){
    output 'Enter your hostname:'
    read -r hostname

    if [ -z "${hostname}" ]; then
        output 'You need to enter a hostname.'
        hostname_prompt
    fi
}

# Set hardcoded variables (temporary, these will be replaced by future prompts)
locale=en_US
kblayout=us

# Cleaning the TTY.
clear

# Initial prompts
install_mode_selector 
luks_password_prompt
disk_prompt
username_prompt
user_password_prompt
hostname_prompt

# Check if this is a VM
virtualization=$(systemd-detect-virt)

# Installation

## Updating the live environment usually causes more problems than its worth, and quite often can't be done without remounting cowspace with more capacity, especially at the end of any given month.
pacman -Sy

## Installing curl
pacman -S --noconfirm curl

## Formatting the disk
wipefs -af "${disk}" &>/dev/null
sgdisk -Zo "${disk}" &>/dev/null

## Creating a new partition scheme.
output "Creating new partition scheme on ${disk}."
parted -s "${disk}" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart cryptroot 513MiB 100%

ESP='/dev/disk/by-partlabel/ESP'
cryptroot='/dev/disk/by-partlabel/cryptroot'

## Informing the Kernel of the changes.
output 'Informing the Kernel about the disk changes.'
partprobe "${disk}"

## Formatting the ESP as FAT32.
output 'Formatting the EFI Partition as FAT32.'
mkfs.fat -F 32 -s 2 "${ESP}" &>/dev/null

## Creating a LUKS Container for the root partition.
output 'Creating LUKS Container for the root partition.'
echo -n "${luks_password}" | cryptsetup luksFormat --type luks1 ${cryptroot} -d - &>/dev/null
echo -n "${luks_password}" | cryptsetup open ${cryptroot} cryptroot -d -
BTRFS='/dev/mapper/cryptroot'

## Formatting the LUKS Container as BTRFS.
output 'Formatting the LUKS container as BTRFS.'
mkfs.btrfs "${BTRFS}" &>/dev/null
mount "${BTRFS}" /mnt

## Creating BTRFS subvolumes.
output 'Creating BTRFS subvolumes.'

btrfs su cr /mnt/@ &>/dev/null
btrfs su cr /mnt/@/.snapshots &>/dev/null
mkdir -p /mnt/@/.snapshots/1 &>/dev/null
btrfs su cr /mnt/@/.snapshots/1/snapshot &>/dev/null
btrfs su cr /mnt/@/boot/ &>/dev/null
btrfs su cr /mnt/@/home &>/dev/null
btrfs su cr /mnt/@/root &>/dev/null
btrfs su cr /mnt/@/srv &>/dev/null
btrfs su cr /mnt/@/var_log &>/dev/null
btrfs su cr /mnt/@/var_log_journal &>/dev/null
btrfs su cr /mnt/@/var_crash &>/dev/null
btrfs su cr /mnt/@/var_cache &>/dev/null
btrfs su cr /mnt/@/var_tmp &>/dev/null
btrfs su cr /mnt/@/var_spool &>/dev/null
btrfs su cr /mnt/@/var_lib_libvirt_images &>/dev/null
btrfs su cr /mnt/@/var_lib_machines &>/dev/null
btrfs su cr /mnt/@/var_lib_gdm &>/dev/null
btrfs su cr /mnt/@/var_lib_AccountsService &>/dev/null
btrfs su cr /mnt/@/cryptkey &>/dev/null

## Disable CoW on subvols we are not taking snapshots of
chattr +C /mnt/@/boot
chattr +C /mnt/@/home
chattr +C /mnt/@/root
chattr +C /mnt/@/srv
chattr +C /mnt/@/var_log
chattr +C /mnt/@/var_log_journal
chattr +C /mnt/@/var_crash
chattr +C /mnt/@/var_cache
chattr +C /mnt/@/var_tmp
chattr +C /mnt/@/var_spool
chattr +C /mnt/@/var_lib_libvirt_images
chattr +C /mnt/@/var_lib_machines
chattr +C /mnt/@/var_lib_gdm
chattr +C /mnt/@/var_lib_AccountsService
chattr +C /mnt/@/cryptkey

## Set the default BTRFS Subvol to Snapshot 1 before pacstrapping
btrfs subvolume set-default "$(btrfs subvolume list /mnt | grep "@/.snapshots/1/snapshot" | grep -oP '(?<=ID )[0-9]+')" /mnt

## Temporarily hardcode the date here, will make it work with proper date later.
echo '<?xml version="1.0"?>
<snapshot>
  <type>single</type>
  <num>1</num>
  <date>1999-03-31 0:00:00</date>
  <description>First Root Filesystem</description>
  <cleanup>number</cleanup>
</snapshot>' > /mnt/@/.snapshots/1/info.xml

chmod 600 /mnt/@/.snapshots/1/info.xml

## Mounting the newly created subvolumes.
umount /mnt
output 'Mounting the newly created subvolumes.'
mount -o ssd,noatime,compress=zstd "${BTRFS}" /mnt
mkdir -p /mnt/{boot,root,home,.snapshots,srv,tmp,/var/log,/var/crash,/var/cache,/var/tmp,/var/spool,/var/lib/libvirt/images,/var/lib/machines,/var/lib/gdm,/var/lib/AccountsService,/cryptkey}
mount -o ssd,noatime,compress=zstd,nodev,nosuid,noexec,subvol=@/boot "${BTRFS}" /mnt/boot
mount -o ssd,noatime,compress=zstd,nodev,nosuid,subvol=@/root "${BTRFS}" /mnt/root
mount -o ssd,noatime,compress=zstd,nodev,nosuid,subvol=@/home "${BTRFS}" /mnt/home
mount -o ssd,noatime,compress=zstd,subvol=@/.snapshots "${BTRFS}" /mnt/.snapshots
mount -o ssd,noatime,compress=zstd,subvol=@/srv "${BTRFS}" /mnt/srv
mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var_log "${BTRFS}" /mnt/var/log

### Toolbox (https://github.com/containers/toolbox) needs /var/log/journal to have dev, suid, and exec, Thus I am splitting the subvolume. Need to make the directory after /mnt/var/log/ has been mounted.
mkdir -p /mnt/var/log/journal
mount -o ssd,noatime,compress=zstd,nodatacow,subvol=@/var_log_journal "${BTRFS}" /mnt/var/log/journal

mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var_crash "${BTRFS}" /mnt/var/crash
mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var_cache "${BTRFS}" /mnt/var/cache
mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var_tmp "${BTRFS}" /mnt/var/tmp

mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var_spool "${BTRFS}" /mnt/var/spool
mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var_lib_libvirt_images "${BTRFS}" /mnt/var/lib/libvirt/images
mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/var_lib_machines "${BTRFS}" /mnt/var/lib/machines

### The encryption is splitted as we do not want to include it in the backup with snap-pac.
mount -o ssd,noatime,compress=zstd,nodatacow,nodev,nosuid,noexec,subvol=@/cryptkey "${BTRFS}" /mnt/cryptkey

mkdir -p /mnt/boot/efi
mount -o nodev,nosuid,noexec "${ESP}" /mnt/boot/efi

## Check the microcode to install.
if [ "${virtualization}" = 'none' ]; then
    CPU=$(grep vendor_id /proc/cpuinfo)
    if [[ "${CPU}" == *"AuthenticAMD"* ]]; then
        microcode=amd-ucode
    else
        microcode=intel-ucode
    fi
fi

## Pacstrap
output 'Installing the base system (it may take a while).'
if [ "${install_mode}" = 'desktop' ]; then
    pacstrap /mnt base "${microcode}" apparmor chrony efibootmgr firewalld grub grub-btrfs inotify-tools linux-firmware linux-hardened linux-lts nano networkmanager reflector sbctl snapper sudo zram-generator nautilus gdm gnome-console gnome-control-center pipewire-alsa pipewire-pulse pipewire-jack
elif [ "${install_mode}" = 'server' ]; then
    pacstrap /mnt base "${microcode}" apparmor chrony efibootmgr firewalld grub grub-btrfs inotify-tools linux-firmware linux-hardened linux-lts nano networkmanager reflector sbctl snapper sudo zram-generator openssh
fi

if [ "${virtualization}" = 'none' ]; then
    pacstrap /mnt fwupd
    echo 'UriSchemes=file;https' | sudo tee -a /mnt/etc/fwupd/fwupd.conf
elif [ "${virtualization}" = 'kvm' ]; then
    pacstrap /mnt qemu-guest-agent
    if [ "${install_mode}" = 'desktop' ]; then
        pacstrap /mnt spice-vdagent
    fi
fi

## Install snap-pac list otherwise we will have problems
pacstrap /mnt snap-pac

## Generate /etc/fstab.
output 'Generating a new fstab.'
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's#,subvolid=258,subvol=/@/.snapshots/1/snapshot,subvol=@/.snapshots/1/snapshot##g' /mnt/etc/fstab

output 'Setting up hostname, locale and keyboard layout' 

## Set hostname.
echo "$hostname" > /mnt/etc/hostname

## Setting hosts file.
echo 'Setting hosts file.'
echo "127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname" > /mnt/etc/hosts

## Setup locales.
echo "$locale.UTF-8 UTF-8"  > /mnt/etc/locale.gen
echo "LANG=$locale.UTF-8" > /mnt/etc/locale.conf

## Setup keyboard layout.
echo "KEYMAP=$kblayout" > /mnt/etc/vconsole.conf

## Configure /etc/mkinitcpio.conf
output 'Configuring /etc/mkinitcpio for ZSTD compression and LUKS hook.'
sed -i 's/#COMPRESSION="zstd"/COMPRESSION="zstd"/g' /mnt/etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems)/g' /mnt/etc/mkinitcpio.conf

## Enable LUKS in GRUB and setting the UUID of the LUKS container.
sed -i 's/#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/g' /mnt/etc/default/grub
echo '' >> /mnt/etc/default/grub
echo '# Booting with BTRFS subvolume
GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=true' >> /mnt/etc/default/grub

## Disable root subvol pinning.
## This is **extremely** important, as snapper expects to be able to set the default btrfs subvol.
# shellcheck disable=SC2016
sed -i 's/rootflags=subvol=${rootsubvol}//g' /mnt/etc/grub.d/10_linux
# shellcheck disable=SC2016
sed -i 's/rootflags=subvol=${rootsubvol}//g' /mnt/etc/grub.d/20_linux_xen

## Kernel hardening
UUID=$(blkid -s UUID -o value "${cryptroot}")
sed -i "s#quiet#rd.luks.name=${UUID}=cryptroot root=${BTRFS} mitigations=auto,nosmt spectre_v2=on spectre_bhi=on spec_store_bypass_disable=on tsx=off kvm.nx_huge_pages=force nosmt=force l1d_flush=on spec_rstack_overflow=safe-ret gather_data_sampling=force reg_file_data_sampling=on random.trust_bootloader=off random.trust_cpu=off intel_iommu=on amd_iommu=force_isolation efi=disable_early_pci_dma iommu=force iommu.passthrough=0 iommu.strict=1 slab_nomerge init_on_alloc=1 init_on_free=1 pti=on vsyscall=none ia32_emulation=0 page_alloc.shuffle=1 randomize_kstack_offset=on debugfs=off lockdown=confidentiality module.sig_enforce=1#g" /mnt/etc/default/grub

## Add keyfile to the initramfs to avoid double password.
dd bs=512 count=4 if=/dev/random of=/mnt/cryptkey/.root.key iflag=fullblock &>/dev/null
chmod 000 /mnt/cryptkey/.root.key &>/dev/null
echo -n "${luks_password}" | cryptsetup luksAddKey /dev/disk/by-partlabel/cryptroot /mnt/cryptkey/.root.key -d -
sed -i 's#FILES=()#FILES=(/cryptkey/.root.key)#g' /mnt/etc/mkinitcpio.conf
sed -i "s#module.sig_enforce=1#module.sig_enforce=1 rd.luks.key=/cryptkey/.root.key#g" /mnt/etc/default/grub

## Continue kernel hardening
unpriv curl https://raw.githubusercontent.com/Kicksecure/security-misc/master/etc/modprobe.d/30_security-misc.conf | tee /mnt/etc/modprobe.d/30_security-misc.conf
sudo sed -i 's/#[[:space:]]*install msr/install msr/g' /mnt/etc/modprobe.d/30_security-misc.conf
if [ "${install_mode}" != 'server' ]; then
    sudo sed -i 's/#[[:space:]]*install bluetooth/install bluetooth/g' /mnt/etc/modprobe.d/30_security-misc.conf
    sudo sed -i 's/#[[:space:]]*install btusb/install btusb/g' /mnt/etc/modprobe.d/30_security-misc.conf
fi
unpriv curl https://raw.githubusercontent.com/Kicksecure/security-misc/master/usr/lib/sysctl.d/990-security-misc.conf | tee /mnt/etc/sysctl.d/990-security-misc.conf
sed -i 's/kernel\.yama\.ptrace_scope[[:space:]]*=.*/kernel.yama.ptrace_scope=3/g' /mnt/etc/sysctl.d/990-security-misc.conf
unpriv curl https://raw.githubusercontent.com/Kicksecure/security-misc/master/etc/sysctl.d/30_silent-kernel-printk.conf | tee /mnt/etc/sysctl.d/30_silent-kernel-printk.conf
unpriv curl https://raw.githubusercontent.com/Kicksecure/security-misc/master/etc/sysctl.d/30_security-misc_kexec-disable.conf | tee /mnt/etc/sysctl.d/30_security-misc_kexec-disable.conf

## Setup NTS
unpriv curl https://raw.githubusercontent.com/GrapheneOS/infrastructure/main/chrony.conf | tee /mnt/etc/chrony.conf
unpriv curl https://raw.githubusercontent.com/TommyTran732/Linux-Setup-Scripts/main/etc/sysconfig/chronyd | tee /etc/sysconfig/chronyd

## Remove nullok from system-auth
sed -i 's/nullok//g' /mnt/etc/pam.d/system-auth

## Disable coredump
unpriv curl https://raw.githubusercontent.com/TommyTran732/Linux-Setup-Scripts/main/etc/security/limits.d/30-disable-coredump.conf | tee /mnt/etc/security/limits.d/30-disable-coredump.conf

## ZRAM configuration
unpriv curl https://raw.githubusercontent.com/TommyTran732/Linux-Setup-Scripts/main/etc/systemd/zram-generator.conf | tee /mnt/etc/systemd/zram-generator.conf

## Setup Networking

if [ "${install_mode}" = "desktop" ]; then
unpriv curl https://raw.githubusercontent.com/TommyTran732/Linux-Setup-Scripts/main/etc/NetworkManager/conf.d/00-macrandomize.conf | tee /mnt/etc/NetworkManager/conf.d/00-macrandomize.conf
unpriv curl https://raw.githubusercontent.com/TommyTran732/Linux-Setup-Scripts/main/etc/NetworkManager/conf.d/01-transient-hostname.conf | tee /mnt/etc/NetworkManager/conf.d/01-transient-hostname.conf
fi

unpriv curl https://gitlab.com/divested/brace/-/raw/master/brace/usr/lib/systemd/system/NetworkManager.service.d/99-brace.conf | tee /mnt/etc/systemd/system/NetworkManager.service.d/99-brace.conf

## Configuring the system.
arch-chroot /mnt /bin/bash -e <<EOF

    # Setting up timezone.
    # Temporarily hardcoding here
    ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime &>/dev/null

    # Setting up clock.
    hwclock --systohc

    # Generating locales.my keys aren't even on
    echo "Generating locales."
    locale-gen

    # Create SecureBoot keys. This isn't strictly necessary, but certain things like linux-hardened preset expects it and mkinitcpio will fail without it, sooo...
    sbctl create-keys

    # Generating a new initramfs.
    echo "Creating a new initramfs."
    chmod 600 /boot/initramfs-linux*
    mkinitcpio -P

    # Installing GRUB.
    echo "Installing GRUB on /boot."
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --modules="normal test efi_gop efi_uga search echo linux all_video gfxmenu gfxterm_background gfxterm_menu gfxterm loadenv configfile gzio part_gpt cryptodisk luks gcry_rijndael gcry_sha256 btrfs" --disable-shim-lock

    # Creating grub config file.
    echo "Creating GRUB config file."
    grub-mkconfig -o /boot/grub/grub.cfg

    # Adding user with sudo privilege
    if [ -n "$username" ]; then
        echo "Adding $username with root privilege."
        useradd -m $username
        usermod -aG wheel $username
    fi

    # Snapper configuration
    umount /.snapshots
    rm -r /.snapshots
    snapper --no-dbus -c root create-config /
    btrfs subvolume delete /.snapshots
    mkdir /.snapshots
    mount -a
    chmod 750 /.snapshots
EOF

## Set user password.
[ -n "$username" ] && echo "Setting user password for ${username}." && echo -e "${user_password}\n${user_password}" | arch-chroot /mnt passwd "$username" &>/dev/null

## Give wheel user sudo access.
sed -i 's/# \(%wheel ALL=(ALL\(:ALL\|\)) ALL\)/\1/g' /mnt/etc/sudoers

## Enabling openssh server
if [ "${install_mode}" = 'server' ]; then
    systemctl enable sshd --root=/mnt
fi

## Enable services
systemctl enable apparmor --root=/mnt
systemctl enable chronyd --root=/mnt
systemctl enable firewalld --root=/mnt
systemctl enable fstrim.timer --root=/mnt
systemctl enable gdm.service --root=/mnt
systemctl enable grub-btrfsd.service --root=/mnt
systemctl enable NetworkManager --root=/mnt
systemctl enable reflector.timer --root=/mnt
systemctl enable snapper-timeline.timer --root=/mnt
systemctl enable snapper-cleanup.timer --root=/mnt
systemctl enable systemd-oomd --root=/mnt
systemctl disable systemd-timesyncd --root=/mnt

## Set umask to 077.
sudo sed -i 's/^UMASK.*/UMASK 077/g' /mnt/etc/login.defs
sudo sed -i 's/^HOME_MODE/#HOME_MODE/g' /mnt/etc/login.defs
sudo sed -i 's/^USERGROUPS_ENAB.*/USERGROUPS_ENAB no/g' /mnt/etc/login.defs
sudo sed -i 's/umask 022/umask 077/g' /mnt/etc/bash.bashrc

# Finish up
echo "Done, you may now wish to reboot (further changes can be done by chrooting into /mnt)."
exit