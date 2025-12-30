#!/usr/bin/env bash
set -e

########################################
# Color helpers
########################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
header()  { echo -e "\n${BOLD}$*${RESET}\n"; }

########################################
# Root check
########################################
if [[ $EUID -ne 0 ]]; then
  error "Please run this script as root, e.g.: sudo $0"
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_ID=$(id -u "$REAL_USER")
USER_GID=$(id -g "$REAL_USER")

header "Disk & USB Formatter for Ubuntu 24.04"

########################################
# Dependency check & install
########################################
REQUIRED_PKGS=(parted dosfstools exfatprogs ntfs-3g util-linux)
MISSING_PKGS=()

info "Checking required packages..."

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
  warn "The following packages are missing and will be installed:"
  for p in "${MISSING_PKGS[@]}"; do
    echo "  - $p"
  done
  echo
  apt-get update
  apt-get install -y "${MISSING_PKGS[@]}"
else
  success "All required packages are already installed."
fi

########################################
# Detect system (root) device to protect it
########################################
ROOT_PART=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_DEV=""
if [[ -n "$ROOT_PART" ]]; then
  PKNAME=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null || true)
  if [[ -n "$PKNAME" ]]; then
    ROOT_DEV="/dev/$PKNAME"
  else
    # Fallback (handles /dev/sda2 style)
    ROOT_DEV="${ROOT_PART%[0-9]*}"
  fi
fi

if [[ -n "$ROOT_DEV" ]]; then
  info "System root device detected and protected: ${BOLD}$ROOT_DEV${RESET}"
else
  warn "Could not reliably detect system root device. Please be extra careful!"
fi

########################################
# Choose device type: external or internal
########################################
echo
echo -e "${BOLD}What do you want to format?${RESET}"
echo "  [1] External USB drive (stick / USB HDD / SD card)"
echo "  [2] Internal drive (NON-system disk only)"
read -rp "→ Choice (1-2): " TYPE_CHOICE

DEVICES=()

if [[ "$TYPE_CHOICE" == "1" ]]; then
  ########################################
  # External USB drives
  # NOTE: Do NOT filter on RM=1, because many USB HDDs report RM=0
  ########################################
  mapfile -t DEVICES < <(
    lsblk -dpno NAME,TRAN,SIZE,MODEL,TYPE | awk '$2=="usb" && $5=="disk"' | while read -r dev tran size model type; do
      # First child partition (if any)
      PART1=$(lsblk -lnpo NAME "$dev" | sed -n '2p')
      if [[ -n "$PART1" ]]; then
        LABEL=$(lsblk -no LABEL "$PART1" 2>/dev/null | head -n 1)
        FSTYPE=$(lsblk -no FSTYPE "$PART1" 2>/dev/null | head -n 1)
      else
        LABEL=""
        FSTYPE=""
      fi
      [[ -z "$LABEL" ]] && LABEL="—"
      [[ -z "$FSTYPE" ]] && FSTYPE="—"
      echo "$dev|$size|$FSTYPE|$LABEL|$model|USB"
    done
  )

elif [[ "$TYPE_CHOICE" == "2" ]]; then
  ########################################
  # Internal drives (no USB, no system disk)
  ########################################
  mapfile -t DEVICES < <(
    lsblk -dpno NAME,TRAN,TYPE,SIZE,MODEL | while read -r dev tran type size model; do
      # Only physical disks
      [[ "$type" != "disk" ]] && continue
      # Exclude USB
      [[ "$tran" == "usb" ]] && continue
      # Exclude root device (system disk)
      [[ -n "$ROOT_DEV" && "$dev" == "$ROOT_DEV" ]] && continue

      # First child partition (if any)
      PART1=$(lsblk -lnpo NAME "$dev" | sed -n '2p')
      if [[ -n "$PART1" ]]; then
        LABEL=$(lsblk -no LABEL "$PART1" 2>/dev/null | head -n 1)
        FSTYPE=$(lsblk -no FSTYPE "$PART1" 2>/dev/null | head -n 1)
      else
        LABEL=""
        FSTYPE=""
      fi
      [[ -z "$LABEL" ]] && LABEL="—"
      [[ -z "$FSTYPE" ]] && FSTYPE="—"
      echo "$dev|$size|$FSTYPE|$LABEL|$model|INTERNAL"
    done
  )
