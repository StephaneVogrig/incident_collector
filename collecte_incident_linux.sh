#!/usr/bin/env bash
# Collecte en LECTURE SEULE après un gel sous Linux (ROG Strix G713QM).
# Usage : bash collecte_gel_linux.sh [BOOT]
#   BOOT = numéro de démarrage journald du boot gelé (défaut : -1 = le précédent).
#   Vérifiez d'abord avec : journalctl --list-boots | tail -5
# Aucune modification du système : le script ne fait que lire et écrire dans OUT.

BOOT="${1:--1}"
STAMP="$(date +%F_%H%M)"
OUT="$HOME/diag_gel_linux${STAMP}"
mkdir -p "$OUT"
R="$OUT/rapport.txt"

section() { printf '\n\n===== %s =====\n' "$1" | tee -a "$R" >/dev/null; }
run()     { printf '\n$ %s\n' "$*" >>"$R"; "$@" >>"$R" 2>&1; }
sh_run()  { printf '\n$ %s\n' "$1" >>"$R"; bash -c "$1" >>"$R" 2>&1; }

{
  echo "Rapport de collecte - généré le $(date '+%F %T')"
  echo "Boot analysé (journald) : $BOOT"
  echo
  echo "À COMPLÉTER À LA MAIN (non déductible des logs) :"
  echo "  Symptômes (écran interne, HDMI, clavier, Verr. Maj) :"
  echo "  Activité réellement en cours :"
  echo "  Secteur / batterie AU MOMENT DU GEL (non journalisé par défaut) :"
  echo "  Démarrage précédent : arrêt complet / redémarrage / depuis Windows (démarrage rapide ?) :"
} >"$R"

