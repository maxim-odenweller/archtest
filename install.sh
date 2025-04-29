#!/usr/bin/env bash

set -euo pipefail

# === CONFIG VARIABLES ===
while getopts "d:p:l:s:r:n:" option
do
  case "${option}" in
    d) DISK=${OPTARG};;
    p) PV_NAME=${OPTARG};;
    l) LVM_GROUP_NAME=${OPTARG};;
    s) SWAP_SPACE=${OPTARG};;
    r) ROOT_SPACE=${OPTARG};;
    n) HOSTN=${OPTARG};;
  esac
done

# Check if required variables are set
if [[ -z "${DISK:-}" || -z "${PV_NAME:-}" || -z "${LVM_GROUP_NAME:-}" || -z "${SWAP_SPACE:-}" || -z "${ROOT_SPACE:-}" || -z "${HOSTN:-}" ]]; then
  echo "Error: Missing required options."
  echo "Usage: $0 -d <disk> -p <pv_name> -l <lvm_group_name> -s <swap_space> -r <root_space>"
  exit 1
fi

# === WARN USER ===
echo "!!! WARNING: This will erase all data on $DISK !!!"
read -rp "Are you sure you want to continue? (yes/NO): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborting."
  exit 1
fi

# === PARTITION DISK ===
echo "Partitioning $DISK..."
parted --script "$DISK" mklabel gpt

# Create /boot partition
parted --script "$DISK" mkpart primary fat32 1MiB 1025MiB
parted --script "$DISK" set 1 esp on

# Create LVM partition
parted --script "$DISK" mkpart primary 1025MiB 100%

# === ENCRYPT LVM PARTITION ===
echo "Encrypting partition..."
cryptsetup luksFormat --batch-mode "${DISK}2"
cryptsetup open "${DISK}2" "$PV_NAME"

# === SETUP LVM ===
echo "Setting up LVM..."
pvcreate /dev/mapper/$PV_NAME
vgcreate "$LVM_GROUP_NAME" /dev/mapper/$PV_NAME

lvcreate -L "$SWAP_SPACE" -n swap "$LVM_GROUP_NAME"
lvcreate -L "$ROOT_SPACE" -n root "$LVM_GROUP_NAME"
lvcreate -l 100%FREE -n home "$LVM_GROUP_NAME"

# Optional: shrink home slightly
lvreduce -L -256M "/dev/$LVM_GROUP_NAME/home" --yes

# === FORMAT FILESYSTEMS ===
echo "Creating filesystems..."
mkfs.ext4 "/dev/$LVM_GROUP_NAME/root"
mkfs.ext4 "/dev/$LVM_GROUP_NAME/home"
mkswap "/dev/$LVM_GROUP_NAME/swap"

# Format /boot partition
mkfs.fat -F32 "${DISK}1"

# === MOUNT FILESYSTEMS ===
echo "Mounting filesystems..."
mount "/dev/$LVM_GROUP_NAME/root" /mnt
mkdir -p /mnt/home
mount "/dev/$LVM_GROUP_NAME/home" /mnt/home

swapon "/dev/$LVM_GROUP_NAME/swap"

mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

pacstrap -K /mnt base linux linux-firmware amd-ucode nvim man-db man-pages texinfo lvm2
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt

ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

sed -i '/^#de_DE.UTF-8/s/^#//g' /etc/locale.gen
locale-gen
echo "LANG=de_DE.UTF-8" > /etc/locale.conf
echo -e "KEYMAP=us\nFONT=latarcyrheb-sun32" > /etc/vconsole.conf
echo -e "$HOSTN" > /etc/hostname

systemctl start systemd-networkd
systemctl start systemd-resolved

sed -i '/^HOOKS=/c\HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/g' /etc/mkinitcpio.conf

echo "Set root password"
passwd

bootctl install

LUKS_UUID=$(cryptsetup luksUUID "${DISK}2")
cat <<EOF | tee /boot/loader/entries/arch.conf > /dev/null
title   Arch
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.name=${LUKS_UUID}=${LVM_GROUP_NAME} root=/dev/${LVM_GROUP_NAME}/root rw acpi_enforce_resources=lax
EOF
mkinitcpio -P


echo "Done"
