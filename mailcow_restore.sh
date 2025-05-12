#!/bin/bash

# Mailcow Encrypted Restore via Rclone Crypt
MAILCOW_DIR="/opt/mailcow-dockerized"
TMP_DIR="/tmp/mailcow-restore"
LOG_FILE="/var/log/mailcow_restore.log"
RCLONE_CRYPT_REMOTE="mailcow_encrypted"

mkdir -p "$TMP_DIR"

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

restore_mysql() {
    local sql_file="$1"
    log "Restoring MySQL databases..."
    
    cd "$MAILCOW_DIR" || exit 1
    docker-compose exec -T mysql mysql < "$sql_file" || {
        log "MySQL restore failed!"
        exit 1
    }
}

full_restore() {
    local backup_timestamp="$1"
    
    log "Finding backup..."
    if [ -z "$backup_timestamp" ]; then
        backup_file=$(rclone lsf "$RCLONE_CRYPT_REMOTE:/full/" | grep "full-" | sort | tail -n1)
    else
        backup_file=$(rclone lsf "$RCLONE_CRYPT_REMOTE:/full/" | grep "$backup_timestamp")
    fi
    
    [ -z "$backup_file" ] && log "Backup not found!" && exit 1
    
    log "Downloading $backup_file..."
    rclone copyto "$RCLONE_CRYPT_REMOTE:/full/$backup_file" "$TMP_DIR/restore.tar.gz"
    
    log "Stopping Mailcow..."
    cd "$MAILCOW_DIR" && docker-compose down
    
    log "Restoring files..."
    tar -xzf "$TMP_DIR/restore.tar.gz" -C "$MAILCOW_DIR"
    
    log "Restoring MySQL..."
    tar -xzf "$TMP_DIR/restore.tar.gz" -C "$TMP_DIR" --wildcards '*/mailcow.sql'
    restore_mysql "$TMP_DIR/mailcow.sql"
    
    rm -f "$TMP_DIR/restore.tar.gz" "$TMP_DIR/mailcow.sql"
    log "Full restore complete. Start Mailcow manually."
}

incremental_restore() {
    local target_timestamp="$1"
    
    log "Finding latest full backup..."
    full_backup=$(rclone lsf "$RCLONE_CRYPT_REMOTE:/full/" | grep "full-" | sort | tail -n1)
    [ -z "$full_backup" ] && log "No full backup found!" && exit 1
    
    log "Downloading base $full_backup..."
    rclone copyto "$RCLONE_CRYPT_REMOTE:/full/$full_backup" "$TMP_DIR/base.tar.gz"
    
    log "Finding incrementals..."
    if [ -z "$target_timestamp" ]; then
        incrementals=($(rclone lsf "$RCLONE_CRYPT_REMOTE:/incremental/" | grep "incr-" | sort))
    else
        incrementals=($(rclone lsf "$RCLONE_CRYPT_REMOTE:/incremental/" | grep "incr-" | sort | awk -v ts="$target_timestamp" '$0 <= ts'))
    fi
    
    log "Stopping Mailcow..."
    cd "$MAILCOW_DIR" && docker-compose down
    
    log "Restoring base..."
    tar -xzf "$TMP_DIR/base.tar.gz" -C "$MAILCOW_DIR"
    
    for incr in "${incrementals[@]}"; do
        log "Applying $incr..."
        rclone copyto "$RCLONE_CRYPT_REMOTE:/incremental/$incr" "$TMP_DIR/incr.tar.gz"
        tar -xzf "$TMP_DIR/incr.tar.gz" -C "$MAILCOW_DIR"
        rm -f "$TMP_DIR/incr.tar.gz"
    done
    
    log "Restoring latest MySQL..."
    latest_sql=$(find "$MAILCOW_DIR" -name mailcow.sql -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2)
    [ -n "$latest_sql" ] && restore_mysql "$latest_sql"
    
    rm -f "$TMP_DIR/base.tar.gz"
    log "Incremental restore complete. Start Mailcow manually."
}

case "$1" in
    full) full_restore "$2" ;;
    incremental) incremental_restore "$2" ;;
    *) echo "Usage: $0 {full|incremental} [timestamp]"; exit 1 ;;
esac
