#!/bin/bash
cd /home/ubuntu/vprofile
F=/tmp/logs-$(date +%F-%H%M).log.gz
docker compose logs --since 24h | gzip > "$F"
aws s3 cp "$F" s3://<BUCKET_ADI>/logs/ && rm "$F"
