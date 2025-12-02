# 📦 Disk & USB Formatter for Ubuntu 24.04  
**A powerful command-line tool to safely format, partition and mount USB sticks, SD cards, external drives and internal HDD/SSD/NVMe (excluding the system drive).**

<p align="center">
  <img src="https://img.shields.io/badge/bash-v5.0+-blue?style=for-the-badge">
  <img src="https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange?style=for-the-badge">
</p>

## ⚠️ Safety Warning

This script can erase entire drives (USB or internal).  
It automatically excludes your system disk, but still:

> ⚠️ Double-check the selected device before confirming.  
> ⚠️ All data on the selected drive will be destroyed.

You must manually confirm destructive actions with:

```
YES
```

---

## ✨ Features

### 🧭 Device Selection  
- Choose between external USB drives or internal disks  
- Automatically lists:
  - Device path (/dev/sdX, /dev/nvmeXn1)
  - Total size  
  - Current filesystem  
  - Current label  
  - Model & type (USB / internal)

### 🧼 Powerful Formatting  
Automatically creates a new GPT partition table and formats with:

- FAT32 (vfat)
- exFAT
- NTFS
- EXT4

You can assign a custom label to the drive.

### 🔧 Auto-Dependency Installer  
Missing tools? The script installs them automatically:

- parted
- dosfstools
- exfatprogs
- ntfs-3g
- blkid

### 📁 Mount Options  
After formatting, choose between:

#### 1️⃣ Temporary mount (Desktop style)  
Mounts under:

```
/media/USERNAME/LABEL
```

#### 2️⃣ Permanent mount (fstab)  
Creates a correct /etc/fstab entry using:

- UUID  
- correct filesystem  
- safe mount options  
- fallbacks & systemd-safe settings  
- backup creation (/etc/fstab.backup-YYYYMMDD-HHMMSS)

Prevents duplicate UUID entries.

#### 3️⃣ No mount  
Just format and leave unmounted.

---

## 📂 Example Output (Device Selection)

```
Devices:
 [1] /dev/sdb      32G    vfat   Label="BACKUP"  USB    SanDisk Ultra
 [2] /dev/sdc      1T     ext4   Label="Data"    USB    WD Elements
 [3] /dev/nvme1n1  512G   —      Label="—"       INTERN Samsung SSD 970 EVO
```

---

## ▶️ Usage

```bash
sudo ./format-disk.sh
```

The script:

1. Installs missing dependencies  
2. Asks whether you want to format:
   - external USB drive  
   - internal drive  
3. Lists all matching devices  
4. Asks for filesystem type  
5. Asks for new label  
6. Formats the selected drive  
7. Mounts it (temporary/permanent) depending on your choice  

---

## 🧠 Internals & Logic

### 🔒 System Disk Protection  
Your root filesystem's physical device is automatically detected and excluded.

Example:

```
/dev/nvme0n1  ← system  
/dev/nvme1n1  ← allowed  
```

### ⚙️ Partitioning Logic

A fresh GPT layout is always created:

```
- new GPT
- 1 partition (100% size)
```

### 💾 Filesystem Commands

| FS Type | Command Used |
|---------|--------------|
| FAT32 | mkfs.vfat -F32 -n LABEL |
| exFAT | mkfs.exfat -n LABEL |
| NTFS  | mkfs.ntfs -Q -L LABEL |
| EXT4  | mkfs.ext4 -L LABEL |

### 🗂 fstab Safety

- Backup created on every run  
- Never duplicates UUID entries  
- Adds safe nofail and systemd timeout  
- Respects permissions for desktop usage  

Example entry:

```
UUID=1234-ABCD  /media/user/MyDrive  exfat  defaults,nofail,uid=1000,gid=1000,umask=022,x-systemd.device-timeout=1  0  0
```

---

## 🧪 Tested On

- Ubuntu 24.04 LTS (Desktop)
- Ubuntu 24.04 LTS (Server)
- Pop!_OS 22.04 / 24.04
- Debian 13

Works with:

- USB sticks  
- microSD / SD  
- SATA HDD  
- SATA SSD  
- NVMe SSD (non-system drive)  
- USB docking stations  

---

## 🤝 Contributing

Pull requests are welcome!  
If you'd like new features:

- GUI mode (Zenity version)  
- Multi-drive batch formatting  
- Logging to /var/log  
- Safety prompt for internal drives  

…feel free to open an issue.

---
