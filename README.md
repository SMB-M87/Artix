# Introduction

This guide documents my Artix Linux setup from bare metal to a fully usable, minimal desktop.  
The system is built around **full disk encryption (LUKS + LVM)**, **OpenRC**, and a **hardened kernel**, with a lightweight **DWM-based X11** environment.

The goal is not convenience or automation, but **control and reproducibility**. If something breaks, you should understand *why* it broke and how to fix it without reinstalling.

This guide is written primarily for my own reference, but it may also be useful if you:

- want a clean Artix install without systemd  
- care about disk encryption and predictable boot behavior  
- prefer minimal window managers over full desktop environments  
- want a system that does exactly what you tell it to  

Follow it carefully, adapt it to your hardware, and **double-check every destructive command**.

---

# Connectivity

## WiFi
If your device does not have supported WLAN or LAN drivers available during installation, use a **USB Wi-Fi adapter** or similar temporary network device. Once connected, follow the steps below to bring up networking using `connman`.

### WiFi Adapter (i.e. ath9k_htc)
```bash
# Load the Wi-Fi kernel module
modprobe ath9k_htc

# Verify the module is loaded properly
lsmod | grep ath9k_htc

# Expected Output
# ath9k_htc           73728  0
# ath9k_common        28672  1 ath9k_htc
# ath9k_hw           466944  2 ath9k_htc,ath9k_common
# ath                 32768  3 ath9k_htc,ath9k_common,ath9k_hw
# mac80211          1007616  1 ath9k_htc
# cfg80211           958464  3 ath9k_htc,mac80211,ath
# If no output is returned, the module is not loaded
```

### Enable WiFi in ConnMan
```bash
connmanctl enable wifi

# Expected Output
# wifi enabled

# Connect to ConnMan
connmanctl

# Scans for nearby wireless networks. This may take a few seconds and produces no output on success.
connmanctl> scan wifi

# Expected Output
# Scan completed for wifi

# Lists available networks.
connmanctl> services

# Enables the authentication agent so ConnMan can prompt for a passphrase.
connmanctl> agent on

# Expected Output
# Agent registered

# Connect to a specific service:
connmanctl> connect wifi_(tab)
connmanctl> enter further prompted credentials

# Quit connmanct (or use CTRL + C)
connmanctl> quit 
```

## Ethernet

If your system has a working Ethernet adapter and a cable is plugged in, **ConnMan usually enables it automatically**. No authentication or manual setup is required in most cases.

### Verify Ethernet Link
```bash
ip link

# Look for an interface such as eth0, enp0s3, or similar. A connected interface should show: state UP
# You can also check whether ConnMan sees the wired connection:
connmanctl services
# Expected Output
# *AO Wired                ethernet_XXXXXXXXXXXX_cable
# If you see Wired listed and marked as connected (*AO), networking is already active.

# If the cable is plugged in but no connection is established:
connmanctl enable ethernet

# Then reconnect ConnMan:
connmanctl
connmanctl> services
connmanctl> connect ethernet_XXXXXXXXXXXX_cable

# Successful connection will produce:
# Connected ethernet_XXXXXXXXXXXX_cable

# If no wired interface or service is shown, the kernel driver may not be loaded.
# Identify the Ethernet controller:
lspci | grep -i ethernet

# Example Output
# Ethernet controller: Intel Corporation Ethernet Connection (I219-V)

# Load common Ethernet drivers manually:
modprobe e1000e     # Intel
modprobe r8169      # Realtek
modprobe tg3        # Broadcom

# Recheck:
ip link
connmanctl services

# If ConnMan is unavailable or malfunctioning, you can bring up Ethernet manually using dhcpcd: (Replace eth0 with the correct interface name)
ip link set eth0 up
dhcpcd eth0
```

## Verify Connectivity
```
ping -c 3 1.1.1.1
ping -c 3 github.com
```

## Time Synchronization

Once network connectivity is confirmed (wired or wireless), start NTP:
```bash
rc-service ntpd start

# Expected Output
# ntpd			| * Starting OpenNTPD ...
```

This ensures correct system time for package management and cryptographic operations.

---

# Disk Partitioning

In order to manipulate disk partitions, the ISO image (live CD) comes with `cfdisk`.  
However, `cfdisk` does not align partitions to block device I/O limits, which can reduce performance on modern drives.  

It is recommended to use **parted** (or `fdisk`, `gdisk`, etc.) which supports proper alignment and scripting. Install it if necessary:

```bash
# Install a specific version from Artix archive
pacman -U "https://archive.artixlinux.org/packages/p/parted/parted-3.4-2-x86_64.pkg.tar.zst"

# OR install the latest from repo
pacman -Sy parted
```

