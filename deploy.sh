#!/bin/bash

# Degiskenler
EC2_USER="ubuntu"
EC2_IP="<EC2_PUBLIC_IP>"
KEY_PATH="$HOME/.ssh/<ANAHTAR_DOSYASI>.pem"

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
