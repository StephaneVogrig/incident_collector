#!/bin/bash
# bootcfg.sh : activation / désactivation d'éléments (Ubuntu + GRUB)
#
#   sudo ./bootcfg.sh init          sauvegarde GRUB et détecte les pilotes Wi-Fi / Bluetooth
#   sudo bootcfg set <éléments>     définit l'ensemble des éléments COUPÉS (puis redémarrer)
#                                  éléments : A1 A2 B1 B2 C1 C2 | groupes A B C | all | none
#   sudo bootcfg status             affiche la config active et la ligne noyau
#   sudo bootcfg restore            restaure GRUB d'origine et désactive les overrides
#
#   A1 idle=poll                         B1 pcie_aspm=off + pcie_port_pm=off     C1 pilote Wi-Fi blacklisté
#   A2 amd_pstate=disable + boost off    B2 NVMe APST off                        C2 pilote Bluetooth blacklisté

set -u

CONF_DIR="${CONF_DIR:-/etc/bootcfg}"
GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"
CMDLINE_FILE="${CMDLINE_FILE:-/proc/cmdline}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
SELF="${SELF:-/usr/local/sbin/bootcfg}"
DRY="${BISECT_DRY:-}"
ORDER="A1 A2 B1 B2 C1 C2"

die()       { echo "ERREUR : $*" >&2; exit 1; }
need_root() { [ -n "$DRY" ] || [ "$(id -u)" -eq 0 ] || die "lance avec sudo"; }
sysd()      { [ -n "$DRY" ] || systemctl "$@"; }
has()       { case "+${CFG:-none}+" in *"+$1+"*) return 0;; esac; return 1; }

load_drivers() {
  WIFI_MOD=""; BT_MOD=""
  # shellcheck disable=SC1091
  [ -f "$CONF_DIR/drivers.conf" ] && . "$CONF_DIR/drivers.conf"
  return 0
}