## Erase a Disk
**Warning**: This will completely destroy all data on the target disk.
```bash
# List all disks and partitions to identify your target:
parted -l

# Print partition table of a specific disk:
parted -s /dev/sdX print

# Overwrite the disk with random data for security
# bs=4096 → block size
# iflag=nocache, oflag=direct → bypass caches for performance/consistency
# status=progress → show progress
dd bs=4096 if=/dev/urandom iflag=nocache of=/dev/sdX oflag=direct status=progress || true

# Flush all pending writes:
sync

# Optional but recommended: reboot after wiping, then re-open a root terminal
```
> Interrupting dd will leave partially overwritten data. Only proceed once the process completes.

---

## BIOS Full Disk Encryption
This part explains a **Full Disk Encryption (FDE)** setup on Artix Linux using **BIOS**, **LUKS1** and **LVM**. [Ref](https://wiki.artixlinux.org/Main/InstallationWithFullDiskEncryption)
> Note: Modern UEFI systems often require separate /boot outside the encrypted LUKS container or use LUKS2. This part is targeted at BIOS/MBR systems.

### Goal
Encrypt **everything** on disk, no plaintext filesystem exists on disk. This is only possible on **BIOS** systems because GRUB can unlock **LUKS1** before loading the kernel.
```
# Disk Layout
/dev/sdX (physical disk, MBR / msdos)
└── /dev/sdX1 (LUKS1 encrypted container)
	└── LVM Volume Group
		├── /dev/lvm/boot → /boot (encrypted)
		├── /dev/lvm/swap → swap (encrypted)
		└── /dev/lvm/root → / (encrypted)
```
Why this works:
- BIOS GRUB supports unlocking **LUKS1**
- GRUB can read **ext4 inside LUKS**
- Kernel and initramfs are protected
- Passphrase is required before *any* OS code loads

### Partitioning (MBR / BIOS)
```bash
# List current disks and partitions:
parted -l

# Check target disk:
parted -s /dev/<TARGET_DISK> print

# Create a new MBR partition table:
parted -s /dev/<TARGET_DISK> mklabel msdos

# Create a single primary partition aligned to optimal block boundaries:
parted -s -a optimal /dev/<TARGET_DISK> mkpart "primary" "ext4" "0%" "100%"
# -a optimal ensures the partition starts/ends on the disk's optimal I/O boundaries.

# Mark it as bootable:
parted -s /dev/<TARGET_DISK> set 1 boot on

# Mark it as LVM to indicate it will be used as a physical volume:
parted -s /dev/<TARGET_DISK> set 1 lvm on

# Print table:
parted -s /dev/<TARGET_DISK> print

# Check alignment:
parted -s /dev/<TARGET_DISK> align-check optimal 1
```

### Encrypt Partition
```bash
# Benchmark cryptsetup performance (optional, useful for tuning):
cryptsetup benchmark

# Encrypt partition with LUKS1:
cryptsetup --verbose \
    --type luks1 \
    --cipher serpent-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --iter-time 10000 \
    --use-random \
    --verify-passphrase luksFormat /dev/<TARGET_DISK>

# Open encrypted container and map it as 'system':
cryptsetup luksOpen /dev/<TARGET_DISK> system
```

### Setup the Logical Volumes
```bash
# Initialize LVM on top of the decrypted device
# --- Step 1: Physical Volume (PV) ---
# pvcreate marks a disk or partition as usable by LVM.
# In this case, the decrypted LUKS container (/dev/mapper/system) becomes a "physical volume".
# Think of it as "this chunk of disk is now LVM-aware".
pvcreate /dev/mapper/system

# --- Step 2: Volume Group (VG) ---
# vgcreate combines one or more PVs into a "storage pool" (volume group) called 'lvm'.
# Logical volumes (LVs) are created from this pool.
# You can think of VG as a virtual disk made from one or more PVs.
vgcreate lvm /dev/mapper/system

# --- Step 3: Logical Volumes (LVs) ---
# lvcreate carves out actual usable partitions from the VG.
# --contiguous y ensures the LV uses a single contiguous block (sometimes recommended for boot partitions)
# Names of LVs appear as /dev/mapper/lvm-boot, /dev/mapper/lvm-swap, etc.
lvcreate --contiguous y --size 1G lvm --name boot   		 # /boot
lvcreate --contiguous y --size 16G lvm --name swap  		 # swap
lvcreate --contiguous y --extents +100%FREE lvm --name root  # /
# --contiguous y ensures the LV uses a single contiguous block (optional, sometimes recommended for boot partitions)
# lvm is the volume group name; logical volumes appear as /dev/mapper/lvm-boot, etc.
```

### Format the Partitions
```bash
# /boot (FAT for GRUB compatibility):
mkfs.fat -n BOOT /dev/lvm/boot

# Swap:
mkswap -L SWAP /dev/lvm/swap

# Root filesystem:
mkfs.ext4 -L ROOT /dev/lvm/root
```

### Mount the Partitions
```bash
# Enable swap:
swapon /dev/mapper/lvm-swap

# Mount root:
mount /dev/mapper/lvm-root /mnt

# Mount boot inside root:
mkdir -p /mnt/boot
mount /dev/mapper/lvm-boot /mnt/boot
```
> At this point, the encrypted LVM setup is ready for base system installation.

---

## UEFI 'Full' Disk Encryption

UEFI systems require a slightly different setup than BIOS because **GRUB in UEFI cannot unlock LUKS1 in the same way** and the EFI system partition (ESP) must remain unencrypted.  
This example uses **LUKS2**, **LVM** and **Btrfs** for flexibility, snapshots and subvolumes.

> Note: The EFI System Partition (ESP) must be **FAT32 and unencrypted**, mounted at `/boot/efi`.  
> The rest of the disk can be encrypted with LUKS2 and used with LVM + Btrfs.

### Goal
- Encrypt all partitions except the **ESP**  
- Use **Btrfs** for `/` and optional `/home` to enable snapshots  
- Keep UEFI boot files on the unencrypted ESP  
- Unlock LUKS at boot using GRUB2’s built-in cryptography support  
```
# Disk Layout
/dev/nvme0n1 (physical disk, GPT)
├── /dev/nvme0n1p1 → EFI System Partition (ESP, FAT32, 512MB, unencrypted)
	/dev/nvme0n1p2 → LUKS2 encrypted container
	└── LVM Volume Group 'lvm'
	├── /dev/mapper/lvm-root → Btrfs root filesystem
	└── /dev/mapper/lvm-swap → swap
```

### Partitioning (UEFI / GPT)
```bash
# Print current disks:
parted -l

# Select target disk:
parted -s /dev/<TARGET_DISK> print

# Create GPT partition table:
parted -s /dev/<TARGET_DISK> mklabel gpt

# Create EFI System Partition (ESP):
parted -s -a optimal /dev/<TARGET_DISK> mkpart "EFI" fat32 1MiB 513MiB
parted -s /dev/<TARGET_DISK> set 1 esp on

# Create encrypted partition for LVM:
parted -s -a optimal /dev/<TARGET_DISK> mkpart "LUKS2" 513MiB 100%
```

### Encrypt Partition
```bash
# Benchmark cryptsetup:
cryptsetup benchmark

# Encrypt the partition with LUKS2:
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --hash sha512 --iter-time 10000 \
    --use-random /dev/<TARGET_DISK>p2

# Open encrypted container:
cryptsetup luksOpen /dev/<TARGET_DISK>p2 system
```
> LUKS2 supports more modern algorithms, flexible metadata, and better integration with systemd/GRUB for UEFI.

### Setup the Logical Volumes
```bash
# Step 1: Physical Volume
pvcreate /dev/mapper/system

# Step 2: Volume Group
vgcreate lvm /dev/mapper/system

# Step 3: Logical Volumes
lvcreate -L 16G lvm --name swap    # swap
lvcreate -l 100%FREE lvm --name root   # root (Btrfs)
```

### Format the Partitions
```bash
# ESP (unlocked, FAT32)
mkfs.fat -F32 -n EFI /dev/<TARGET_DISK>p1

# Swap
mkswap -L SWAP /dev/mapper/lvm-swap

# Root filesystem with Btrfs
mkfs.btrfs -L ROOT /dev/mapper/lvm-root
```

### Mount the Partitions
```bash
# Enable swap:
swapon /dev/mapper/lvm-swap

# Mount root:
mount /dev/mapper/lvm-root /mnt

# Optional: create Btrfs subvolumes
btrfs subvolume create /mnt/@          # main root
btrfs subvolume create /mnt/@home      # optional home subvolume
umount /mnt

# Mount Btrfs subvolumes:
mount -o compress=zstd,subvol=@ /dev/mapper/lvm-root /mnt
mkdir -p /mnt/home
mount -o compress=zstd,subvol=@home /dev/mapper/lvm-root /mnt/home

# Mount EFI System Partition:
mkdir -p /mnt/boot/efi
mount /dev/<TARGET_DISK>p1 /mnt/boot/efi
```

---

## Encrypt Second Drive

A separate encrypted /data drive is straightforward, and you don’t need LVM here unless you want snapshots across disks. This WILL ERASE /dev/sda. Double-check the disk:

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# If /dev/sda is empty or you want it clean:
parted -s /dev/sda mklabel gpt
parted -s -a optimal /dev/sda mkpart "LUKS2" 1MiB 100%

# Expected Output:
# lsblk
# NAME           MAJ:MIN RM   SIZE RO TYPE  MOUNTPOINTS
# sda              8:0    0 931,5G  0 disk  
# └─sda1           8:1    0 931,5G  0 part

cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --hash sha512 --iter-time 10000 \
    --use-random /dev/sda1

cryptsetup luksOpen /dev/sda1 data
mkfs.btrfs -L data /dev/mapper/data
mkdir -p /data
mount /dev/mapper/data /mnt
btrfs subvolume create /mnt/@data
btrfs subvolume create /mnt/@snapshots

# Normale workflow to decrypt:
cryptsetup luksOpen /dev/sda1 data
mount -o subvol=@data,compress=zstd,noatime /dev/mapper/data /data
# When Done:
umount /data
cryptsetup luksClose data

# Or Add:
alias data-open='cryptsetup luksOpen /dev/sda1 data && mount -o subvol=@data,compress=zstd,noatime /dev/mapper/data /data'
alias data-close='umount /data && cryptsetup luksClose data'
```

---

## External Drive
### Mount External Drive
```bash
# lsblk
# NAME           MAJ:MIN RM   SIZE RO TYPE  MOUNTPOINTS
# sda              8:0    0 931,5G  0 disk  
# └─sda1           8:1    0 931,5G  0 part  
#   └─data       254:3    0 931,5G  0 crypt /data
# sdb              8:16   0 931,5G  0 disk  
# └─sdb1           8:17   0    16M  0 part  
# sdc              8:32   0   3,6T  0 disk  
# ├─sdc1           8:33   0   128M  0 part  
# └─sdc2           8:34   0   3,6T  0 part  

# Check the file system of target sdc2:
blkid /dev/sdc2
# Example Output
# /dev/sdc2: LABEL="Seagate" BLOCK_SIZE="512" UUID="32A85E" TYPE="ntfs" PARTLABEL="Basic" PARTUUID="b542e8-tc2"

mkdir -p /mnt/external

# NTFS:
mount -t ntfs-3g /dev/sdc2 /mnt/external

# exFAT
mount -t exfat /dev/sdc2 /mnt/external

# FAT32
mount -t vfat /dev/sdc2 /mnt/external

# ext4/XFS/F2FS:
mount /dev/sdX2 /mnt/external

# Btrfs:
mount -t btrfs /dev/sdX2 /mnt/external
# Or Convenience/performance:
mount -o compress=zstd,noatime /dev/sdX2 /mnt/external
# Or mount a subvolume if it exists:
# btrfs subvolume list /dev/sdX2
# ID 256 gen 123 top level 5 path @
# ID 257 gen 124 top level 5 path @home
# ID 258 gen 125 top level 5 path @snapshots
mount -t btrfs -o subvol=@data /dev/sdX2 /mnt/external

# Acces Files
ls -la /mnt/external

# Unmount safely
umount /mnt/external
```

### Windows Compatible Drive
```bash
parted /dev/sdc
(parted) mklabel gpt
(parted) mkpart primary 1MiB 129MiB
(parted) set 1 msftres on
(parted) mkpart primary ntfs 129MiB 1057GiB
(parted) mkpart primary 1057GiB 100%   
(parted) quit   

mkfs.ntfs -f -L Windows /dev/sdc2

cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --hash sha512 --iter-time 10000 \
    --use-random /dev/sdc3

cryptsetup luksOpen /dev/sdc3 drive

mkfs.btrfs -L drive /dev/mapper/drive

mount /dev/mapper/drive /mnt/drive
```

---

# Install Base System
Use basestrap to install the base and optionally the base-devel package groups and your preferred init. [Ref](https://wiki.artixlinux.org/Main/Installation)

```bash
# basestrap installs the base Artix system into /mnt.
# Think of /mnt as "the future / (root) of your installed system".
#
# This step copies packages, initializes pacman keys,
# and sets up a minimal but bootable Artix environment.
basestrap /mnt \
    base \                     # Minimal filesystem, shell, core utilities
    base-devel \               # Toolchain (gcc, make, etc.) – needed for building software
    openrc \                   # Init system (Artix default in this setup)
    linux-hardened \           # Hardened Linux kernel (security-focused)
    linux-hardened-headers \   # Headers required for DKMS modules (e.g. NVIDIA)
    linux-firmware \           # Firmware for Wi-Fi, GPU, storage, etc.
	linux-lts \ 			   # Backup kernel if linux-hardened got corrupted.
	linux-lts-headers \ 	   # Backup kernel
    lvm2-openrc \              # LVM userspace tools + OpenRC service scripts
    cryptsetup-openrc \        # LUKS encryption tools + OpenRC service scripts
    mkinitcpio \               # Builds the initramfs (needed for LUKS + LVM boot)
    neovim \                   # Text editor (used later for config files)
    xclip \                    # Clipboard utility (X11)
    xsel \                     # Alternative clipboard utility
    iwd iwd-openrc \           # Wi-Fi daemon
    dhcpcd dhcpcd-openrc \     # DHCP client (IP configuration)
    elogind-openrc \           # Login/session manager (systemd-logind replacement)
	zsh                        # ZSH Shell

# Generate /etc/fstab for the new system using UUIDs.
# This records how partitions and volumes should be mounted at boot.
fstabgen -U /mnt >> /mnt/etc/fstab

# If using Btrfs:
# - Open /mnt/etc/fstab
# - Add ",compress=zstd" to Btrfs mount options
#   for better performance and reduced disk usage.
#
# Example:
# UUID=xxxx  /  btrfs  rw,relatime,compress=zstd,subvol=@  0  0
#UUID=</dev/mapper/lvm-root> / btrfs compress=zstd,subvol=@ 0 0
#UUID=</dev/mapper/lvm-root> /home btrfs compress=zstd,subvol=@home 0 0
#UUID=</dev/nvme0n1p1> /boot/efi vfat umask=0077 0 1
```

## Chroot
```bash
# artix-chroot changes root into the newly installed system at /mnt.
# From this point on, every command affects the installed system, NOT the live ISO environment.
artix-chroot /mnt /bin/bash

# Set the root password for the installed system.
# This is required to log in after first boot.
passwd

# Sync package databases inside the chroot.
# This ensures pacman knows about current repositories.
pacman -Sy

# Initialize the pacman keyring.
# Required so packages can be verified and installed securely.
pacman-key --init

# Populate Artix Linux signing keys.
# Without this, pacman will fail with signature errors.
pacman-key --populate artix

# Temporary DNS configuration.
# This ensures name resolution works inside the chroot,
# especially if networking services are not yet running.
#
# This file may be overwritten later by network managers.
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
```

## Base Configurations

This section configures system language, regional formats, time zone and host identity.
These settings affect *all* users and programs.

### Locale

We use:
- **en_US.UTF-8** for system language (English messages)
- **en_NL.UTF-8** for regional formats (dates, numbers, currency, measurements)

This avoids mixing incompatible conventions while keeping the system fully English.

```bash
# Enable US English (language)
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "nl_NL.UTF-8 UTF-8" >> /etc/locale.gen

# Generate enabled locales
locale-gen

# Base system language
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Use Netherlands formats while keeping English language
echo "LC_TIME=en_NL.UTF-8" >> /etc/locale.conf
echo "LC_NUMERIC=en_NL.UTF-8" >> /etc/locale.conf
echo "LC_MONETARY=en_NL.UTF-8" >> /etc/locale.conf
echo "LC_MEASUREMENT=en_NL.UTF-8" >> /etc/locale.conf
echo "LC_PAPER=en_NL.UTF-8" >> /etc/locale.conf
echo "LC_ADDRESS=en_NL.UTF-8" >> /etc/locale.conf
echo "LC_TELEPHONE=en_NL.UTF-8" >> /etc/locale.conf

# Verify Locale
locale
# Expected Output
# LANG=en_US.UTF-8
# LC_TIME=en_NL.UTF-8
# LC_NUMERIC=en_NL.UTF-8
# ...
```

### Timezone

This ensures correct timestamps and log times.

```bash
# Set local timezone
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime

# Sync hardware clock
hwclock --systohc
```

### Hostname
Choose a short, lowercase name (e.g. system, atlas, ect). The hostname identifies the system on the network and in logs.

```bash
nvim /etc/conf.d/hostname
	hostname="<FILLIN>"
```

### User

Create a regular user for daily use.

```bash
# Make Zsh the default shell for root (optional, useful if you prefer Zsh over Bash)
chsh -s /bin/zsh root

# Ensures all future users created with useradd will automatically use Zsh.
nvim /etc/default/useradd
	SHELL=/bin/zsh

# Create a daily-use user with a home directory and a default shell.
# -m  → create home directory
# -s  → login shell (use /bin/zsh if you already set it system-wide)
useradd -m -s /bin/bash user

# Set password for the user
passwd user

# Groups give access to audio, video, input devices, storage, etc.
usermod -aG audio,video,input,lp,scanner,optical,storage,users,power user

Disable root login on virtual consoles (TTYs)
# PAM checks /etc/securetty to allow root login on TTYs.
# Edit /etc/pam.d/login to ensure pam_securetty is used:
nvim /etc/pam.d/login
	# Ensure the line exists:	
	auth required pam_securetty.so
# Then edit /etc/securetty:
nvim /etc/securetty
	# Comment out all lines (or leave empty) to block root login on all TTYs.
	# Root can still perform administrative actions via 'sudo' or 'su' from this user.
	comment everything out
```

### Packages

These packages installation form the essential system packages, sets up X11, audio, CLI tools, fonts and configures zsh as default shell.

```bash
# --- Step 1: Upgrade critical system packages first ---
# To avoid cryptsetup and SSL issues during installation, upgrade pacman and OpenSSL.
pacman -S \
	openssl \
	openssl-1.1 \
	pacman

# --- Step 2: Check GPU ---
# Useful to know which graphics driver you need.
lspci | grep -E "VGA|3D"

# --- Step 3: Install core system and userland packages ---
pacman -S \
    # --- Core libraries & device support ---
    glibc                  			# C library
    device-mapper-openrc   			# LVM / device mapper support
    haveged haveged-openrc         	# Entropy daemon (for key generation, crypto)
    cronie cronie-openrc          	# Cron jobs
    openntpd openntpd-openrc        # NTP time synchronization
    acpid acpid-openrc           	# ACPI events (power buttons, lid, etc.)

    # --- Bootloader & EFI tools ---
    efibootmgr             			# EFI boot manager (needed for UEFI GRUB)
    grub                   			# Bootloader

    # --- X11 and graphics ---
    libx11 libxft libxinerama libxrandr libxrender libxext \
    xorg-server xorg-apps xorg-xinit xorg-xrandr xorg-xinput \
    xorg-fonts xorg-font-util xorg-mkfontscale xorg-mkfontdir \
    xorg-fonts-misc        			# X11 dependencies
    xcompmgr               			# Simple compositor for X11
    xwallpaper             			# Set wallpaper in X
    brightnessctl          			# Screen brightness control
    mesa                   			# OpenGL implementation
    nvidia-dkms nvidia-utils 		# NVIDIA GPU drivers (skip if not using Nvidia)

    # --- Networking ---
    inetutils              			# Basic network utilities (ping, ftp, etc.)
    openssh                			# SSH client/server
	firefox

    # --- Audio & Media ---
    playerctl alsa-utils wireplumber pipewire-pulse pulsemixer \
    wireplumber-openrc pipewire-pulse-openrc \
                           			# Audio system: PipeWire + PulseAudio compatibility
    bluez bluez-utils bluez-openrc  # Bluetooth
    yt-dlp                 			# Video downloader
    mpd mpc mpv            			# Music player daemon + clients
    nsxiv                           # Minimalist Image Viewer

    # --- Filesystem utilities ---
	ntfs-3g
	exfat-utils
	dosfstools
	unzip

    # --- Shell utilities ---
    lf                     			# Terminal file manager
    eza                    			# Modern ls replacement
    tldr                   			# Simplified command summaries
    curl                   			# Downloads, scripts
    fastfetch              			# System info in terminal
    man man-db man-pages   			# Manual pages
    bash-completion        			# Command completion for bash
    zsh zsh-completions    			# Zsh shell and completions
    bat ripgrep fd fzf     			# Modern CLI tools (cat with syntax, search, find, fuzzy finder)
    lazygit github-cli git     		# Git helper tools
	htop
    parted
    btrfs-progs
    mlocate
    autorandr

    # --- Fonts ---
    noto-fonts                  	# Google Noto fonts (multilingual support)
    noto-fonts-emoji           	 	# Emoji support
    ttf-font-awesome            	# Icon font
    ttf-dejavu                  	# Classic sans-serif font
    terminus-font              		# Console font

    zathura
    zathura-pdf-mupdf
    libreoffice-fresh

# --- Step 4: Console font configuration ---
# Changes the font in virtual console (tty) to Terminus 12x6 (good readability)
echo 'FONT=ter-132n' > /etc/vconsole.conf

# --- Step 5: Configure Git ---
git config --global user.name "name"
git config --global user.email "mail"
git config --global --list

ssh-keygen -t ed25519 -C "mail@provider"
# Go to GitHub in your browser → Settings → SSH and GPG keys → New SSH key.
# Paste the contents of id_ed25519.pub into GitHub and give it a name.
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

gh auth login
ssh -T git@github.com

git remote -v
git remote set-url origin git@github.com:username/repo

# --- Step 6: Install Oh My Posh for Zsh prompt ---
# This provides a modern, informative prompt
curl -s https://ohmyposh.dev/install.sh | bash -s -- -d /usr/local/bin/oh-my-posh
mkdir -p /etc/zsh/themes
git clone --depth=1 git@github.com:JanDeDobbeleer/oh-my-posh.git
cp -r /tmp/oh-my-posh/themes/* /etc/zsh/themes/
rm -rf /tmp/oh-my-posh

# --- Step 7: Setup base files ---
git clone git@github.com:SMB-M87/Artix.git
cp zsh_shared /etc/zsh/zsh_shared
cp zshrc /home/<FILLIN>/.zshrc
cp zprofile /home/<FILLIN>/.zprofile
cp xinitrc /home/<FILLIN>/.xinitrc
chmod +x /home/<FILLIN>/.xinitrc
cp zshrc /root/.zshrc
```

### GUI
```bash
# Enable system clipboard in Neovim so yanks/pastes work across apps
nvim /etc/xdg/nvim/sysinit.vim
	# Append:
	set clipboard=unnamedplus

# Move to source directory for building software
cd /usr/local/src

# Clone and install DWM (Dynamic Window Manager)
# Minimal tiling window manager for X11
git clone git@github.com:SMB-M87/dwm
cd ../dwm
make clean install

# Clone and install dmenu, a lightweight app launcher for DWM
git clone git@github.com:SMB-M87/dmenu
cd ../dmenu
make clean install

# Clone and install st, a minimal terminal emulator
git clone https://github.com/SMB-M87/st
cd /st
make clean install

# Clone slock, a simple screen locker
git clone https://github.com/SMB-M87/slock
cd slock

# Edit slock configuration to set your user/group
nvim config.h
	change user and group

# Configure ACPI scripts for power/lid events
nvim /etc/acpi/handler.sh
	button/power)
		logger..
		/sbin/shutdown -h --now
	button/lid)
		close)
			logger 'LID closed, locking screen'
			/usr/local/src/slock/lid-lock.sh
			;;

make clean install
```

### Services
```bash
# Early boot services for encrypted LVM and system initialization
rc-update add device-mapper boot   # Handles device-mapper devices (required for LVM)
rc-update add lvm boot             # Activates volume groups and logical volumes at boot
rc-update add dmcrypt boot         # Unlocks LUKS encrypted partitions
rc-update add elogind boot         # Starts elogind for session and login management

# Core system services for normal operation
rc-update add dbus default         # Provides D-Bus IPC system; required by many system services
rc-update add haveged default      # Optional: provides entropy for cryptography (useful for LUKS, SSH, etc.)
rc-update add cronie default       # Cron daemon for scheduled tasks
rc-update add ntpd default         # Synchronizes system time via NTP
rc-update add acpid default        # Handles ACPI events like power button, lid close, battery status

rc-update add iwd default
rc-update add dhcpcd default
rc-update add bluetooth default
```

## mkinicpio.conf & GRUB
Overview: BIOS vs UEFI
- **BIOS**: GRUB can unlock LUKS1 directly. `/boot` can be encrypted.  
- **UEFI**: GRUB cannot unlock LUKS1 reliably, and the EFI System Partition (ESP) **must remain unencrypted**. Use LUKS2 with modern encryption and keep `/boot/efi` separate.  
- Initramfs (`mkinitcpio`) and GRUB configuration differ slightly between the two.

### BIOS
```bash
# Edit mkinitcpio configuration
nvim /etc/mkinitcpio.conf
	# HOOKS determine what scripts and modules are included in the initramfs.
	# Typical order: base → udev → autodetect → microcode → modconf → kms → keyboard → keymap → consolefont → block → encrypt → lvm2 → resume → filesystem
	HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 resume filesystem)
	# MODULES specifies kernel modules to include. Here, including NVIDIA modules for proprietary GPU support.
	MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)

cp /etc/mkinitcpio.conf /etc/mkinitcpio-lts.conf
	Remove nvidia Modules

# Edit the preset file to define initramfs presets (used by mkinitcpio -P)
# 'default' → normal initramfs
# 'fallback' → generic initramfs with additional modules; useful if new kernel modules break boot
nvim /etc/mkinitcpio.d/linux-hardened.preset:
	PRESETS=('default' 'fallback')
	# Uncomment Default config fallback config and fallback image

nvim /etc/mkinitcpio.d/linux-lts.preset:
	PRESETS=('default' 'fallback')
	# Uncomment Default config fallback config and fallback image => use mkinitcpio-lts

# Create pacman hook to automatically rebuild initramfs after kernel upgrades
mkdir -p /etc/pacman.d/hooks
nvim /etc/pacman.d/hooks/99-mkinitcpio-force.hook
	# Run after installing or upgrading these packages
	[Trigger]
	Operation = Install
	Operation = Upgrade
	Type = Package
	Target = linux-hardened
	Target = linux
	Target = linux-lts

	[Action]
	Description = Rebuilding initramfs (forced)
	When = PostTransaction
	Exec = /usr/bin/mkinitcpio -P

# Build the initial initramfs for the hardened kernel
mkinitcpio -p linux-hardened
mkinitcpio -p linux-lts

# Get UUID of swap partition (useful for resume/suspend)
blkid -s UUID -o value /dev/lvm/swap

# Configure GRUB
nvim /etc/default/grub
	# Timeout in seconds for GRUB menu
	GRUB_TIMEOUT=1
	# Save last selected menu entry
	GRUB_DEFAULT=saved
    GRUB_SAVEDEFAULT=true
	# Kernel parameters for default boot
	# cryptdevice=UUID=xxx:system → tells kernel where to find encrypted root
	# loglevel=3 → suppress most kernel logs
	# quiet → reduce boot messages
	# net.ifnames=0 → disable predictable network interface names (ensures eth0/wlan0 style names)
	GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=xxx:system loglevel=3 quiet net.ifnames=0 nvidia-drm.modeset=1"
	# Kernel parameters without DEFAULT for explicit root specification
	GRUB_CMDLINE_LINUX="cryptdevice=UUID=xxx:system root=/dev/mapper/lvm-root net.ifnames=0 nvidia-drm.modeset=1"
	# Enable GRUB to decrypt LUKS at boot (necessary for encrypted /boot/root)
    GRUB_ENABLE_CRYPTODISK=y

# Install GRUB bootloader to MBR of target disk
# --target=i386-pc → BIOS boot
# --boot-directory=/boot → where to place GRUB files
# --bootloader-id=artix → menu name
# --recheck → force detection of disks
grub-install --target=i386-pc --boot-directory=/boot --bootloader-id=artix --recheck /dev/<TARGET_DISK>

# Generate GRUB configuration file
grub-mkconfig -o /boot/grub/grub.cfg
```

---

### UEFI
```bash
# Edit mkinitcpio configuration (similar to BIOS)
nvim /etc/mkinitcpio.conf
	HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 resume filesystems)
	MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)

cp /etc/mkinitcpio.conf /etc/mkinitcpio-lts.conf
	Remove nvidia Modules

nvim /etc/mkinitcpio.d/linux-hardened.preset:
	PRESETS=('default' 'fallback')
	# Uncomment Default config fallback config and fallback image

nvim /etc/mkinitcpio.d/linux-lts.preset:
	PRESETS=('default' 'fallback')
	# Uncomment Default config fallback config and fallback image => use mkinitcpio-lts

# Rebuild initramfs
mkinitcpio -p linux-hardened
mkinitcpio -p linux-lts

# Configure GRUB for UEFI
nvim /etc/default/grub
	GRUB_TIMEOUT=1
	GRUB_SAVEDEFAULT=true
	GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=xxx:system root=/dev/mapper/lvm-root loglevel=3 quiet nvidia-drm.modeset=1"
	GRUB_CMDLINE_LINUX="cryptdevice=UUID=xxx:system root=/dev/mapper/lvm-root loglevel=3 quiet net.ifnames=0"

# Verify UEFI is visible:
ls /sys/firmware/efi/efivars

# Install GRUB to EFI System Partition (ESP)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=artix --recheck

# Generate GRUB config
grub-mkconfig -o /boot/grub/grub.cfg
```

---

## Reboot
```bash
exit
umount -R /mnt
swapoff -a
vgchange -an lvm
cryptsetup luksClose system
sync
reboot

User:
rc-update add wireplumber default --user
rc-update add pipewire-pulse default --user
rc-update add pipewire default --user

rc-service pipewire start --user
rc-service pipewire-pulse start --user
rc-service wireplumber start --user

Root:
# Check that udev (device manager) is running
rc-status sysinit | grep "udev"
# Expected Output:
# udev                       [  started  ]

nvidia-smi //Check if GPU loaded correctly
lsmod | grep nvidia
dmesg | grep -i nvidia
grep -i nvidia /var/log/Xorg.0.log

ip link
rfkill list
unblock wifi

nvim /etc/init.d/unblockwifi
#!/sbin/openrc-run
command="/usr/sbin/rfkill"
command_args="unblock wifi"
depend() {
        after bootmisc
}

chmod +x /etc/init.d/unblockwifi
rc-update add unblockwifi boot

iwctl
device list
station <device> scan
station <device> get-networks
station <device> connect(-hidden) NETWORK_NAME
exit

ip addr show <device>

nvim /etc/init.d/unblockbluetooth
#!/sbin/openrc-run
command="/usr/sbin/rfkill"
command_args="unblock bluetooth"
depend() {
        after bootmisc
}

chmod +x /etc/init.d/unblockbluetooth
rc-update add unblockbluetooth boot

bluetoothctl
	power on
	agent on
	default-agent
	scan on
	pair XX:XX:XX:XX:XX:XX
	trust XX..
	connect XX..
	scan off

mandb
updatedb

# Invert Mouse
xinput list
# Example Output:
# ⎜   ↳ Logitech USB Optical Mouse           id=10   [slave  pointer  (2)]

# Add following to .xinitrc before exec dwm:
xinput set-button-map "Logitech USB Optical Mouse" 3 2 1 &
```

## Rechroot
```bash
# BIOS
cryptsetup luksOpen /dev/<TARGET_DISK> system
vgchange -ay
swapon /dev/lvm/swap
mount /dev/lvm/root /mnt
mount /dev/lvm/boot /mnt/boot
artix-chroot /mnt /bin/bash

# UEFI
cryptsetup luksOpen /dev/<TARGET_DISK>p2 system
vgchange -ay
mount -o compress=zstd,subvol=@ /dev/mapper/lvm-root /mnt
mkdir -p /mnt/home
mount -o compress=zstd,subvol=@home /dev/mapper/lvm-root /mnt/home
mkdir -p /mnt/boot/efi
mount /dev/<TARGET_DISK>p1 /mnt/boot/efi
mount -t proc /proc /mnt/proc
mount --rbind /sys /mnt/sys
mount --rbind /dev /mnt/dev
mount --rbind /run /mnt/run
artix-chroot /mnt /bin/bash
```

---