section "A. Résumé automatique du boot analysé ($BOOT)"
fmt() { date -d "@$1" '+%F %T' 2>/dev/null; }
J() { journalctl -b "$1" -o short-unix --no-pager 2>/dev/null; }
first_line=$(J "$BOOT" | grep -m1 -E '^[0-9]')
last_line=$(journalctl -b "$BOOT" -o short-unix -n 1 --no-pager 2>/dev/null | grep -E '^[0-9]' | tail -1)
FIRST=${first_line%%.*}; LAST=${last_line%%.*}
NEXT=$((BOOT+1))
next_line=$(J "$NEXT" | grep -m1 -E '^[0-9]'); NEXTB=${next_line%%.*}
{
  if [[ "$FIRST" =~ ^[0-9]+$ && "$LAST" =~ ^[0-9]+$ ]]; then
    echo "Début du boot (1er message)    : $(fmt "$FIRST")"
    echo "HEURE DU GEL (dernier message) : $(fmt "$LAST")   <- approximative : un léger retard d'écriture est possible"
    echo "Durée avant le gel (uptime)    : $(( (LAST-FIRST)/3600 )) h $(( ((LAST-FIRST)%3600)/60 )) min"
    if [[ "$NEXTB" =~ ^[0-9]+$ ]]; then
      echo "Démarrage suivant              : $(fmt "$NEXTB")   (écart avec le gel : $(( (NEXTB-LAST)/60 )) min)"
    fi
    sleeps=$(J "$BOOT" | grep -E 'PM: suspend (entry|exit)')
    if [ -z "$sleeps" ]; then
      echo "Veille dans ce boot            : aucune trace"
    else
      lastexit=$(echo "$sleeps" | grep 'suspend exit' | tail -1); LE=${lastexit%%.*}
      echo "Veille dans ce boot            : $(echo "$sleeps" | grep -c 'suspend entry') entrée(s)"
      [[ "$LE" =~ ^[0-9]+$ ]] && echo "Dernier réveil de veille       : $(fmt "$LE") (soit $(( (LAST-LE)/60 )) min avant le gel)"
    fi
    echo
    echo "Sources de messages dans les 5 dernières minutes avant le gel (indice d'activité) :"
    journalctl -b "$BOOT" --since "@$((LAST-300))" -o short-unix --no-pager 2>/dev/null \
      | grep -E '^[0-9]' | awk '{print $3}' | sed -E 's/\[[0-9]+\]:?$//; s/:$//' \
      | sort | uniq -c | sort -rn | head -12
  else
    echo "Boot $BOOT introuvable ou journal vide (journal non persistant ? droits ?). Voir section 2."
  fi
  echo
  echo "Alimentation à l'instant T du gel : NON récupérable a posteriori (pas journalisée par défaut)."
  echo "État ACTUEL (≠ au moment du gel) :"
  for f in /sys/class/power_supply/*; do
    echo "  $(basename "$f"): type=$(cat "$f/type" 2>/dev/null) online=$(cat "$f/online" 2>/dev/null) status=$(cat "$f/status" 2>/dev/null) capacity=$(cat "$f/capacity" 2>/dev/null)"
  done
} >>"$R"
sed -n '/===== A\./,$p' "$R" | head -30

section "0. Droits d'accès au journal"
sh_run "id -nG"
if ! id -nG | grep -qwE 'adm|systemd-journal' && [ "$(id -u)" -ne 0 ]; then
  echo "ATTENTION : ni adm ni systemd-journal. Relancez avec sudo si les sections journal sont vides." | tee -a "$R"
fi

section "1. Contexte système actuel"
run uname -r
sh_run "cat /proc/cmdline"
run uptime -s
sh_run "last -x -n 12 | head -20"
sh_run "for f in /sys/class/power_supply/*; do echo \"\$f: \$(cat \$f/type 2>/dev/null) \$(cat \$f/online 2>/dev/null) \$(cat \$f/status 2>/dev/null) \$(cat \$f/capacity 2>/dev/null)%\"; done"

section "2. Démarrages journald et persistance"
sh_run "journalctl --list-boots | tail -8"
sh_run "ls -ld /var/log/journal 2>&1"
run journalctl --disk-usage
sh_run "ls -lh /var/log/syslog 2>&1"
sh_run "df -h / | tail -2"

section "3. Fin du boot analysé ($BOOT)"
sh_run "journalctl -b $BOOT -n 1 --no-pager -o short-iso"
sh_run "journalctl -b $BOOT -n 150 --no-pager -o short-iso"
journalctl -b "$BOOT" -n 150 --no-pager -o short-iso >"$OUT/fin_du_boot.txt" 2>&1

section "4. Lignes suspectes du boot analysé (matériel, graphique, énergie)"
sh_run "journalctl -b $BOOT --no-pager -o short-iso | grep -iE 'amdgpu|nvidia|NVRM|Xid|drm|snd_hda|aer|pcie|mce|hardware error|lockup|watchdog|power state|soft lockup|rcu|hung task|segfault|oops|panic|BUG:' | tail -80"
sh_run "journalctl -b $BOOT -p err --no-pager -o short-iso | tail -60"
sh_run "journalctl -b $BOOT --no-pager | grep -ciE 'messages suppressed|suppressed [0-9]+ messages'"

section "5. Traces de crash persistantes (pstore, coredumps)"
sh_run "ls -la /sys/fs/pstore /var/lib/systemd/pstore 2>&1"
sh_run "ls -la /var/crash 2>&1 | tail -10"

section "6. États d'énergie des périphériques clés"
for d in 0000:01:00.0 0000:06:00.0 0000:06:00.1; do
  sh_run "echo $d; lspci -s ${d#0000:} 2>&1; for a in runtime_status control; do echo \"  \$a: \$(cat /sys/bus/pci/devices/$d/power/\$a 2>/dev/null)\"; done"
done
sh_run "prime-select query 2>&1"
sh_run "nvidia-smi --query-gpu=name,driver_version,pstate,power.draw --format=csv 2>&1"
sh_run "grep -rH -iE 'DynamicPowerManagement|NVreg' /etc/modprobe.d /proc/driver/nvidia/params 2>/dev/null"

section "7. C-states et paramètres amdgpu actifs"
sh_run "for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do echo \"\$(basename \$s): \$(cat \$s/name) lat=\$(cat \$s/latency)us\"; done"
sh_run "for p in runpm dcdebugmask ppfeaturemask; do echo \"amdgpu.\$p = \$(cat /sys/module/amdgpu/parameters/\$p 2>/dev/null)\"; done"
sh_run "grep -iE 'processor.max_cstate|amdgpu|nvidia' /etc/default/grub"

section "8. Firmware et microcode"
sh_run "sudo -n dmidecode -s bios-version 2>/dev/null || cat /sys/class/dmi/id/bios_version"
sh_run "journalctl -k -b 0 --no-pager | grep -iE 'microcode' | head -3"

# Archive pour transfert vers Windows
tar -czf "$OUT.tar.gz" -C "$HOME" "$(basename "$OUT")" 2>/dev/null

echo
echo "Terminé. Rapport : $R"
echo "Archive : $OUT.tar.gz"
echo "Pour consulter : less $R"
