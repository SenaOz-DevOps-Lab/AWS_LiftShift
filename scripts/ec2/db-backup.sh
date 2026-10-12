#!/bin/bash

CONTAINER_NAME="vprofile-vprodb-1"
BUCKET_NAME="<BUCKET_ADI>"
DATE=$(date +%F-%H%M)
BACKUP_FILE="/tmp/vprodb-backup-${DATE}.sql.gz"

# MySQL yedek al (root sifresi ile)
docker exec "$CONTAINER_NAME" mysqldump -u root -p<DB_SIFRESI> accounts | gzip > "$BACKUP_FILE"

# S3'e yukle ve gecici dosyayi sil
aws s3 cp "$BACKUP_FILE" "s3://${BUCKET_NAME}/db-backups/" && rm "$BACKUP_FILE"
