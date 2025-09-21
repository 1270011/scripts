#!/bin/bash

# Proxmox ZFS Root Snapshot & Backup Script
# Creates bootable backup clone of current root filesystem

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT_NAME="daily_snapshot-${TIMESTAMP}"
BACKUP_CLONE_NAME="daily_clone-${TIMESTAMP}"
LOG_FILE="/var/log/proxmox-backup-day.log"
SESSION_LOG="DAILY SESSION BACKUP LOG from ${TIMESTAMP}"$'\n'
SCRIPT_NAME="$(basename "$0")"
RETENTION_DAYS=60  # Keep snapshots for N days

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"
      
    echo "$log_line" | tee -a "$LOG_FILE"
    SESSION_LOG+="$log_line"$'\n'
}

# Error handler
error_exit() {
    log "ERROR" "$1"
    echo "$SESSION_LOG" | mail -s "ERROR on Daily ZFS Backup Report for ${SNAPSHOT_NAME} - completed: $(date +%Y%m%d-%H%M%S)" pve@recordingbeats.net
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Check if required commands exist
for cmd in findmnt zfs; do
    if ! command -v "$cmd" &> /dev/null; then
        error_exit "Required command '$cmd' not found"
    fi
done

log "INFO" "Starting backup process with snapshot: $SNAPSHOT_NAME (retention: $RETENTION_DAYS days)"

# Get current root filesystem information
log "INFO" "Detecting current root filesystem"
ROOT_INFO=$(findmnt -n -o SOURCE /) || error_exit "Failed to get root filesystem info"
log "INFO" "Current root filesystem: $ROOT_INFO"

# Validate that we have a ZFS root
if [[ ! "$ROOT_INFO" == *"/"* ]] || [[ ! "$ROOT_INFO" == *"ROOT"* ]]; then
    error_exit "Root filesystem doesn't appear to be ZFS: $ROOT_INFO"
fi

# Extract pool and dataset name
CURRENT_DATASET="$ROOT_INFO"
log "INFO" "Current ZFS dataset: $CURRENT_DATASET"

# Create snapshot
log "INFO" "Creating snapshot: ${CURRENT_DATASET}@${SNAPSHOT_NAME}"
if zfs snapshot "${CURRENT_DATASET}@${SNAPSHOT_NAME}"; then
    log "INFO" "Snapshot created successfully"
else
    error_exit "Failed to create snapshot"
fi

# Get the pool name (everything before the first slash)
POOL_NAME="${CURRENT_DATASET%%/*}"
BACKUP_DATASET="${POOL_NAME}/ROOT/${BACKUP_CLONE_NAME}"

# Remove existing backup clone if it exists
if zfs list "$BACKUP_DATASET" &>/dev/null; then
    log "INFO" "Removing existing backup clone: $BACKUP_DATASET"
    if ! zfs destroy "$BACKUP_DATASET"; then
        error_exit "Failed to remove existing backup clone"
    fi
fi

# Create bootable clone
log "INFO" "Creating bootable clone: $BACKUP_DATASET"
if zfs clone -o mountpoint=/ -o canmount=noauto "${CURRENT_DATASET}@${SNAPSHOT_NAME}" "$BACKUP_DATASET"; then
    log "INFO" "Bootable clone created successfully"
else
    error_exit "Failed to create bootable clone"
fi

# Get current boot parameters
log "INFO" "Getting current boot parameters"
BOOT_PARAMS=$(zfs get -H -o value org.zfsbootmenu:commandline "$CURRENT_DATASET" 2>/dev/null || echo "")

if [[ -n "$BOOT_PARAMS" && "$BOOT_PARAMS" != "-" ]]; then
    log "INFO" "Current boot parameters: $BOOT_PARAMS"
    log "INFO" "Setting boot parameters for backup clone"
    
    if zfs set "org.zfsbootmenu:commandline=$BOOT_PARAMS" "$BACKUP_DATASET"; then
        log "INFO" "Boot parameters set successfully for backup clone"
    else
        error_exit "Failed to set boot parameters for backup clone"
    fi
else
    log "WARNING" "No boot parameters found for current dataset"
fi

# Copy other important ZFS boot properties if they exist
BOOT_PROPERTIES=(
    "org.zfsbootmenu:keysource"
    "org.zfsbootmenu:active"
    "org.zfsbootmenu:timeout"
)

for prop in "${BOOT_PROPERTIES[@]}"; do
    PROP_VALUE=$(zfs get -H -o value "$prop" "$CURRENT_DATASET" 2>/dev/null || echo "")
    if [[ -n "$PROP_VALUE" && "$PROP_VALUE" != "-" ]]; then
        log "INFO" "Copying property $prop=$PROP_VALUE to backup clone"
        if ! zfs set "$prop=$PROP_VALUE" "$BACKUP_DATASET"; then
            log "WARNING" "Failed to set property $prop for backup clone"
        fi
    fi
done

# Verify the backup clone
log "INFO" "Verifying backup clone"
if zfs list "$BACKUP_DATASET" &>/dev/null; then
    CLONE_SIZE=$(zfs get -H -o value used "$BACKUP_DATASET")
    log "INFO" "Backup clone verified - Size: $CLONE_SIZE"
else
    error_exit "Backup clone verification failed"
fi

# Clean up old backup clones first (before snapshots!)
log "INFO" "Cleaning up old backup clones (keeping last $RETENTION_DAYS days)"
OLD_CLONES=$(zfs list -H -t filesystem -o name -S creation 2>/dev/null | grep "${POOL_NAME}/ROOT/daily_clone-" | tail -n +$((RETENTION_DAYS + 1)) || true)

if [[ -n "$OLD_CLONES" ]]; then
    while IFS= read -r clone; do
        log "INFO" "Removing old backup clone: $clone"
        if ! zfs destroy "$clone"; then
            log "WARNING" "Failed to remove old backup clone: $clone"
        fi
    done <<< "$OLD_CLONES"
else
    log "INFO" "No old backup clones to clean up"
fi

# Clean up old snapshots after clones are gone
log "INFO" "Cleaning up old snapshots (keeping last $RETENTION_DAYS days)"
OLD_SNAPSHOTS=$(zfs list -H -t snapshot -o name -S creation 2>/dev/null | grep "${CURRENT_DATASET}@daily_snapshot-" | tail -n +$((RETENTION_DAYS + 1)) || true)

if [[ -n "$OLD_SNAPSHOTS" ]]; then
    while IFS= read -r snapshot; do
        log "INFO" "Removing old snapshot: $snapshot"
        if ! zfs destroy "$snapshot"; then
            log "WARNING" "Failed to remove old snapshot: $snapshot"
        fi
    done <<< "$OLD_SNAPSHOTS"
else
    log "INFO" "No old snapshots to clean up"
fi

log "INFO" "Backup process completed successfully"
log "INFO" "Snapshot: ${CURRENT_DATASET}@${SNAPSHOT_NAME}"
log "INFO" "Backup clone: $BACKUP_DATASET"
log "INFO" "To boot from backup, select 'daily_clone-${TIMESTAMP}' from ZFS boot menu"

echo "$SESSION_LOG" | mail -s "Daily ZFS Backup Report for ${SNAPSHOT_NAME} - completed: $(date +%Y%m%d-%H%M%S)" mail@example.com


exit 0
