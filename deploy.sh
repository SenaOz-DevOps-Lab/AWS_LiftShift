#!/bin/bash

# Degiskenler
EC2_USER="ubuntu"
EC2_IP="54.84.219.206"
KEY_PATH="~/.ssh/vprofile-key.pem"

echo "[1/2] Degisiklikler GitHub'a gonderiliyor..."
git add .
git commit -m "Auto deploy: $(date +%F-%H%M)"
git push origin main

echo "[2/2] EC2 Sunucusunda Deploy Baslatiliyor..."
ssh -i "$KEY_PATH" "$EC2_USER@$EC2_IP" << 'EOF'
  cd /home/ubuntu/vprofile
  git pull origin main
  docker compose down
  docker compose up -d --build
  echo "Deploy basariyla tamamlandi!"
EOF
