#!/usr/bin/env bash
set -e

########################################
# Root-Check
########################################
if [[ $EUID -ne 0 ]]; then
  echo "Bitte als Root starten: sudo $0"
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_ID=$(id -u "$REAL_USER")
USER_GID=$(id -g "$REAL_USER")

########################################
# Abhängigkeiten prüfen & installieren
########################################
REQUIRED_PKGS=(parted dosfstools exfatprogs ntfs-3g blkid)

echo -e "\n=== Disk/USB Formatter für Ubuntu 24.04 ==="
echo "→ Prüfe benötigte Pakete..."

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
  echo "Folgende Pakete fehlen und werden installiert:"
  printf '  - %s\n' "${MISSING_PKGS[@]}"
  echo
  apt-get update
  apt-get install -y "${MISSING_PKGS[@]}"
else
  echo "Alle benötigten Pakete sind bereits installiert."
fi

echo

########################################
# System-Root-Device ermitteln (zum Schutz)
########################################
ROOT_PART=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_DEV=""
if [[ -n "$ROOT_PART" ]]; then
  PKNAME=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null || true)
  if [[ -n "$PKNAME" ]]; then
    ROOT_DEV="/dev/$PKNAME"
  else
    # Fallback
    ROOT_DEV="${ROOT_PART%[0-9]*}"
  fi
fi

########################################
# Gerätetyp wählen: extern oder intern
########################################
echo "Was möchtest du formatieren?"
echo "  [1] Externes USB-Laufwerk (Stick / USB-HDD)"
echo "  [2] Internes Laufwerk (NICHT Systemplatte)"
read -rp "→ Auswahl (1-2): " TYPE_CHOICE

DEVICES=()

if [[ "$TYPE_CHOICE" == "1" ]]; then
  ########################################
  # USB-Geräte
  ########################################
  mapfile -t DEVICES < <(
    lsblk -dpno NAME,TRAN,RM,SIZE,MODEL | awk '$2=="usb" && $3=="1"' | while read -r dev tran rm size model; do
      LABEL=$(lsblk -no LABEL "${dev}1" 2>/dev/null | head -n 1)
      FSTYPE=$(lsblk -no FSTYPE "${dev}1" 2>/dev/null | head -n 1)
      [[ -z "$LABEL" ]] && LABEL="—"
      [[ -z "$FSTYPE" ]] && FSTYPE="—"
      echo "$dev|$size|$FSTYPE|$LABEL|$model|USB"
    done
  )
elif [[ "$TYPE_CHOICE" == "2" ]]; then
  ########################################
  # Interne Laufwerke (keine USB, keine Systemplatte)
  ########################################
  mapfile -t DEVICES < <(
    lsblk -dpno NAME,TRAN,TYPE,RM,SIZE,MODEL | while read -r dev tran type rm size model; do
      # Nur echte Disks
      [[ "$type" != "disk" ]] && continue
      # Keine USB
      [[ "$tran" == "usb" ]] && continue
      # Keine Systemplatte
      [[ -n "$ROOT_DEV" && "$dev" == "$ROOT_DEV" ]] && continue
      # Label/FS von erster Partition holen (falls vorhanden)
      PART1="${dev}1"
      LABEL=$(lsblk -no LABEL "$PART1" 2>/dev/null | head -n 1)
      FSTYPE=$(lsblk -no FSTYPE "$PART1" 2>/dev/null | head -n 1)
      [[ -z "$LABEL" ]] && LABEL="—"
      [[ -z "$FSTYPE" ]] && FSTYPE="—"
      echo "$dev|$size|$FSTYPE|$LABEL|$model|INTERN"
    done
  )
else
  echo "Ungültige Auswahl."
  exit 1
fi

if (( ${#DEVICES[@]} == 0 )); then
  echo "❌ Keine passenden Laufwerke gefunden."
  exit 1
fi

########################################
# Geräte anzeigen
########################################
echo
echo "Gefundene Laufwerke:"
i=1
for entry in "${DEVICES[@]}"; do
  IFS="|" read -r dev size fs label model kind <<< "$entry"
  printf " [%d] %-12s %-6s %-6s Label=\"%s\"  %-6s  %s\n" \
    "$i" "$dev" "$size" "$fs" "$label" "$kind" "$model"
  ((i++))
done

echo
read -rp "→ Nummer des zu formatierenden Laufwerks: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#DEVICES[@]})); then
  echo "Ungültige Auswahl."
  exit 1
fi

SELECT="${DEVICES[$((choice-1))]}"
IFS="|" read -r DEV SIZE FSTYPE_OLD LABEL_OLD MODEL KIND <<< "$SELECT"

echo
echo "⚠️ GEWÄHLT:"
echo "  Gerät:  $DEV"
echo "  Typ:    $KIND"
echo "  Größe:  $SIZE"
echo "  FS alt: $FSTYPE_OLD"
echo "  Label:  $LABEL_OLD"
if [[ "$KIND" == "INTERN" ]]; then
  echo
  echo "🚨 ACHTUNG: INTERNES LAUFWERK!"
  echo "    Stelle sicher, dass dies NICHT die Systemplatte ist."
fi
echo
read -rp "Alle Daten auf $DEV werden GELÖSCHT. Bestätige mit 'YES': " confirm
[[ "$confirm" != "YES" ]] && { echo "Abgebrochen."; exit 0; }

########################################
# Dateisystem wählen
########################################
echo
echo "Neues Dateisystem wählen:"
echo "  [1] FAT32  (vfat, sehr kompatibel)"
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

read -rp "Neues Label (Name des Laufwerks): " NEWLABEL
[[ -z "$NEWLABEL" ]] && { echo "Label darf nicht leer sein."; exit 1; }

########################################
# Umount & Partition neu anlegen
########################################
echo
echo "Unmount & neue Partitionstabelle auf $DEV..."

# Alle Partitionen dieses Devices aushängen
lsblk -no NAME,MOUNTPOINT "$DEV" | tail -n +2 | while read -r name mp; do
  if [[ -n "$mp" ]]; then
    echo "  umount $mp"
    umount "$mp" || true
  fi
done

parted -s "$DEV" mklabel gpt
parted -s "$DEV" mkpart primary 1MiB 100%
PART="${DEV}1"

########################################
# Formatieren
########################################
echo
echo "📀 Formatiere → $PART als $FSTYPE (Label \"$NEWLABEL\")"

case "$FSTYPE" in
  vfat)  mkfs.vfat -F32 -n "$NEWLABEL" "$PART" ;;
  exfat) mkfs.exfat -n "$NEWLABEL" "$PART" ;;
  ntfs)  mkfs.ntfs -Q -L "$NEWLABEL" "$PART" ;;
  ext4)  mkfs.ext4 -L "$NEWLABEL" "$PART" ;;
