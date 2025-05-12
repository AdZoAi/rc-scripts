# Full daily backup at midnight
0 0 * * * /usr/local/bin/mailcow_backup.sh daily

# Incremental backups every 15 minutes
*/15 * * * * /usr/local/bin/mailcow_backup.sh incremental

# Weekly backup on Sunday at 1am
0 1 * * 0 /usr/local/bin/mailcow_backup.sh weekly

# Monthly backup on 1st of month at 2am
0 2 1 * * /usr/local/bin/mailcow_backup.sh monthly

# Cleanup at 3am daily
0 3 * * * /usr/local/bin/mailcow_backup.sh cleanup
