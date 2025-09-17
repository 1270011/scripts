zfs receive rpool/ROOT/weekly-restored < /mnt/usb/zfs-backups/weekly_snapshot-20250917-0111.zfs

# boot params aktueller fmount anschauen und setzen (pve-1 ersetzen durch das aktuelle, zu finden mit 'findmnt /')
BOOT_PARAMS=$(zfs get -H -o value org.zfsbootmenu:commandline rpool/ROOT/pve-1)
zfs set org.zfsbootmenu:commandline="$BOOT_PARAMS" rpool/ROOT/weekly-restored

# 2. Mount-Properties setzen
zfs set canmount=noauto rpool/ROOT/weekly-restored
zfs set mountpoint=/ rpool/ROOT/weekly-restored

# 3. Optional: Timeout auch kopieren
zfs set org.zfsbootmenu:timeout=30 rpool/ROOT/weekly-restored

reboot

#### zusätzliche Infos:
findmnt muss das hier an options ausgeben:
findmnt /
TARGET SOURCE           FSTYPE OPTIONS
/      rpool/ROOT/pve-1 zfs    rw,relatime,xattr,posixacl,casesensitive

setzbar via:
CURRENT_ROOT=$(findmnt -n -o SOURCE /)
ACL_TYPE=$(zfs get -H -o value acltype "$CURRENT_ROOT")
zfs set acltype="$ACL_TYPE" rpool/ROOT/weekly-restored
