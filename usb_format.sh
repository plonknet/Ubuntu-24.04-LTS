#!/bin/bash
set -e


# Root-Check

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo or become Root: sudo $0"
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"

# DEP-Check

REQUIRED_PKGS=(parted dosfstools exfatprogs ntfs-3g udisks2)

echo -e "\n=== USB-Drive Formatter for Ubuntu 24.04 ==="
echo "→ Prüfe benötigte Pakete..."

MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
  echo "Folgende Pakete fehlen und werden jetzt installiert:"
  printf '  - %s\n' "${MISSING_PKGS[@]}"
  echo
  apt-get update
  apt-get install -y "${MISSING_PKGS[@]}"
else
  echo "Alle benötigten Pakete sind bereits installiert."
fi

echo


# Looking for USB Peripherals

mapfile -t DEVICES < <(
  lsblk -dpno NAME,TRAN,RM,SIZE,MODEL | awk '$2=="usb" && $3=="1"' | while read -r dev tran rm size model; do
    LABEL=$(lsblk -no LABEL "${dev}1" 2>/dev/null | head -n 1)
    FSTYPE=$(lsblk -no FSTYPE "${dev}1" 2>/dev/null | head -n 1)
    [[ -z "$LABEL" ]] && LABEL="—"
    [[ -z "$FSTYPE" ]] && FSTYPE="—"
    echo "$dev|$size|$FSTYPE|$LABEL|$model"
  done
)

if (( ${#DEVICES[@]} == 0 )); then
  echo "❌ Keine USB-Sticks gefunden."
  exit 1
fi

echo "Gefundene USB-Sticks:"
i=1
for entry in "${DEVICES[@]}"; do
  IFS="|" read -r dev size fs label model <<< "$entry"
  printf " [%d] %-10s  %-6s  %-6s  Label=\"%s\"  %s\n" "$i" "$dev" "$size" "$fs" "$label" "$model"
  ((i++))
done

echo
read -rp "→ Nummer des zu formatierenden Sticks: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#DEVICES[@]})); then
  echo "Ungültige Auswahl."
  exit 1
fi

SELECT="${DEVICES[$((choice-1))]}"
IFS="|" read -r DEV SIZE FSTYPE_OLD LABEL_OLD MODEL <<< "$SELECT"

echo -e "\n⚠️ GEWÄHLT:"
echo "  Gerät:  $DEV"
echo "  Größe:  $SIZE"
echo "  FS:     $FSTYPE_OLD"
echo "  Label:  $LABEL_OLD"
echo
read -rp "Alle Daten werden GELÖSCHT. Bestätige mit 'YES': " confirm
[[ "$confirm" != "YES" ]] && { echo "Abgebrochen."; exit 0; }

# Choose FS

echo -e "\nDateisystem wählen:"
echo "  [1] FAT32  (kompatibel überall, vfat)"
echo "  [2] exFAT  (für große Dateien)"
echo "  [3] NTFS   (Windows optimiert)"
echo "  [4] ext4   (Linux)"
read -rp "→ Auswahl (1-4): " fs

case "$fs" in
  1) FSTYPE="vfat" ;;
  2) FSTYPE="exfat" ;;
  3) FSTYPE="ntfs" ;;
  4) FSTYPE="ext4" ;;
  *) echo "Ungültige Auswahl."; exit 1 ;;
esac

read -rp "Neues Label (Name des USB-Sticks): " NEWLABEL
[[ -z "$NEWLABEL" ]] && { echo "Label darf nicht leer sein."; exit 1; }


# Umount & Partition
echo -e "\nUnmount & neue Partitionstabelle..."

# Unmount
lsblk -no NAME,MOUNTPOINT "$DEV" | tail -n +2 | while read -r name mp; do
  if [[ -n "$mp" ]]; then
    echo "  umount $mp"
    umount "$mp" || true
  fi
done

parted -s "$DEV" mklabel gpt
parted -s "$DEV" mkpart primary 1MiB 100%
PART="${DEV}1"


# Format

echo -e "\n📀 Formatiere → $PART als $FSTYPE (Label \"$NEWLABEL\")"

case "$FSTYPE" in
  vfat)  mkfs.vfat -F32 -n "$NEWLABEL" "$PART" ;;
  exfat) mkfs.exfat -n "$NEWLABEL" "$PART" ;;
  ntfs)  mkfs.ntfs -Q -L "$NEWLABEL" "$PART" ;;
  ext4)  mkfs.ext4 -L "$NEWLABEL" "$PART" ;;
esac


# Auto-Mount

echo -e "\n🔁 Versuche, den Stick automatisch einzubinden..."

sleep 2

if command -v udisksctl >/dev/null 2>&1; then
  if sudo -u "$REAL_USER" udisksctl mount -b "$PART" --no-user-interaction >/tmp/usb-mount.log 2>&1; then
    MOUNTPOINT=$(grep "Mounted" /tmp/usb-mount.log | sed -E 's/.* at (.+)\./\1/')
    echo "✔ Erfolgreich gemountet unter: $MOUNTPOINT"
  else
    echo "⚠ Automount mit udisksctl fehlgeschlagen."
    echo "  Log:"
    sed 's/^/    /' /tmp/usb-mount.log
    echo -e "\nDu kannst den Stick manuell mounten, z.B.:"
    echo "  sudo mkdir -p /media/$REAL_USER/$NEWLABEL"
    echo "  sudo mount $PART /media/$REAL_USER/$NEWLABEL"
  fi
else
  echo "⚠ udisksctl nicht gefunden. Vermutlich Server/Minimal-Installation."
  echo "  Manuell mounten, z.B.:"
  echo "    sudo mkdir -p /media/$REAL_USER/$NEWLABEL"
  echo "    sudo mount $PART /media/$REAL_USER/$NEWLABEL"
fi


# EoF

echo -e "\n✔ Fertig!"
echo "  Gerät:     $DEV"
echo "  Partition: $PART"
echo "  FS:        $FSTYPE"
echo "  Label:     $NEWLABEL"
echo