else
  error "Invalid choice."
  exit 1
fi

if (( ${#DEVICES[@]} == 0 )); then
  error "No matching drives found."
  exit 1
fi

########################################
# Show devices
########################################
echo
header "Detected drives"

i=1
for entry in "${DEVICES[@]}"; do
  IFS="|" read -r dev size fs label model kind <<< "$entry"
  printf " [%d] %-12s %-7s %-7s Label=\"%s\"  %-8s %s\n" \
    "$i" "$dev" "$size" "$fs" "$label" "$kind" "$model"
  ((i++))
done

echo
read -rp "→ Enter the number of the drive to FORMAT: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#DEVICES[@]})); then
  error "Invalid selection."
  exit 1
fi

SELECT="${DEVICES[$((choice-1))]}"
IFS="|" read -r DEV SIZE FSTYPE_OLD LABEL_OLD MODEL KIND <<< "$SELECT"

echo
header "SUMMARY OF SELECTED DRIVE"
echo -e "  Device : ${BOLD}$DEV${RESET}"
echo -e "  Type   : ${BOLD}$KIND${RESET}"
echo -e "  Size   : $SIZE"
echo -e "  FS old : $FSTYPE_OLD"
echo -e "  Label  : $LABEL_OLD"

if [[ "$KIND" == "INTERNAL" ]]; then
  echo
  echo -e "${RED}${BOLD}WARNING: INTERNAL DRIVE SELECTED!${RESET}"
  echo -e "${RED}Make absolutely sure this is NOT your system disk.${RESET}"
fi

echo
echo -e "${RED}${BOLD}This will ERASE ALL DATA on $DEV!${RESET}"
read -rp "Type ${BOLD}YES${RESET} to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
  warn "Aborted by user."
  exit 0
fi

########################################
# Choose filesystem
########################################
echo
header "Filesystem selection"
echo "  [1] FAT32  (vfat, highly compatible)"
echo "  [2] exFAT  (large file support, modern OSes)"
echo "  [3] NTFS   (Windows optimized)"
echo "  [4] ext4   (Linux native)"
read -rp "→ Choice (1-4): " fs

case "$fs" in
  1) FSTYPE="vfat" ;;
  2) FSTYPE="exfat" ;;
  3) FSTYPE="ntfs" ;;
  4) FSTYPE="ext4" ;;
  *)
    error "Invalid filesystem choice."
    exit 1
    ;;
esac

read -rp "New volume label (display name of the drive): " NEWLABEL
if [[ -z "$NEWLABEL" ]]; then
  error "Label must not be empty."
  exit 1
fi

# Use a safer directory name (replace spaces with underscores)
SAFE_LABEL="${NEWLABEL// /_}"

########################################
# Unmount & create new partition table
########################################
echo
header "Preparing drive"

info "Unmounting all partitions on $DEV (if any)..."
lsblk -lnpo NAME,MOUNTPOINT "$DEV" | tail -n +2 | while read -r name mp; do
  if [[ -n "$mp" ]]; then
    info "  umount $mp"
    umount "$mp" || true
  fi
done

info "Creating new GPT partition table on $DEV..."
parted -s "$DEV" mklabel gpt
info "Creating primary partition (1 MiB → 100%)..."
parted -s "$DEV" mkpart primary 1MiB 100%

# Determine the newly created partition reliably (2nd line child of DEV)
PART=$(lsblk -lnpo NAME "$DEV" | sed -n '2p')
if [[ -z "$PART" ]]; then
  error "Could not detect newly created partition on $DEV."
  exit 1
fi

########################################
# Format partition
########################################
echo
header "Formatting partition"

info "Formatting $PART as $FSTYPE with label \"$NEWLABEL\"..."

case "$FSTYPE" in
  vfat)
    mkfs.vfat -F32 -n "$NEWLABEL" "$PART"
    ;;
  exfat)
    mkfs.exfat -n "$NEWLABEL" "$PART"
    ;;
  ntfs)
    mkfs.ntfs -Q -L "$NEWLABEL" "$PART"
    ;;
  ext4)
    mkfs.ext4 -L "$NEWLABEL" "$PART"
    ;;