detect_drivers() {
  WIFI_DET=""; BT_DET=""
  local i d
  for i in /sys/class/net/*; do
    { [ -d "$i/wireless" ] || [ -d "$i/phy80211" ]; } || continue
    d=$(readlink -f "$i/device/driver" 2>/dev/null) && WIFI_DET=$(basename "$d") && break
  done
  if [ -e /sys/class/bluetooth/hci0/device/driver ]; then
    BT_DET=$(basename "$(readlink -f /sys/class/bluetooth/hci0/device/driver)")
  fi
  if [ -z "$BT_DET" ] && lsmod 2>/dev/null | grep -q '^btusb '; then BT_DET=btusb; fi
  return 0
}

current_cfg() {
  load_drivers
  local cl c="" bl
  cl=" $(cat "$CMDLINE_FILE") "
  case "$cl" in *" idle=poll "*) c="$c+A1";; esac
  case "$cl" in *" amd_pstate=disable "*) c="$c+A2";; esac
  case "$cl" in *" pcie_aspm=off "*) case "$cl" in *" pcie_port_pm=off "*) c="$c+B1";; esac;; esac
  case "$cl" in *" nvme_core.default_ps_max_latency_us=0 "*) c="$c+B2";; esac
  bl=$(tr ' ' '\n' <<<"$cl" | sed -n 's/^modprobe\.blacklist=//p' | tr ',' '\n')
  if [ -n "$WIFI_MOD" ] && grep -qx "$WIFI_MOD" <<<"$bl"; then c="$c+C1"; fi
  if [ -n "$BT_MOD" ] && grep -qx "$BT_MOD" <<<"$bl"; then c="$c+C2"; fi
  c="${c#+}"; echo "${c:-none}"
}

expand_items() {
  local want=" " t k out=""
  for t in "$@"; do
    t="${t^^}"
    case "$t" in
      NONE) ;;
      ALL) want="$want$ORDER " ;;
      A|B|C) want="$want${t}1 ${t}2 " ;;
      A1|A2|B1|B2|C1|C2) want="$want$t " ;;
      *) die "élément inconnu : $t (A1 A2 B1 B2 C1 C2, A B C, all, none)" ;;
    esac
  done
  for k in $ORDER; do case "$want" in *" $k "*) out="$out $k";; esac; done
  ITEMS="${out# }"
}

install_boost_unit() {
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/bisect-boost.service" <<'EOF'
[Unit]
Description=Boost CPU désactivé (bisection)
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'
[Install]
WantedBy=multi-user.target
EOF
  sysd daemon-reload
}

cmd_init() {
  need_root
  if [ -z "$DRY" ]; then command -v update-grub >/dev/null || die "update-grub absent (GRUB requis)"; fi
  [ -f "$GRUB_FILE" ] || die "$GRUB_FILE introuvable"
  mkdir -p "$CONF_DIR"
  [ -f "$CONF_DIR/grub.orig" ] || cp "$GRUB_FILE" "$CONF_DIR/grub.orig"

  load_drivers; detect_drivers
  [ -n "$WIFI_MOD" ] || WIFI_MOD="$WIFI_DET"
  [ -n "$BT_MOD" ]   || BT_MOD="$BT_DET"
  printf 'WIFI_MOD=%s\nBT_MOD=%s\n' "$WIFI_MOD" "$BT_MOD" > "$CONF_DIR/drivers.conf"

  [ "$(readlink -f "$0")" = "$(readlink -f "$SELF" 2>/dev/null)" ] || install -m 0755 "$0" "$SELF"
  install_boost_unit

  echo "Pilote Wi-Fi : ${WIFI_MOD:-NON DÉTECTÉ} | Bluetooth : ${BT_MOD:-NON DÉTECTÉ} (${CONF_DIR}/drivers.conf)"
  echo "Prêt. Utilise : sudo bisect set <none|all|A|B|C|A1..C2>"
}

cmd_set() {
  need_root; load_drivers
  [ $# -ge 1 ] || die "usage : bisect set <none|all|A|B|C|A1|A2|B1|B2|C1|C2 ...>"
  [ -f "$CONF_DIR/grub.orig" ] || die "lance d'abord : sudo ./bisect.sh init"
  expand_items "$@"
  CFG="${ITEMS// /+}"; CFG="${CFG:-none}"

  local toks="" bl=""
  has A1 && toks="$toks idle=poll"
  has A2 && toks="$toks amd_pstate=disable"
  has B1 && toks="$toks pcie_aspm=off pcie_port_pm=off"
  has B2 && toks="$toks nvme_core.default_ps_max_latency_us=0"
  if has C1; then [ -n "$WIFI_MOD" ] || die "pilote Wi-Fi inconnu (${CONF_DIR}/drivers.conf)"; bl="$WIFI_MOD"; fi
  if has C2; then [ -n "$BT_MOD" ]   || die "pilote Bluetooth inconnu (${CONF_DIR}/drivers.conf)"; bl="${bl:+$bl,}$BT_MOD"; fi
  [ -n "$bl" ] && toks="$toks modprobe.blacklist=$bl"

  local line cur kept="" t new
  line=$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE") || die "GRUB_CMDLINE_LINUX_DEFAULT introuvable"
  cur="${line#GRUB_CMDLINE_LINUX_DEFAULT=}"
  case "$cur" in \"*\") cur="${cur#\"}"; cur="${cur%\"}";; *) die "format inattendu : $line";; esac
  for t in $cur; do
    case "$t" in
      idle=poll|amd_pstate=disable|pcie_aspm=off|pcie_port_pm=off|nvme_core.default_ps_max_latency_us=0|modprobe.blacklist=*) ;;
      *) kept="$kept $t" ;;
    esac
  done
  # shellcheck disable=SC2086
  new=$(echo $kept $toks)
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" "$GRUB_FILE"
  [ -n "$DRY" ] || update-grub >/dev/null 2>&1 || die "update-grub a échoué"

  [ -f "$UNIT_DIR/bisect-boost.service" ] || install_boost_unit
  if has A2; then sysd enable bisect-boost.service >/dev/null 2>&1; else sysd disable bisect-boost.service >/dev/null 2>&1; fi

  echo "Éléments coupés : ${ITEMS:-aucun} (config $CFG)"
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\""
  echo "Redémarre pour appliquer."
}

cmd_status() {
  echo "Config active (éléments coupés) : $(current_cfg)"
  echo "Ligne noyau : $(cat "$CMDLINE_FILE")"
}

cmd_restore() {
  need_root
  if [ -f "$CONF_DIR/grub.orig" ]; then
    cp "$CONF_DIR/grub.orig" "$GRUB_FILE"
    [ -n "$DRY" ] || update-grub >/dev/null 2>&1
  fi
  sysd disable --now bisect-boost.service >/dev/null 2>&1
  rm -f "$UNIT_DIR/bisect-boost.service"
  sysd daemon-reload
  echo "Restauré (GRUB d'origine et service boost supprimé). Redémarre pour appliquer."
}

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  init)    cmd_init ;;
  set)     shift; cmd_set "$@" ;;
  status)  cmd_status ;;
  restore) cmd_restore ;;
  *)       usage ;;
esac
