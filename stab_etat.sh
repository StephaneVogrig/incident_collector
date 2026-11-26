#!/usr/bin/env bash
# stab-etat.sh : capture l'état du système pour les tests de stabilité.
# Ne modifie RIEN sur le système : lit /etc/default/grub, /proc et /sys, écrit uniquement dans ~/stab.
#
# Usage (SANS sudo) :
#   ./stab-etat.sh origine   # une seule fois, avant tout test : sauvegardes + état de départ
#   ./stab-etat.sh courant   # état actuel, comparé à l'état d'origine
set -u

DIR="$HOME/stab"

[ "$(id -u)" -ne 0 ] || { echo "Ne pas lancer avec sudo (\$HOME serait /root)."; exit 1; }

etat() {
  date; uname -r
  echo '--- cmdline'
  cat /proc/cmdline
  echo '--- GRUB_CMDLINE (grub + grub.d)'
  grep -H '^GRUB_CMDLINE' /etc/default/grub /etc/default/grub.d/* 2>/dev/null
  echo '--- driver cpufreq / boost'
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
  cat /sys/devices/system/cpu/cpufreq/boost
  echo '--- ASPM policy'
  cat /sys/module/pcie_aspm/parameters/policy
  echo '--- NVMe pm_qos'
  grep -H . /sys/class/nvme/nvme*/power/pm_qos_latency_tolerance_us
  echo '--- GPU power/control'
  for d in /sys/bus/pci/devices/*; do
    [ "$(cut -c1-4 "$d/class")" = 0x03 ] && echo "$d $(cat "$d/power/control")"
  done
  echo '--- rfkill'
  rfkill list
}

case "${1:-}" in
  origine)
    [ ! -e "$DIR/grub.orig" ] || { echo "Sauvegarde déjà présente ($DIR/grub.orig) : rien n'a été écrasé."; exit 1; }
    mkdir -p "$DIR"
    cp /etc/default/grub "$DIR/grub.orig"
    cp /proc/cmdline "$DIR/cmdline.orig"
    etat > "$DIR/etat-origine.txt" 2>&1
    echo "Sauvegarde faite dans $DIR :"
    ls -l "$DIR"
    echo "Relis etat-origine.txt : une erreur y signale un chemin absent sur cette machine."
    ;;
  courant)
    mkdir -p "$DIR"
    etat > "$DIR/etat-courant.txt" 2>&1
    echo "État actuel écrit dans $DIR/etat-courant.txt"
    if [ -f "$DIR/etat-origine.txt" ]; then
      echo "== diff origine -> courant (la date diffère toujours) =="
      diff "$DIR/etat-origine.txt" "$DIR/etat-courant.txt" && echo "identique"
    fi
    ;;
  *)
    echo "Usage : $0 {origine|courant}"
    exit 1
    ;;
esac