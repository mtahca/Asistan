#!/bin/bash
# Sürücüyü kaldırır ve Core Audio'yu yeniden başlatır.
set -euo pipefail
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/AsistanSes.driver"
sudo killall coreaudiod
echo "AsistanSes sürücüsü kaldırıldı."
