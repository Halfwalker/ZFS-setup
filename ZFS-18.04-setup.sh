#!/bin/bash

# Shortened url direct to script : https://shorturl.at/AFHV2

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# No magenta overrides for whiptail dialogs please
export NEWT_COLORS="none"

# If there's a local apt-cacher-ng setup, use for speed
PROXY="http://192.168.2.104:3142/"
PROXY=$(whiptail --inputbox "Enter an apt proxy. Cancel or hit <esc> for no proxy" --title "APT proxy setup" 8 70 $(echo $PROXY) 3>&1 1>&2 2>&3)
RET=${?}
(( RET )) && PROXY=
if [ ${PROXY} ]; then
    export http_proxy=${PROXY}
    export ftp_proxy=${PROXY}
    # This is for apt-get
    echo 'Acquire::http::proxy "${PROXY}";' > /etc/apt/apt.conf.d/03proxy
fi # PROXY

# Get userid and full name of main user
USERNAME=datto
UCOMMENT="Full name goes here"
USERINFO=$(whiptail --inputbox "Enter username (login id) and full name of user\n\nlogin full name here\n|---| |------------ - - -  -  -" --title "User information" 11 70 "$(echo $USERNAME $UCOMMENT)" 3>&1 1>&2 2>&3)
USERNAME=$(echo $USERINFO | cut -d' ' -f1)
UCOMMENT=$(echo $USERINFO | cut -d' ' -f2-)

# Get password, confirm and loop until confirmation OK
DONE=false
until ${DONE} ; do
    PW1=$(whiptail --passwordbox "Please enter a password for user $(echo $USERNAME)" 8 70 --title "User password" 3>&1 1>&2 2>&3)
    PW2=$(whiptail --passwordbox "Please re-enter the password to confirm" 8 70 --title "User password confirmation" 3>&1 1>&2 2>&3)
    [ "$PW1" = "$PW2" ] && DONE=true
done
UPASSWORD="$PW1"

# Hostname - cancel or blank name will exit
HOSTNAME=dattotest
HOSTNAME=$(whiptail --inputbox "Enter hostname to be used for new system" --title "Hostname for new system" 8 70 $(echo $HOSTNAME) 3>&1 1>&2 2>&3)
RET=${?}
(( RET )) && HOSTNAME=
if [ ! ${HOSTNAME} ]; then
    echo "Must have a hostname" 
    exit 1
fi

# Set main disk here - be sure to include the FULL path
# Get list of disks, ask user which one to install to
# Ignore cdrom etc.
readarray -t disks <<< $(ls -l /dev/disk/by-id | egrep -v '(CDROM|CDRW|-ROM|CDDVD|-part|md-|dm-|wwn-)' | sort -t '/' -k3 | tr -s " " | cut -d' ' -f9 | sed '/^$/d')

