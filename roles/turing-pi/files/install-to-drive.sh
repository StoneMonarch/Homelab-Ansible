#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

wait_loopdev() {
    local loop="$1"
    local seconds="$2"

    until test $((seconds--)) -eq 0 -o -b "${loop}"; do sleep 1; done

    ((++seconds))

    ls -l "${loop}" &> /dev/null
}

if [ "$(id -u)" -ne 0 ]; then
    echo "$0: please run this command as root or with sudo"
    exit 1
fi

if test $# -ne 1; then
    echo "usage: $0 /dev/mmcblk0"
    exit 1
fi

disk=$1

if test ! -b "${disk}"; then
    echo "$0: block device '${disk}' not found"
    exit 1
fi

if [[ "/dev/$(lsblk -no pkname "$(findmnt -n -o SOURCE /)")" == "${disk}" ]]; then
    echo "$0: invalid block device '${disk}'"
    exit 1
fi

echo "This script will install the currently running system onto ${disk}."

# Ensure disk is not mounted
mount_point=/tmp/mnt
umount -lf "${disk}"* 2> /dev/null || true
umount -lf ${mount_point}/* 2> /dev/null || true
mkdir -p ${mount_point}

echo -e "\nCreating partition table for ${disk}."

# Setup partition table
dd if=/dev/zero of="${disk}" count=4096 bs=512 2> /dev/null
parted --script "${disk}" \
mklabel gpt \
mkpart primary fat16 16MiB 528MiB \
mkpart primary ext4 528MiB 100% 2> /dev/null

# Create partitions
{
    echo "t"
    echo "1"
    echo "BC13C2FF-59E6-4262-A352-B275FD6F7172"
    echo "t"
    echo "2"
    echo "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    echo "w"
} | fdisk "${disk}" &> /dev/null || true

partprobe "${disk}" 1> /dev/null

partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"

sleep 1

wait_loopdev "${disk}${partition_char}2" 60 || {
    echo "$0: failure to create '${disk}${partition_char}1' in time"
    exit 1
}

sleep 1

wait_loopdev "${disk}${partition_char}1" 60 || {
    echo "$0: failure to create '${disk}${partition_char}1' in time"
    exit 1
}

sleep 1

echo -e "Creating filesystem on partitions ${disk}${partition_char}1 and ${disk}${partition_char}2.\n"

# Generate random uuid for bootfs
boot_uuid=$(uuidgen | head -c8)

# Generate random uuid for rootfs
root_uuid=$(uuidgen)

# Create filesystems on partitions
mkfs.vfat -i "${boot_uuid}" -F32 -n system-boot "${disk}${partition_char}1" &> /dev/null
dd if=/dev/zero of="${disk}${partition_char}2" bs=1KB count=10 2> /dev/null
mkfs.ext4 -U "${root_uuid}" -L writable "${disk}${partition_char}2" &> /dev/null

# Write the bootloader
if [ -f /usr/lib/u-boot/u-boot-rockchip.bin ]; then
    dd if=/usr/lib/u-boot/u-boot-rockchip.bin of="${disk}" seek=1 bs=32k conv=fsync 2> /dev/null
else
    dd if=/usr/lib/u-boot/idbloader.img of="${disk}" seek=64 conv=notrunc 2> /dev/null
    dd if=/usr/lib/u-boot/u-boot.itb of="${disk}" seek=16384 conv=notrunc 2> /dev/null
fi

# Read partition table again
blockdev --rereadpt "${disk}"

# Ensure boot partition is mounted
root_partition_char=$(lsblk -no pkname "$(findmnt -n -o SOURCE /)")
if [[ $(findmnt -M /boot/firmware/ -n -o SOURCE) != "/dev/$(lsblk -no pkname "$(findmnt -n -o SOURCE /)")$(if [[ ${root_partition_char: -1} == [0-9] ]]; then echo p; fi)1" ]]; then
    mkdir -p /boot/firmware/
    umount -lf /boot/firmware/ 2> /dev/null || true
    mount "/dev/$(lsblk -no pkname "$(findmnt -n -o SOURCE /)")$(if [[ ${root_partition_char: -1} == [0-9] ]]; then echo p; fi)1" /boot/firmware/
fi

# Mount partitions
mkdir -p ${mount_point}/{system-boot,writable}
mount "${disk}${partition_char}1" ${mount_point}/system-boot/
mount "${disk}${partition_char}2" ${mount_point}/writable/

echo "Counting files..."
count=$(rsync -xahvrltDn --delete --stats /boot/firmware/* ${mount_point}/system-boot/ | grep "Number of files:" | awk '{print $4}' | tr -d '.,')

# Figure out if we have enough free disk space to copy the bootfs
usage=$(df -BM | grep ^/dev | head -2 | tail -n 1 | awk '{print $3}' | tr -cd '[0-9]. \n')
dest=$(df -BM | grep ^/dev | grep ${mount_point}/system-boot | awk '{print $4}' | tr -cd '[0-9]. \n')
if [[ ${usage} -gt ${dest} ]]; then
    echo -e "\nPartition ${disk}${partition_char}1 is too small.\nNeeded: ${usage} MB Avaliable: ${dest} MB"
    umount -lf "${disk}${partition_char}1" 2> /dev/null || true
    umount -lf "${disk}${partition_char}2" 2> /dev/null || true
    exit 1
fi

echo "Transferring $count files (${usage} MB) from the bootfs to ${disk}${partition_char}1. Please wait!"
rsync -xavrltD --delete /boot/firmware/* ${mount_point}/system-boot/ >/dev/null 2>&1

# Run rsync again to catch outstanding changes
echo "Cleaning up..."
rsync -xavrltD --delete /boot/firmware/* ${mount_point}/system-boot/ >/dev/null 2>&1

echo -e "\nCounting files..."
count=$(rsync -xahvrltDn --delete --stats / ${mount_point}/writable/ | grep "Number of files:" | awk '{print $4}' | tr -d '.,')

# Figure out if we have enough free disk space to copy the rootfs
usage=$(df -BM | grep ^/dev | head -1 | awk '{print $3}' | tr -cd '[0-9]. \n')
dest=$(df -BM | grep ^/dev | grep ${mount_point}/writable | awk '{print $4}' | tr -cd '[0-9]. \n')
if [[ ${usage} -gt ${dest} ]]; then
    echo -e "\nPartition ${disk}${partition_char}2 is too small.\nNeeded: ${usage} MB Avaliable: ${dest} MB"
    umount -lf "${disk}${partition_char}1" 2> /dev/null || true
    umount -lf "${disk}${partition_char}2" 2> /dev/null || true
    exit 1
fi

echo "Transferring $count files (${usage} MB) from the rootfs to ${disk}${partition_char}2. Please wait!"
rsync -xavrltD --delete / ${mount_point}/writable/ >/dev/null 2>&1

# Run rsync again to catch outstanding changes
echo -e "Cleaning up..."
rsync -xavrltD --delete / ${mount_point}/writable/ >/dev/null 2>&1

# Update root uuid for kernel cmdline
sed -i "s/^\(\s*bootargs=\s*\)root=UUID=[A-Fa-f0-9-]*/\1root=UUID=${root_uuid}/" ${mount_point}/system-boot/ubuntuEnv.txt

# Update fstab entries
boot_uuid="${boot_uuid:0:4}-${boot_uuid:4:4}"
mkdir -p ${mount_point}/writable/boot/firmware
cat > ${mount_point}/writable/etc/fstab << EOF
# <file system>     <mount point>  <type>  <options>   <dump>  <fsck>
UUID=${boot_uuid^^} /boot/firmware vfat    defaults    0       2
UUID=${root_uuid,,} /              ext4    defaults,x-systemd.growfs    0       1
EOF

# Let systemd create machine id on first boot
rm -f ${mount_point}/writable/var/lib/dbus/machine-id
true > ${mount_point}/writable/etc/machine-id

sync --file-system
sync

sleep 2

echo -e "\nDone!"

# Umount partitions
umount "${disk}${partition_char}1"
umount "${disk}${partition_char}2"