esac

success "Formatting completed."

UUID=$(blkid -s UUID -o value "$PART" 2>/dev/null || true)
if [[ -z "$UUID" ]]; then
  warn "Could not retrieve UUID for $PART. fstab entry may need manual adjustment later."
else
  info "Partition UUID: $UUID"
fi

########################################
# Mount mode selection
########################################
echo
header "Mount options"

echo "How should this drive be mounted?"
echo "  [1] Temporarily now under /media/$REAL_USER/$SAFE_LABEL"
echo "  [2] Permanently via /etc/fstab (auto-mount on boot)"
echo "  [3] Do not mount (just format)"
read -rp "→ Choice (1-3): " MOUNT_CHOICE

MOUNTPOINT="/media/$REAL_USER/$SAFE_LABEL"

# Only create mountpoint if we actually intend to mount
if [[ "$MOUNT_CHOICE" == "1" || "$MOUNT_CHOICE" == "2" ]]; then
  mkdir -p "$MOUNTPOINT"
fi

# Mount options
if [[ "$FSTYPE" == "ext4" ]]; then
  MOUNT_OPTS="defaults"
  FSTAB_OPTS="defaults,nofail,x-systemd.device-timeout=1"
else
  MOUNT_OPTS="uid=$USER_ID,gid=$USER_GID,umask=022"
  FSTAB_OPTS="defaults,nofail,uid=$USER_ID,gid=$USER_GID,umask=022,x-systemd.device-timeout=1"
fi

########################################
# Apply mount choice
########################################
if [[ "$MOUNT_CHOICE" == "1" ]]; then
  echo
  header "Temporary mount"
  info "Mounting $PART → $MOUNTPOINT ..."
  mount -t "$FSTYPE" -o "$MOUNT_OPTS" "$PART" "$MOUNTPOINT"
  success "Mounted at: $MOUNTPOINT"

elif [[ "$MOUNT_CHOICE" == "2" ]]; then
  echo
  header "Persistent mount via /etc/fstab"

  if [[ -z "$UUID" ]]; then
    error "No UUID available – cannot safely create /etc/fstab entry."
  else
    BACKUP="/etc/fstab.backup-$(date +%Y%m%d-%H%M%S)"
    info "Creating backup of /etc/fstab → $BACKUP"
    cp /etc/fstab "$BACKUP"

    # Avoid duplicate UUID entries
    if grep -q "UUID=$UUID" /etc/fstab; then
      warn "An entry with this UUID already exists in /etc/fstab."
      warn "No new entry was written. Please review /etc/fstab manually."
    else
      FSTAB_LINE="UUID=$UUID  $MOUNTPOINT  $FSTYPE  $FSTAB_OPTS  0  0"
      echo "$FSTAB_LINE" >> /etc/fstab
      success "New fstab entry added:"
      echo "  $FSTAB_LINE"
    fi

    echo
    info "Attempting to mount $MOUNTPOINT using the new fstab entry..."
    mount "$MOUNTPOINT" || warn "Mount command reported an error. Please check /etc/fstab and system logs."
    success "Drive should now be available at: $MOUNTPOINT"
  fi

elif [[ "$MOUNT_CHOICE" == "3" ]]; then
  echo
  header "No mount selected"
  info "Drive remains unmounted. You can mount it later manually."

else
  echo
  warn "Invalid mount choice – skipping mount step."
fi

########################################
# Final summary
########################################
echo
header "Done"

echo -e "  Device    : ${BOLD}$DEV${RESET}"
echo -e "  Partition : ${BOLD}$PART${RESET}"
echo -e "  Type      : $KIND"
echo -e "  Filesystem: $FSTYPE"
echo -e "  Label     : $NEWLABEL"
if [[ "$MOUNT_CHOICE" == "1" || "$MOUNT_CHOICE" == "2" ]]; then
  echo -e "  Mount dir : $MOUNTPOINT"
else
  echo -e "  Mount dir : —"
fi

success "All operations finished."
echo