TMPFILE=$(mktemp)
whiptail --title "List of disks" --radiolist --noitem \
    "Choose disk to install to" 20 70 12 \
    $( for disk in $(seq 0 $(( ${#disks[@]}-1)) ) ; do echo "${disks[${disk}]}" OFF ; done) 2> "${TMPFILE}"
read -r DISK < ${TMPFILE}
if [ "${DISK}" = "" ] ; then
    echo "Must choose disk"
    exit 1
fi
DISK="/dev/disk/by-id/${DISK}"

DESKTOP=n
UEFI=n
LUKS=n
HWE=n
HIBERNATE=n
# Set basic options for install
whiptail --title "Set options to install" --separate-output --checklist "Choose options" 20 65 4 \
    DESKTOP "Install full Ubuntu desktop" OFF \
    UEFI "Enable UEFI grub install" $( [ -d /sys/firmware/efi ] && echo ON || echo OFF ) \
    LUKS "Enable full disk encryption" OFF \
    HWE "Install Hardware Enablement kernel" ON \
    HIBERNATE "Enable swap partition\n for hibernation" OFF 2>"${TMPFILE}"
cat "${TMPFILE}"
while read -r TODO ; do
    OPTION="${TODO}"
    eval "${TODO}"='y'
done < "${TMPFILE}"

# We check /sys/power/state - if no "disk" in there, then HIBERNATE is disabled
cat /sys/power/state | fgrep disk
if [ ${?} -ne 0 ] ; then
    whiptail --title "Hibernate not available" --msgbox "The /sys/power/state file does not contain 'disk', so hibernate to disk is not available" 8 70
    HIBERNATE=n
fi

# If LUKS enabled, need a passphrase
if [ "${LUKS}" = "y" ] ; then
    DONE=false
    until ${DONE} ; do
        PW1=$(whiptail --passwordbox "Please enter a good long LUKS encryption passphrase" 8 70 --title "LUKS passphrase" 3>&1 1>&2 2>&3)
        PW2=$(whiptail --passwordbox "Please re-enter the LUKS encryption passphrase" 8 70 --title "LUKS passphrase confirmation" 3>&1 1>&2 2>&3)
        [ "$PW1" = "$PW2" ] && DONE=true
    done
    PASSPHRASE="$PW1"
fi

# Swap size - if HIBERNATE enabled then this will be an actual disk partition.  
# If LUKS defined then partition will be encrypted.  If SIZE_SWAP is not
# defined here, then will be calculated to accomodate memory size (plus fudge factor).
MEMTOTAL=$(cat /proc/meminfo | fgrep MemTotal | tr -s ' ' | cut -d' ' -f2)
SIZE_SWAP=$(( (${MEMTOTAL} + 10) / 1024 ))
SIZE_SWAP=$(whiptail --inputbox "If HIBERNATE enabled then this will be a disk partition otherwise it will be a regular ZFS dataset. If LUKS enabled then the partition will be encrypted.\nIf SWAP size not set here (left blank), then it will be calculated to accomodate memory size.\n\nSize of swap space in megabytes (default is calculated value)" \
    --title "SWAP size" 18 70 $(echo $SIZE_SWAP) 3>&1 1>&2 2>&3)

# Use zswap compressed page cache in front of swap ? https://wiki.archlinux.org/index.php/Zswap
# Only used for swap partition (encrypted or not)
USE_ZSWAP="\"zswap.enabled=1 zswap.compressor=lz4 zswap.max_pool_percent=25\""

# Suite to install - xenial bionic
SUITE=$(whiptail --title "Select Ubuntu distribtion" --radiolist "Choose distro" 20 70 2 \
    xenial "16.04 Xenial" OFF \
    bionic "18.04 Bionic" ON 3>&1 1>&2 2>&3)

case ${SUITE} in
	bionic)
        SUITENUM="18.04"
        SUITE_EXTRAS="netplan.io expect"
        SUITE_BOOTSTRAP="wget,whois,rsync,gdisk,netplan.io"
        ;;
    xenial | loki | serena)
        SUITENUM="16.04"
        SUITE_EXTRAS="openssl-blacklist openssh-blacklist openssh-blacklist-extra bootlogd"
        SUITE_BOOTSTRAP="wget,whois,rsync,gdisk"
        ;;
    *)
        SUITENUM="16.04"
        SUITE_EXTRAS="openssl-blacklist openssh-blacklist openssh-blacklist-extra bootlogd"
        SUITE_BOOTSTRAP="wget,whois,rsync,gdisk"
        ;;
esac

# Install HWE packages - set to blank or to "-hwe-18.04"
# Gets tacked on to various packages below
if [ "${HWE}" = "y" ] ; then
    HWE="-hwe-${SUITENUM}"
fi

whiptail --title "Summary of install options" --msgbox "These are the options we're about to install with :\n\n \
    Proxy $([ ${PROXY} ] && echo ${PROXY} || echo None)\n \
    $(echo $SUITE $SUITENUM) $([ ${HWE} ] && echo WITH || echo without) $(echo hwe kernel ${HWE})\n \
    Disk $(echo $DISK | sed 's!/dev/disk/by-id/!!')\n \
    Hostname $(echo $HOSTNAME)\n \
    User $(echo $USERNAME $UCOMMENT)\n\n \
    DESKTOP   = $(echo $DESKTOP)  : Install full Ubuntu desktop\n \
    UEFI      = $(echo $UEFI)  : Enable UEFI\n \
    LUKS      = $(echo $LUKS)  : Enable LUKS disk encryption\n \
    HIBERNATE = $(echo $HIBERNATE)  : Enable SWAP disk partition for hibernation\n \
    Swap size = $(echo $SIZE_SWAP)M\n" \
    25 70

# Log everything we do
rm -f /root/ZFS-setup.log
exec > >(tee -a "/root/ZFS-setup.log") 2>&1

# Clear disk *before* install zfs
sgdisk --zap-all ${DISK}
sgdisk --clear ${DISK}

apt-get update
apt-get --no-install-recommends --yes install software-properties-common
apt-add-repository universe
apt-get --no-install-recommends --yes install openssh-server debootstrap gdisk zfs-initramfs

# Legacy (BIOS) booting
sgdisk -a1 -n1:24K:+1000K -c1:"GRUB" -t1:EF02 ${DISK}

# UEFI booting
sgdisk     -n2:1M:+512M   -c2:"UEFI" -t2:EF00 ${DISK}

# boot pool
sgdisk     -n3:0:+1000M   -c3:"BOOT" -t3:BF01 ${DISK}

# For laptop hibernate need swap partition, encrypted or not
if [ "${HIBERNATE}" = "y" ] ; then
    if [ ${LUKS} = "y" ] ; then
        sgdisk -n4:0:+${SIZE_SWAP}M -c4:"SWAP" -t4:8300 ${DISK}
    else
        sgdisk -n4:0:+${SIZE_SWAP}M -c4:"SWAP" -t4:8200 ${DISK}
    fi # LUKS
fi # HIBERNATE

# Main data partition for root
if [ ${LUKS} = "y" ] ; then
# Encrypted
    sgdisk -n5:0:0        -c5:"ZFS"  -t5:8300 ${DISK}
    apt-get --no-install-recommends --yes install cryptsetup
else
# Unencrypted
    sgdisk -n5:0:0        -c5:"ZFS"  -t5:BF01 ${DISK}
fi #LUKS

# Have to wait a bit for the partitions to actually show up
echo "Wait for partition info to settle out"
sleep 5

# Create boot pool - only uses features supported by grub
# userobj_accounting not supported in 0.6.x in 16.04
echo "Creating boot pool bpool"
zpool create -f -o ashift=12 -d \
      -o feature@async_destroy=enabled \
      -o feature@bookmarks=enabled \
      -o feature@embedded_data=enabled \
      -o feature@empty_bpobj=enabled \
      -o feature@enabled_txg=enabled \
      -o feature@extensible_dataset=enabled \
      -o feature@filesystem_limits=enabled \
      -o feature@hole_birth=enabled \
      -o feature@userobj_accounting=enabled \
      -o feature@large_blocks=enabled \
      -o feature@lz4_compress=enabled \
      -o feature@spacemap_histogram=enabled \
      -O acltype=posixacl -O canmount=off -O compression=lz4 -O devices=off \
      -O normalization=formD -O relatime=on -O xattr=sa \
      -O mountpoint=/ -R /mnt \
      bpool ${DISK}-part3

# Create root pool
if [ ${LUKS} = "y" ] ; then
# Encrypted
    echo "Encrypting root ZFS"
    echo ${PASSPHRASE} | cryptsetup luksFormat --type luks2 -c aes-xts-plain64 -s 512 -h sha256 ${DISK}-part5
    echo ${PASSPHRASE} | cryptsetup luksOpen ${DISK}-part5 root_crypt
    
    echo "Creating root pool rpool"
    # dnodesize not supported in 0.6.x in 16.04
    zpool create -f -o ashift=12 \
         -O acltype=posixacl -O canmount=off -O compression=lz4 \
         -O atime=off \
         -O dnodesize=auto \
         -O normalization=formD -O relatime=on -O xattr=sa \
         -O mountpoint=/ -R /mnt \
         rpool /dev/mapper/root_crypt
else
# Unencrypted
echo "Creating root pool rpool"
# dnodesize not supported in 0.6.x in 16.04
zpool create -f -o ashift=12 \
      -O acltype=posixacl -O canmount=off -O compression=lz4 \
      -O atime=off \
      -O dnodesize=auto \
      -O normalization=formD -O relatime=on -O xattr=sa \
      -O mountpoint=/ -R /mnt \
      rpool ${DISK}-part5
fi # LUKS

# Create SWAP volume
if [ ${HIBERNATE} = "y" ] ; then
    if [ ${LUKS} = "y" ] ; then
        echo "Encrypting swap partition size ${SIZE_SWAP}M"
        echo ${PASSPHRASE} | cryptsetup luksFormat --type luks2 -c aes-xts-plain64 -s 512 -h sha256 ${DISK}-part4
        echo ${PASSPHRASE} | cryptsetup luksOpen ${DISK}-part4 swap_crypt
        mkswap -f /dev/mapper/swap_crypt

        # Get derived key from swap to insert into encrypted root partition
        # swap must be opened 1st to enable resume from hibernation
        /lib/cryptsetup/scripts/decrypt_derived swap_crypt > /tmp/key
        echo ${PASSPHRASE} | cryptsetup luksAddKey ${DISK}-part5 /tmp/key
    else
        mkswap -f ${DISK}-part4
    fi # LUKS
else
    echo "Creating swap zfs dataset size ${SIZE_SWAP}M"
    zfs create -V ${SIZE_SWAP}M -b $(getconf PAGESIZE) -o compression=zle \
      -o logbias=throughput -o sync=always \
      -o primarycache=metadata -o secondarycache=none \
      -o com.sun:auto-snapshot=false rpool/swap
    mkswap -f /dev/zvol/rpool/swap
fi #HIBERNATE


# Main filesystem datasets
echo "Creating main zfs datasets"
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu
zfs mount rpool/ROOT/ubuntu
zfs create -o canmount=off -o mountpoint=none bpool/BOOT
zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/ubuntu
zfs mount bpool/BOOT/ubuntu

# zfs create rpool/home and main user home dataset
zfs create -o canmount=off -o mountpoint=none -o compression=lz4 -o atime=off rpool/home
zfs create -o canmount=on -o mountpoint=/home/${USERNAME} rpool/home/${USERNAME}

# Show what we got before installing
zfs list -t all
df -h

# Install basic system
echo "debootstrap to build initial system"
debootstrap ${SUITE} /mnt
zfs set devices=off rpool

# If this system will use Docker (which manages its own datasets & snapshots):
zfs create -o com.sun:auto-snapshot=false -o mountpoint=/var/lib/docker rpool/docker

echo ${HOSTNAME} > /mnt/etc/hostname
echo "127.0.1.1  ${HOSTNAME}" >> /mnt/etc/hosts

if [ ${PROXY} ]; then
    # This is for apt-get
    echo 'Acquire::http::proxy "${PROXY}";' > /mnt/etc/apt/apt.conf.d/03proxy
fi # PROXY


# Set up networking for netplan or interfaces
# renderer: networkd is for text mode only, use NetworkManager for gnome
if [ ${SUITE} == bionic ] ; then
cat >> /mnt/etc/netplan/01_netcfg.yaml << __EOF__
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      optional: true
__EOF__
else
cat >> /mnt/etc/network/interfaces << __EOF__
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet dhcp
__EOF__
fi

# sources
cat > /mnt/etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu ${SUITE} main universe multiverse
deb-src http://archive.ubuntu.com/ubuntu ${SUITE} main universe multiverse

deb http://security.ubuntu.com/ubuntu ${SUITE}-security main universe multiverse
deb-src http://security.ubuntu.com/ubuntu ${SUITE}-security main universe multiverse

deb http://archive.ubuntu.com/ubuntu ${SUITE}-updates main universe multiverse
deb-src http://archive.ubuntu.com/ubuntu ${SUITE}-updates main universe multiverse
EOF

# Bind mount virtual filesystem, create Setup.sh, then chroot
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
# Make the mounts rslaves to make umounting later cleaner
mount –make-rslave /mnt/dev
mount –make-rslave /mnt/proc
mount –make-rslave /mnt/sys

echo "Creating Setup.sh in new system for chroot"
cat > /mnt/root/Setup.sh << __EOF__
#!/bin/bash

export DISK=${DISK}
export USERNAME=${USERNAME}
export UPASSWORD="${UPASSWORD}"
export UCOMMENT="${UCOMMENT}"
export LUKS=${LUKS}
export UEFI=${UEFI}
export PROXY=${PROXY}
export HWE=${HWE}
export DESKTOP=${DESKTOP}
export HIBERNATE=${HIBERNATE}
__EOF__

cat >> /mnt/root/Setup.sh << '__EOF__'
# Setup inside chroot
set -x

ln -s /proc/self/mounts /etc/mtab
apt-get update

# Preseed a few things
cat > /tmp/selections << EOFPRE
# tzdata
tzdata  tzdata/Zones/US                         select Eastern
tzdata  tzdata/Zones/America                    select New_York
tzdata  tzdata/Areas                            select US
grub-pc         grub-pc/install_devices_empty   select true
grub-pc         grub-pc/install_devices         select
grub-installer/bootdev string ${DISK}
grub-pc grub-pc/install_devices string ${DISK}
EOFPRE

# Set up locale - must set langlocale variable (defaults to en_US)
cat > /etc/default/locale << EOFLOCALE
LC_ALL=en_US.UTF-8
LANG=en_US.UTF-8
LANGUAGE=en_US:en
EOFLOCALE
cat /etc/default/locale >> /etc/environment
cat /tmp/selections | debconf-set-selections
locale-gen --purge "en_US.UTF-8"
# dpkg-reconfigure locales
echo "America/New_York" > /etc/timezone
ln -fs /usr/share/zoneinfo/US/Eastern /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Install ZFS
apt-get --yes --no-install-recommends install linux-generic${HWE}
apt-get --yes install zfs-initramfs

# Set up /etc/crypttab
if [ "${LUKS}" = "y" ] ; then
# Encrypted
    apt-get --yes install cryptsetup
    if [ ${HIBERNATE} = "y" ] ; then
        # swap must be opened 1st to enable resume from hibernation
        echo "swap_crypt UUID=$(blkid -s UUID -o value ${DISK}-part4) none luks,discard,initramfs" > /etc/crypttab
        echo "root_crypt UUID=$(blkid -s UUID -o value ${DISK}-part5) swap_crypt luks,discard,initramfs,keyscript=/lib/cryptsetup/scripts/decrypt_derived" >> /etc/crypttab
    else
        echo "root_crypt UUID=$(blkid -s UUID -o value ${DISK}-part5) none luks,discard,initramfs" > /etc/crypttab
    fi # HIBERNATE
fi # LUKS

if [ "${UEFI}" = "y" ] ; then
# Grub for UEFI
    apt-get --yes install dosfstools
    mkdosfs -F 32 -s 1 -n EFI ${DISK}-part2
    mkdir /boot/efi
    echo PARTUUID=$(blkid -s PARTUUID -o value \
          ${DISK}-part2) \
          /boot/efi vfat nofail,x-systemd.device-timeout=1 0 1 >> /etc/fstab
    mount /boot/efi
    apt-get install --yes grub-efi-amd64-signed shim-signed
fi # UEFI
    # Grub for legacy BIOS
apt-get --yes install grub-pc

# Install basic packages
# jmespath stuff needed for ansible json filters - have to be installed *before*
# running ansible - can't install via a task since that ansible run won't see
# the newly installed jmes stuff
apt-get --no-install-recommends --yes install expect most vim-nox rsync whois gdisk \
    openssh-server python3-jmespath python-jmespath

# Enable importing bpool
cat >> /etc/systemd/system/zfs-import-bpool.service << 'EOF'
[Unit]
    DefaultDependencies=no
    Before=zfs-import-scan.service
    Before=zfs-import-cache.service
    
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/sbin/zpool import -N -o cachefile=none bpool
    
    [Install]
    WantedBy=zfs-import.target
EOF
systemctl enable zfs-import-bpool.service

# Setup system groups
addgroup --system lpadmin
addgroup --system sambashare

# Grub installation
# Verify ZFS boot is seen
echo "${DASHES}"
echo "Please verify that ZFS shows up below for grub-probe"
grub-probe /boot
read -t 5 QUIT

# Update initrd
update-initramfs -u -k all

# Ensure grub supports ZFS and reset timeouts to 5s
sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 root=ZFS=rpool\/ROOT\/ubuntu"/' /etc/default/grub
sed -i 's/GRUB_TIMEOUT_STYLE=hidden/# GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
sed -i 's/#GRUB_TERMINAL.*/GRUB_TERMINAL=console/' /etc/default/grub
cat >> /etc/default/grub << EOF

# Ensure both timeouts are 5s
GRUB_RECOVERFAIL_TIMEOUT=5

# Sometimes os_prober fails with device busy. Only really needed for multi-OS
GRUB_DISABLE_OS_PROBER=true
EOF

# Using a swap partition ?
if [ ${HIBERNATE} = "y" ] ; then
    if [ "${LUKS}" = "y" ] ; then
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash resume=\/dev\/mapper\/swap_crypt ${USE_ZSWAP}\"/" /etc/default/grub
        echo "/dev/mapper/swap_crypt none swap discard,sw 0 0" >> /etc/fstab
        echo "RESUME=/dev/mapper/swap_crypt" > /etc/initramfs-tools/conf.d/resume
    else
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash resume=UUID=$(blkid -s UUID -o value ${DISK}-part4) ${USE_ZSWAP}\"/" /etc/default/grub
        echo "UUID=$(blkid -s UUID -o value ${DISK}-part4) none swap discard,sw 0 0" >> /etc/fstab
        echo "RESUME=UUID=$(blkid -s UUID -o value ${DISK}-part4)" > /etc/initramfs-tools/conf.d/resume
    fi # LUKS
else
    # No swap partition
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
    echo "/dev/zvol/rpool/swap none swap discard,sw 0 0" >> /etc/fstab
    echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume
fi # HIBERNATE

# Update boot config
update-grub

# Install bootloader grub for either UEFI or legacy bios
if [ "${UEFI}" = "y" ] ; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi \
      --bootloader-id=ubuntu --recheck --no-floppy ${DISK}
    umount /boot/efi
fi # UEFI
    grub-install --target=i386-pc ${DISK}

apt-get --yes dist-upgrade

# Install acpi support
if [ -d /proc/acpi ] ; then
    apt-get --yes install acpi acpid
    service acpid stop
fi # acpi

# Create user
useradd -c "${UCOMMENT}" -p $(echo "${UPASSWORD}" | mkpasswd -m sha-512 --stdin) -M --home-dir /home/${USERNAME} --user-group --groups adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo --shell /bin/bash ${USERNAME}
# Since /etc/skel/* files aren't copied, have to do it manually
rsync -a /etc/skel/ /home/${USERNAME}
chown -R ${USERNAME}.${USERNAME} /home/${USERNAME}

# Allow read-only zfs commands with no sudo password
cat /etc/sudoers.d/zfs | sed -e 's/#//' > /etc/sudoers.d/zfsALLOW

# Install main ubuntu gnome desktop, plus maybe HWE packages
if [ "${DESKTOP}" = "y" ] ; then
    apt-get --yes install ubuntu-desktop xserver-xorg${HWE}
    
    # Ensure networking is handled by Gnome
    sed -i 's/networkd/NetworkManager/' /etc/netplan/01_netcfg.yaml
    
    # Enable hibernate in upower and logind if desktop is installed
    if [ -d /etc/polkit-1/localauthority/50-local.d ] ; then
    cat > /etc/polkit-1/localauthority/50-local.d/com.ubuntu.enable-hibernate.pkla << EOF
[Re-enable hibernate by default in upower]
Identity=unix-user:*
Action=org.freedesktop.upower.hibernate
ResultActive=yes

[Re-enable hibernate by default in logind]
Identity=unix-user:*
Action=org.freedesktop.login1.hibernate;org.freedesktop.login1.handle-hibernate-key;org.freedesktop.login1;org.freedesktop.login1.hibernate-multiple-sessions;org.freedesktop.login1.hibernate-ignore-inhibit
ResultActive=yes
EOF
    fi # Hibernate
fi # DESKTOP

update-grub
update-initramfs -c -k all

# Fix filesystem mount ordering
zfs set mountpoint=legacy bpool/BOOT/ubuntu
echo bpool/BOOT/ubuntu /boot zfs \
  nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0 >> /etc/fstab

# zfs set mountpoint=legacy rpool/var/log
# echo rpool/var/log /var/log zfs nodev,relatime 0 0 >> /etc/fstab
# 
# zfs set mountpoint=legacy rpool/var/spool
# echo rpool/var/spool /var/spool zfs nodev,relatime 0 0 >> /etc/fstab

# Create install snaps
zfs snapshot bpool/BOOT/ubuntu@base_install
zfs snapshot rpool/ROOT/ubuntu@base_install

# End of Setup.sh
__EOF__

chmod +x /mnt/root/Setup.sh

# chroot and set up system
chroot /mnt /bin/bash --login -c /root/Setup.sh

# Copy setup log
cp /root/ZFS-setup.log /mnt/home/${USERNAME}
zfs umount rpool/home/${USERNAME}

# Remove any lingering crash reports
rm -f /mnt/var/crash/*

umount /mnt/dev
umount /mnt/proc
umount /mnt/sys

# Back in livecd - unmount filesystems
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
zpool export -a