esac

UUID=$(blkid -s UUID -o value "$PART" 2>/dev/null || true)
if [[ -z "$UUID" ]]; then
  echo "⚠ Konnte UUID von $PART nicht ermitteln. /etc/fstab-Eintrag später evtl. manuell nötig."
fi

########################################
# Mount-Variante wählen
########################################
echo
echo "Wie soll das Laufwerk eingehängt werden?"
echo "  [1] Nur temporär (jetzt mounten unter /media/$REAL_USER/$NEWLABEL)"
echo "  [2] Permanent via /etc/fstab (Auto-Mount bei jedem Boot)"
echo "  [3] Gar nicht mounten (nur formatieren)"
read -rp "→ Auswahl (1-3): " MOUNT_CHOICE

MOUNTPOINT="/media/$REAL_USER/$NEWLABEL"
mkdir -p "$MOUNTPOINT"

# Mount-Optionen für mount(8) und fstab
if [[ "$FSTYPE" == "ext4" ]]; then
  MOUNT_OPTS="defaults"
  FSTAB_OPTS="defaults,nofail,x-systemd.device-timeout=1"
else
  MOUNT_OPTS="uid=$USER_ID,gid=$USER_GID,umask=022"
  FSTAB_OPTS="defaults,nofail,uid=$USER_ID,gid=$USER_GID,umask=022,x-systemd.device-timeout=1"
fi

########################################
# Mount umsetzen
########################################
if [[ "$MOUNT_CHOICE" == "1" ]]; then
  echo
  echo "🔁 Temporäres Mounten von $PART nach $MOUNTPOINT ..."
  mount -t "$FSTYPE" -o "$MOUNT_OPTS" "$PART" "$MOUNTPOINT"
  echo "✔ Gemountet unter: $MOUNTPOINT"

elif [[ "$MOUNT_CHOICE" == "2" ]]; then
  if [[ -z "$UUID" ]]; then
    echo "❌ Keine UUID verfügbar – kann keinen /etc/fstab-Eintrag anlegen."
  else
    echo
    echo "📄 Erstelle Backup von /etc/fstab und füge neuen Eintrag hinzu..."

    BACKUP="/etc/fstab.backup-$(date +%Y%m%d-%H%M%S)"
    cp /etc/fstab "$BACKUP"
    echo "  Backup: $BACKUP"

    # Doppelten Eintrag vermeiden
    if grep -q "$UUID" /etc/fstab; then
      echo "⚠ In /etc/fstab existiert bereits ein Eintrag mit dieser UUID."
      echo "  Es wird KEIN neuer Eintrag geschrieben. Bitte manuell prüfen."
    else
      FSTAB_LINE="UUID=$UUID  $MOUNTPOINT  $FSTYPE  $FSTAB_OPTS  0  0"
      echo "$FSTAB_LINE" >> /etc/fstab
      echo "Neuer /etc/fstab-Eintrag:"
      echo "  $FSTAB_LINE"
    fi

    echo
    echo "🔁 Mounten jetzt mit: mount $MOUNTPOINT"
    mount "$MOUNTPOINT" || true
    echo "✔ Laufwerk (soweit keine Fehler) unter: $MOUNTPOINT"
  fi

elif [[ "$MOUNT_CHOICE" == "3" ]]; then
  echo
  echo "Kein Mount-Vorgang – Laufwerk bleibt ungemountet."
else
  echo
  echo "Ungültige Auswahl – kein Mount-Vorgang."
fi

########################################
# Abschluss
########################################
echo
echo "✔ Fertig!"
echo "  Gerät:     $DEV"
echo "  Partition: $PART"
echo "  FS:        $FSTYPE"
echo "  Label:     $NEWLABEL"
echo "  Typ:       $KIND"
echo
