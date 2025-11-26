#!/bin/bash
set -e

echo "⬆️ Iniciando atualização"
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt autoclean

echo "🔨 Instalando clamav"
sudo apt install -y clamav clamav-daemon

echo "📝 Configurando clamav"
sudo systemctl stop clamav-freshclam
sudo freshclam
sudo systemctl start clamav-freshclam

echo "✅ Atualização completa e ClamAV instalado."
