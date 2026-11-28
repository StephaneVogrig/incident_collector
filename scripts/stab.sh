#!/usr/bin/env bash
# Tests de stabilité (ROG Strix G713QM)
# Usage : sudo ./stab.sh {save|runtime|restore|grub|grub-restore|status}
set -u

STATE_DIR=/var/lib/stab
STATE=$STATE_DIR/state          # valeurs de départ (sysfs), jamais écrasées
GRUB_BAK=$STATE_DIR/grub.orig   # copie de /etc/default/grub d'origine

# Paramètres noyau à ajouter (édite cette liste pour réintégrer par blocs)
PARAMS="idle=poll amd_pstate=disable pcie_aspm=off pcie_port_pm=off nvme_core.default_ps_max_latency_us=0 amdgpu.dcdebugmask=0x10 amdgpu.sg_display=0 amdgpu.runpm=0"

[ "$(id -u)" -eq 0 ] || { echo "root requis"; exit 1; }
mkdir -p "$STATE_DIR"

# Lit une valeur sysfs ; extrait la valeur entre [] si présente (ex. policy ASPM)
rd() {
  local v
  v=$(cat "$1" 2>/dev/null) || return 1
  case $v in *\[*) v=${v#*[}; v=${v%%]*} ;; esac
  echo "$v"
}

# Chemins sysfs modifiés à chaud
targets() {
  echo /sys/devices/system/cpu/cpufreq/boost
  ls /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]*/disable 2>/dev/null
  ls /sys/class/nvme/nvme*/power/pm_qos_latency_tolerance_us 2>/dev/null
  echo /sys/module/pcie_aspm/parameters/policy
  for d in /sys/bus/pci/devices/*; do
    [ "$(cut -c1-4 "$d/class")" = 0x03 ] && echo "$d/power/control"
  done
}

w() { echo "$2" > "$1" 2>/dev/null && echo "ok     $1 = $2" || echo "ÉCHEC  $1"; }

save() {
  if [ -f "$STATE" ]; then
    echo "Référence déjà enregistrée ($STATE), conservée."
    return
  fi
  targets | while read -r p; do
    [ -w "$p" ] && v=$(rd "$p") && printf '%s\t%s\n' "$p" "$v"
  done > "$STATE"
  cp /proc/cmdline "$STATE_DIR/cmdline.orig"
  echo "Référence enregistrée dans $STATE"
}

runtime() {
  save
  # CPU : boost off, C-states >= C2 off (équivalent max_cstate=1 ; C1 conservé)
  w /sys/devices/system/cpu/cpufreq/boost 0
  for f in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]*/disable; do [ -e "$f" ] && w "$f" 1; done
  # NVMe : pas d'états d'énergie profonds (APST)
  for f in /sys/class/nvme/nvme*/power/pm_qos_latency_tolerance_us; do [ -e "$f" ] && w "$f" 0; done
  # PCIe ASPM : politique performance (pcie_aspm=off complet = cmdline)
  [ -w /sys/module/pcie_aspm/parameters/policy ] && w /sys/module/pcie_aspm/parameters/policy performance
  # GPU(s) : pas de runtime PM
  for d in /sys/bus/pci/devices/*; do
    [ "$(cut -c1-4 "$d/class")" = 0x03 ] && w "$d/power/control" on
  done
  # Wi-Fi / Bluetooth coupés
  rfkill block wifi bluetooth && echo "ok     wifi+bluetooth bloqués"
}

restore() {
  [ -f "$STATE" ] || { echo "Pas de référence ($STATE)"; exit 1; }
  while IFS=$'\t' read -r p v; do w "$p" "$v"; done < "$STATE"
  rfkill unblock wifi bluetooth && echo "ok     wifi+bluetooth débloqués"
}

regen() {
  if command -v update-grub >/dev/null; then update-grub
  elif [ -d /boot/grub2 ]; then grub2-mkconfig -o /boot/grub2/grub.cfg
  else grub-mkconfig -o /boot/grub/grub.cfg; fi
}

grub_apply() {
  [ -f "$GRUB_BAK" ] || cp /etc/default/grub "$GRUB_BAK"
  cp "$GRUB_BAK" /etc/default/grub   # repart de l'original : idempotent
  sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 $PARAMS\"|" /etc/default/grub
  grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub
  regen
  echo "Redémarre pour appliquer."
}

grub_restore() {
  [ -f "$GRUB_BAK" ] || { echo "Pas de sauvegarde GRUB"; exit 1; }
  cp "$GRUB_BAK" /etc/default/grub
  regen
  echo "Redémarre pour appliquer."
}

status() {
  echo "== cmdline actuelle ==";  cat /proc/cmdline
  [ -f "$STATE_DIR/cmdline.orig" ] && { echo "== cmdline de référence =="; cat "$STATE_DIR/cmdline.orig"; }
  echo "== sysfs : chemin | actuel | référence =="
  targets | while read -r p; do
    ref=$(awk -F'\t' -v p="$p" '$1==p{print $2}' "$STATE" 2>/dev/null)
    printf '%s | %s | %s\n' "$p" "$(rd "$p")" "${ref:--}"
  done
  rfkill list
}

case "${1:-}" in
  save)         save ;;
  runtime)      runtime ;;
  restore)      restore ;;
  grub)         grub_apply ;;
  grub-restore) grub_restore ;;
  status)       status ;;
  *) echo "Usage : $0 {save|runtime|restore|grub|grub-restore|status}"; exit 1 ;;
esac
