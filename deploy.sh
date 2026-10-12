#!/bin/bash

EC2_USER="ubuntu"
EC2_IP="172-31-39-24"                  # EC2 sunucunun IP adresi
KEY_PATH="~/.ssh/vprofile-key.pem"      # .pem anahtar dosyanın yolu

echo "🚀 1. Değişiklikler GitHub'a gönderiliyor..."
git add .
git commit -m "Auto deploy: $(date +%F-%H%M)"
git push origin main

echo "🔄 2. EC2 Sunucusunda Deploy Başlatılıyor..."
ssh -i "$KEY_PATH" "$EC2_USER@$EC2_IP" << 'EOF'
  cd /home/ubuntu/vprofile
  git pull origin main
  docker compose down
  docker compose up -d --build
  echo "✅ Deploy başarıyla tamamlandı!"
EOF
