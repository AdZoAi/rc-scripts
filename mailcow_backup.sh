#!/bin/bash

# Mailcow Encrypted Backup via Rclone Crypt
BACKUP_NAME="mailcow"
MAILCOW_DIR="/opt/mailcow-dockerized" 
TMP_DIR="/tmp/mailcow-backup"
LOG_FILE="/var/log/mailcow_backup.log"
RCLONE_CRYPT_REMOTE="mailcow_encrypted"

# Retention settings
DAILY_RETENTION_DAYS=2
WEEKLY_RETENTION_WEEKS=3
MONTHLY_RETENTION_MONTHS=3

mkdir -p "$TMP_DIR"

log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

check_mailcow_services() {
    log "Checking Mailcow services..."
    cd "$MAILCOW_DIR" || exit 1
    
    if ! docker-compose ps | grep -q "Up"; then
        log "ERROR: Some Mailcow services are not running!"
        docker-compose ps
        exit 1
    fi
}

backup_mysql() {
    log "Starting MySQL backup..."
    cd "$MAILCOW_DIR" || exit 1
    
    docker-compose exec -T mysql mysqldump \
        --default-character-set=utf8mb4 \
        --single-transaction \
        --routines \
        --triggers \
        --all-databases > "$TMP_DIR/mailcow.sql"
    
    [ $? -ne 0 ] && log "MySQL backup failed!" && exit 1
    log "MySQL backup completed"
}

full_backup() {
    local backup_type=$1
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file
    
    if [ "$backup_type" = "monthly" ]; then
        backup_file="full-monthly-$(date +%Y%m).tar.gz"
    else
        backup_file="full-$backup_type-$timestamp.tar.gz"
    fi
    
    backup_mysql
    
    log "Creating $backup_type backup package..."
    tar -czf "$TMP_DIR/$backup_file" \
        -C "$MAILCOW_DIR" \
        --exclude="data/redis" \
        --exclude="data/rspamd" \
        .
    
    log "Uploading encrypted backup..."
    rclone copy "$TMP_DIR/$backup_file" "$RCLONE_CRYPT_REMOTE:/full/" \
        --log-file="$LOG_FILE" --stats-one-line
    
    rm -f "$TMP_DIR/$backup_file" "$TMP_DIR/mailcow.sql"
}

incremental_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local snapshot_file="$TMP_DIR/last_snapshot.snar"
    
    backup_mysql
    
    log "Creating incremental package..."
    if [ -f "$snapshot_file" ]; then
        tar -czf "$TMP_DIR/incr-$timestamp.tar.gz" \
            -C "$MAILCOW_DIR" \
            --listed-incremental="$snapshot_file" \
            --exclude="data/redis" \
            --exclude="data/rspamd" \
            .
    else
        tar -czf "$TMP_DIR/incr-$timestamp.tar.gz" \
            -C "$MAILCOW_DIR" \
            --listed-incremental="$snapshot_file" \
            --exclude="data/redis" \
            --exclude="data/rspamd" \
            .
    fi
    
    rclone copy "$TMP_DIR/incr-$timestamp.tar.gz" "$RCLONE_CRYPT_REMOTE:/incremental/" \
        --log-file="$LOG_FILE" --stats-one-line
    
    rm -f "$TMP_DIR/incr-$timestamp.tar.gz" "$TMP_DIR/mailcow.sql"
}

cleanup_backups() {
    log "Cleaning up old backups..."
    
    # Daily full backups
    rclone delete "$RCLONE_CRYPT_REMOTE:/full/" \
        --include "full-daily-*" \
        --min-age "${DAILY_RETENTION_DAYS}d"
    
    # Incremental backups
    rclone delete "$RCLONE_CRYPT_REMOTE:/incremental/" \
        --include "incr-*" \
        --min-age "${DAILY_RETENTION_DAYS}d"
    
    # Weekly full backups
    rclone delete "$RCLONE_CRYPT_REMOTE:/full/" \
        --include "full-weekly-*" \
        --min-age "${WEEKLY_RETENTION_WEEKS}w"
    
    # Monthly full backups
    rclone delete "$RCLONE_CRYPT_REMOTE:/full/" \
        --include "full-monthly-*" \
        --min-age "${MONTHLY_RETENTION_MONTHS}m"
}

case "$1" in
    daily) check_mailcow_services && full_backup "daily" ;;
    weekly) check_mailcow_services && full_backup "weekly" ;;
    monthly) check_mailcow_services && full_backup "monthly" ;;
    incremental) check_mailcow_services && incremental_backup ;;
    cleanup) cleanup_backups ;;
    *) echo "Usage: $0 {daily|weekly|monthly|incremental|cleanup}"; exit 1 ;;
esac
