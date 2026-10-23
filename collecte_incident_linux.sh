#!/usr/bin/env bash
# collecte_incident_linux.sh
# Collecte en LECTURE SEULE après un gel sous Linux (ROG Strix G713QM).
# Produit UN SEUL fichier Markdown : ~/AAAA_MM_JJ_incident_linux_HHhMM.md
#
# Usage : bash collecte_incident_linux.sh [BOOT]
#   BOOT = indice journald du boot gelé (ex. -1, -2).
#   Sans argument : le script retient le boot le plus récent SANS arrêt propre
#   et d'au moins 10 s (voir le tableau des boots dans le rapport).
#
# Nom du fichier : date et heure du DERNIER MESSAGE journalisé du boot gelé
#   (borne basse de l'heure du gel, pas l'heure de la collecte).
#   Heure indéterminable : AAAA_MM_JJ_incident_linux_heure_inconnue_collecte_HHhMM.md
#   Fichier déjà existant : suffixe _2, _3, ... (jamais d'écrasement).
#
# Durées et fenêtres : calculées avec l'horloge MONOTONIC du noyau, insensible aux
#   sauts d'horloge (décalage RTC Windows/Linux de 2 h, resynchronisation NTP).
# Aucune modification du système : le script ne fait que lire.

VERSION="2.2"
MAX_LINE_LENGTH=400     # longueur max d'une ligne dans le rapport
NB_BOOTS=8              # nombre de boots récents listés
MIN_UPTIME_SEC=10       # un boot plus court que ça n'est pas retenu automatiquement
CLOCK_TOLERANCE_SEC=30  # écart toléré entre durée murale et monotonic (au-delà : signalé)
ACTIVITY_WINDOW_SEC=300 # fenêtre d'analyse de l'activité avant le dernier message
HEARTBEAT_MIN_SAMPLES=3 # passages de geoclue nécessaires pour estimer la période

# Rapport et fichiers temporaires lisibles par le seul propriétaire (il contient des données personnelles)
umask 077

# Locale fixe : évite les séparateurs décimaux et les messages localisés dans les parties analysées
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; else export LC_ALL=C; fi

ARG_BOOT="${1:-}"

if [ -n "$ARG_BOOT" ] && ! [[ "$ARG_BOOT" =~ ^-?[0-9]+$ ]]; then
  echo "Argument invalide : '$ARG_BOOT' (attendu : un entier, ex. -1)." >&2
  exit 2
fi

if ! command -v journalctl >/dev/null 2>&1; then
  echo "journalctl introuvable : ce script exige systemd-journald." >&2
  exit 1
fi

# --- Dossier de sortie (gère « sudo bash script.sh » : on écrit chez l'utilisateur) ---
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  OUTDIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  RUN_AS="$SUDO_USER"
else
  OUTDIR="$HOME"
  RUN_AS=""
fi
[ -d "$OUTDIR" ] || OUTDIR="$HOME"

TMP="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
BODY="$TMP/body.md"; SUMMARY="$TMP/summary.md"; UNREAD="$TMP/unread.txt"
: >"$BODY"; : >"$SUMMARY"; : >"$UNREAD"

# --- Droits : certaines lectures (pstore, hwclock) demandent root ---
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
  CAN_PRIV=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"; CAN_PRIV=1
elif command -v sudo >/dev/null 2>&1 && [ -t 0 ]; then
  echo "Certaines lectures (pstore, hwclock) demandent sudo. Mot de passe, ou Ctrl+D pour ignorer."
  if sudo -v; then SUDO="sudo -n"; CAN_PRIV=1; else CAN_PRIV=0; fi
else
  CAN_PRIV=0
fi

# --- Droits de lecture du journal : sans root ni groupe adm/systemd-journal/wheel, il est incomplet ---
JOURNAL_WARN=""
if [ "$(id -u)" -ne 0 ] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qxE 'adm|systemd-journal|wheel'; then
  JOURNAL_WARN="l'utilisateur n'appartient ni à adm, ni à systemd-journal, ni à wheel : le journal système peut être INCOMPLET ou vide (relancer avec sudo)."
  echo "ATTENTION : $JOURNAL_WARN" >&2
fi

# --- Utilitaires ---
fmt() { date -d "@$1" '+%F %T' 2>/dev/null || echo "?"; }
dur() { local s=$1; printf '%d h %02d min %02d s' $((s/3600)) $(((s%3600)/60)) $((s%60)); }
isnum() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

trunc() {
  if command -v perl >/dev/null 2>&1; then
    MAX_LINE_LENGTH="$MAX_LINE_LENGTH" perl -CS -ne 'chomp; $_ = substr($_,0,$ENV{MAX_LINE_LENGTH})." […tronqué]" if length($_) > $ENV{MAX_LINE_LENGTH}; print "$_\n"' 2>/dev/null
  else
    cut -c1-"$MAX_LINE_LENGTH"
  fi
}

h2()   { printf '\n## %s\n' "$1" >>"$BODY"; }
note() { printf '\n%s\n' "$1" >>"$BODY"; }

# emit "commande" : exécute via bash -c, met la commande et sa sortie dans un bloc de code
emit() {
  {
    printf '\n~~~text\n$ %s\n' "$1"
    bash -c "$1" 2>&1 | trunc | sed 's/^~~~/ ~~~/'
    printf '~~~\n'
  } >>"$BODY"
}

# emit_priv "commande" : idem avec root si possible, sinon l'indique dans le rapport
emit_priv() {
  if [ "$CAN_PRIV" = "1" ]; then
    {
      printf '\n~~~text\n$ sudo %s\n' "$1"
      $SUDO bash -c "$1" 2>&1 | trunc | sed 's/^~~~/ ~~~/'
      printf '~~~\n'
    } >>"$BODY"
  else
    printf '\n~~~text\n$ sudo %s\n(NON LU : droits root indisponibles)\n~~~\n' "$1" >>"$BODY"
    echo "$1" >>"$UNREAD"
  fi
}

# --- Fonctions journald (une valeur par appel ; vide si introuvable) ---
last_unix()  { journalctl -b "$1" -n 1 -o short-unix --no-pager 2>/dev/null | grep -E '^[0-9]+\.' | cut -d. -f1; }
first_unix() { journalctl -b "$1" -o short-unix --no-pager 2>/dev/null | grep -m1 -E '^[0-9]+\.' | cut -d. -f1; }
last_mono()  { journalctl -b "$1" -n 1 -o short-monotonic --no-pager 2>/dev/null | sed -nE 's/^\[ *([0-9]+)\..*/\1/p'; }
first_mono() { journalctl -b "$1" -o short-monotonic --no-pager 2>/dev/null | sed -nE '/^\[ *([0-9]+)\./ { s/^\[ *([0-9]+)\..*/\1/p; q; }'; }
clean_shutdown() {
  journalctl -b "$1" -n 300 --no-pager 2>/dev/null \
    | grep -qiE 'Reached target (System )?(Shutdown|Power-Off|Reboot|Final Step)|Journal stopped|systemd-shutdown\[|Shutting down\.'
}


# --- Inventaire PCI dynamique : GPU et périphériques associés ---
collect_pci_inventory() {
  {
    echo
    echo "### Inventaire PCI détecté dynamiquement"
    echo
    echo "> État relevé au moment de la collecte, après le redémarrage éventuel."
    echo "> Les états actuels ne prouvent pas l'état du matériel au moment du gel."
    echo

    if ! command -v lspci >/dev/null 2>&1; then
      echo "**lspci indisponible** : installer le paquet pciutils pour obtenir les noms et pilotes."
      echo
    fi

    if [ ! -d /sys/bus/pci/devices ]; then
      echo "**/sys/bus/pci/devices indisponible**."
      echo
      return
    fi

    local p bdf class vendor device driver subsystem
    local runtime control status autosuspend
    local gpu_count=0 pci_count=0

    for p in /sys/bus/pci/devices/*; do
      [ -e "$p" ] || continue

      bdf="${p##*/}"
      class=$(cat "$p/class" 2>/dev/null || echo inconnu)
      vendor=$(cat "$p/vendor" 2>/dev/null || echo inconnu)
      device=$(cat "$p/device" 2>/dev/null || echo inconnu)
      subsystem=$(cat "$p/subsystem_vendor" 2>/dev/null || echo inconnu)
      driver="non lié"

      if [ -L "$p/driver" ]; then
        driver=$(basename "$(readlink -f "$p/driver")")
      fi

      runtime=$(cat "$p/power/runtime_status" 2>/dev/null || echo indisponible)
      control=$(cat "$p/power/control" 2>/dev/null || echo indisponible)
      status=$(cat "$p/power_state" 2>/dev/null || echo indisponible)
      autosuspend=$(cat "$p/power/autosuspend_delay_ms" 2>/dev/null || echo indisponible)

      pci_count=$((pci_count + 1))

      case "$class" in
        (0x03*)
          gpu_count=$((gpu_count + 1))
          echo "#### GPU / contrôleur graphique : $bdf"
          ;;
        (*)
          echo "#### Périphérique PCI : $bdf"
          ;;
      esac

      echo "- Classe PCI : $class"
      echo "- Identifiants vendeur / périphérique : $vendor / $device"
      echo "- Identifiant vendeur du sous-système : $subsystem"
      echo "- Pilote lié : $driver"
      echo "- Runtime PM : $runtime"
      echo "- Contrôle d'énergie : $control"
      echo "- État PCI déclaré : $status"
      echo "- Délai autosuspend (ms) : $autosuspend"

      if command -v lspci >/dev/null 2>&1; then
        echo
        echo '~~~text'
        lspci -Dnnk -s "$bdf" 2>&1 | trunc
        echo '~~~'
      fi

      echo
    done

    echo "**Total :** $pci_count périphérique(s) PCI détecté(s), dont $gpu_count contrôleur(s) graphique(s) selon la classe PCI."
    echo
  } >> "$BODY"
}

# --- Variables du rapport + finalisation (posées TÔT pour que le trap INT couvre toute la collecte) ---
A_HEURE="non précisé"; A_SYMP="non précisé"; A_ACT="non précisé"; A_PWR="non précisé"; A_BOOT="non précisé"
DONE=""
FINAL=""

finalize() {
  [ -n "$DONE" ] && return
  DONE=1
  local base n
  if isnum "$LASTU"; then
    base="$(date -d "@$LASTU" '+%Y_%m_%d_incident_linux_%Hh%M')"
  else
    base="$(date '+%Y_%m_%d')_incident_linux_heure_inconnue_collecte_$(date '+%Hh%M')"
  fi
  FINAL="$OUTDIR/$base.md"; n=2
  while [ -e "$FINAL" ]; do FINAL="$OUTDIR/${base}_$n.md"; n=$((n+1)); done

  {
    if isnum "$LASTU"; then
      echo "# Incident Linux — dernier message journalisé : $(fmt "$LASTU")"
    else
      echo "# Incident Linux — heure inconnue (collecte du $(date '+%F %T'))"
    fi
    echo
    echo "> Généré par \`collecte_incident_linux.sh\` v$VERSION (lecture seule). L'heure du nom de fichier est celle du dernier message journalisé du boot gelé : c'est une **borne basse** de l'heure du gel."
    echo
    echo "> **Confidentialité** : ce rapport peut contenir nom de machine, utilisateurs, adresses IP/MAC, SSID et applications utilisées. Le relire et le caviarder avant tout partage public."
    if [ -n "$JOURNAL_WARN" ]; then
      echo
      echo "> **Attention (droits)** : $JOURNAL_WARN"
    fi
    echo
    echo "## Renseigné à la main (fin de script)"
    echo
    echo "- **Heure à laquelle le gel a été constaté** : $A_HEURE"
    echo "- **Symptômes** (écran interne, HDMI, clavier, Verr. Maj) : $A_SYMP"
    echo "- **Activité en cours** : $A_ACT"
    echo "- **Secteur / batterie au moment du gel** : $A_PWR"
    echo "- **Démarrage précédent** (arrêt complet / redémarrage / depuis Windows, démarrage rapide ?) : $A_BOOT"
    if [ -s "$UNREAD" ]; then
      echo
      echo "**Non lu (droits root requis)** : $(paste -sd ';' "$UNREAD")"
    fi
    echo
    cat "$SUMMARY" "$BODY"
  } >"$FINAL"
  chmod 600 "$FINAL" 2>/dev/null
  [ -n "$RUN_AS" ] && chown "$RUN_AS": "$FINAL" 2>/dev/null
}

on_int() { echo; echo "Interrompu : rapport partiel enregistré."; finalize; echo "Rapport : $FINAL"; exit 130; }

trap on_int INT TERM HUP

# =====================================================================
# 1. Liste des boots et choix du boot gelé
# =====================================================================
mapfile -t IDX < <(journalctl --list-boots --no-pager 2>/dev/null | tail -n $((NB_BOOTS+1)) | awk '{print $1}' | grep -E '^-?[0-9]+$' | sort -rn)

BOOTS_TABLE="$TMP/boots_table.md"
{
  echo "| Indice | Début (heure murale) | Dernier message | Uptime (monotonic) | Fin |"
  echo "|---|---|---|---|---|"
} >"$BOOTS_TABLE"

SEL=""; SEL_MODE=""
for i in "${IDX[@]}"; do
  fu=$(first_unix "$i"); lu=$(last_unix "$i"); lm=$(last_mono "$i")
  unclean=0
  if [ "$i" = "0" ]; then
    end="boot actuel"
  elif clean_shutdown "$i"; then
    end="arrêt propre"
  else
    end="**SANS arrêt propre**"; unclean=1
  fi
  isnum "$lm" || lm=0
  printf '| %s | %s | %s | %s | %s |\n' "$i" "$( [ -n "$fu" ] && fmt "$fu" || echo '?')" \
    "$( [ -n "$lu" ] && fmt "$lu" || echo '?')" "$(dur "$lm")" "$end" >>"$BOOTS_TABLE"
  if [ -z "$SEL" ] && [ "$i" -lt 0 ] && [ "$unclean" = "1" ] && [ "$lm" -ge "$MIN_UPTIME_SEC" ]; then
    SEL="$i"; SEL_MODE="automatique (dernier boot sans arrêt propre, ≥ ${MIN_UPTIME_SEC} s)"
  fi
done

if [ -n "$ARG_BOOT" ]; then
  SEL="$ARG_BOOT"; SEL_MODE="forcé par argument"
elif [ -z "$SEL" ]; then
  SEL="-1"; SEL_MODE="repli sur -1 (aucun boot sans arrêt propre ≥ ${MIN_UPTIME_SEC} s trouvé)"
fi
B="$SEL"

# =====================================================================
# 2. Analyse du boot gelé (tout en monotonic pour les durées)
# =====================================================================
LASTU=$(last_unix "$B")
FIRSTU=$(first_unix "$B")
LASTM=$(last_mono "$B")
FIRSTM=$(first_mono "$B")

{
  echo "## Résumé automatique"
  echo
} >>"$SUMMARY"

ANALYSIS_OK=0
if isnum "$LASTU" && isnum "$FIRSTU" && isnum "$LASTM" && isnum "$FIRSTM"; then
  ANALYSIS_OK=1
  journalctl -b "$B" --no-pager -o short-monotonic >"$TMP/mono.txt" 2>/dev/null

  # Veilles : UN SEUL flux JSON (le mur et le monotonic sont sur la même ligne : pas de désalignement possible).
  # Format de sortie de pm.txt : « entry|exit <mur_µs> <mono_µs> »
  journalctl -b "$B" -k -o json --no-pager 2>/dev/null \
    | grep -E '"MESSAGE" *: *"PM: suspend (entry|exit)' \
    | awk '
        function num(re,   s) {
          if (match($0, re)) { s=substr($0,RSTART,RLENGTH); sub(/^[^:]*: */,"",s); gsub(/[^0-9]/,"",s); return s }
          return ""
        }
        { r=num("\"__REALTIME_TIMESTAMP\" *: *\"[0-9]+\"")
          m=num("\"__MONOTONIC_TIMESTAMP\" *: *\"[0-9]+\"")
          k=($0 ~ /PM: suspend entry/) ? "entry" : "exit"
          if (r!="" && m!="") print k, r, m }' >"$TMP/pm.txt"

  NENTRY=$(grep -c '^entry' "$TMP/pm.txt")
  SLEEP_TOTAL=0; SLEEP_OPEN=""; : >"$TMP/sleeps.txt"
  if [ "$NENTRY" -eq 0 ]; then
    SLEEP_MSG="aucune trace"
  else
    SLEEP_MSG="${NENTRY} entrée(s) en veille"
    LE=$(awk '$1=="exit"{m=$3} END{if (m!="") printf "%d\n", m/1000000}' "$TMP/pm.txt")
    isnum "$LE" && SLEEP_MSG="$SLEEP_MSG ; dernier réveil $(( (LASTM-LE)/60 )) min avant le dernier message"
    # Durée d'une veille = (mur sortie − mur entrée) − (mono sortie − mono entrée)
    awk '$1=="entry" {er=$2; em=$3; open=1; next}
         $1=="exit" && open {printf "%d %d\n", int(er/1000000), (($2-er)-($3-em))/1000000+0.5; open=0}
         END {if (open) print "OPEN", int(er/1000000)}' "$TMP/pm.txt" >"$TMP/sleeps.txt"
    SLEEP_OPEN=$(awk '$1=="OPEN"{print $2}' "$TMP/sleeps.txt")
    SLEEP_TOTAL=$(awk '$1!="OPEN"{t+=$2} END{print t+0}' "$TMP/sleeps.txt")
    SLEEP_MSG="$SLEEP_MSG ; durée cumulée $(dur "$SLEEP_TOTAL")"
    [ -n "$SLEEP_OPEN" ] && SLEEP_MSG="$SLEEP_MSG ; **dernière entrée en veille ($(fmt "$SLEEP_OPEN")) sans réveil journalisé**"
  fi

  # Cohérence de l'horloge : écart brut (mur − mono) puis RÉSIDU après déduction des veilles.
  # Le résidu mesure les sauts d'horloge hors veille (RTC / NTP) ; une veille normale ne déclenche plus d'alerte.
  WALL=$((LASTU-FIRSTU))
  MONO=$((LASTM-FIRSTM))
  DIFF=$((WALL-MONO))
  ADIFF=${DIFF#-}
  RESID=$((DIFF-SLEEP_TOTAL))
  ARESID=${RESID#-}
  RAW="écart brut $(dur "$ADIFF") (mur ${WALL} s, mono ${MONO} s), dont veilles $(dur "$SLEEP_TOTAL")"
  if [ "$ARESID" -le "$CLOCK_TOLERANCE_SEC" ]; then
    CLOCK_MSG="cohérente : ${RAW} ; résidu ${RESID} s (tolérance ±${CLOCK_TOLERANCE_SEC} s)."
  else
    if [ "$RESID" -lt 0 ]; then
      CLOCK_KIND="**HORLOGE MURALE EN ARRIÈRE**"
      CLOCK_DETAIL="Ni une veille ni la dérive ne produisent un recul : un saut en arrière (RTC / NTP) est la cause typique."
    else
      CLOCK_KIND="**AVANCE D'HORLOGE INEXPLIQUÉE**"
      CLOCK_DETAIL="Après déduction des veilles détectées, la durée murale dépasse la durée monotone : saut en avant (RTC / NTP) ou veille non journalisée."
    fi
    CLOCK_HINT=""
    if [ "$ARESID" -ge 1680 ]; then
      rem=$((ARESID%1800))
      if [ "$rem" -le 120 ] || [ "$rem" -ge 1680 ]; then
        CLOCK_HINT=" Le résidu est proche d'un multiple de 30 min : décalage de fuseau de la RTC (Windows en heure locale / Linux en UTC) probable."
      fi
    fi
    CLOCK_MSG="${CLOCK_KIND} : résidu ${RESID} s (≈ $(dur "$ARESID")) après déduction des veilles (${RAW}). ${CLOCK_DETAIL}${CLOCK_HINT} À confirmer avec \`timedatectl\` et les messages « Time has been changed » / « Synchronized to time server ». Limite : un saut survenu pendant une veille est compté dans la durée de cette veille."
  fi
  START_EST=$((LASTU-LASTM-SLEEP_TOTAL))

  # Prochain démarrage
  NEXT_MSG="n/a"
  if [ "$B" -lt 0 ]; then
    NEXTU=$(first_unix $((B+1)))
    if isnum "$NEXTU"; then
      NEXT_MSG="$(fmt "$NEXTU") (écart avec le dernier message : $(( (NEXTU-LASTU)/60 )) min ; heures murales, à relativiser en cas de saut d'horloge)"
    fi
  fi

  # Fenêtre de gel via une tâche périodique (geoclue) : si le passage attendu manque, le gel est antérieur
  WINDOW_MSG="non déterminable (moins de ${HEARTBEAT_MIN_SAMPLES} passages de geoclue)"
  HB=$(grep -E 'geoclue\[[0-9]+\]: Failed to query location' "$TMP/mono.txt" | sed -nE 's/^\[ *([0-9]+)\..*/\1/p' | tail -n $((HEARTBEAT_MIN_SAMPLES>5 ? HEARTBEAT_MIN_SAMPLES : 5)))
  if [ "$(echo "$HB" | grep -c .)" -ge "$HEARTBEAT_MIN_SAMPLES" ]; then
    read -r LASTHB PERIOD < <(echo "$HB" | awk 'NR>1{d+=$1-p; k++} {p=$1} END{if(k>0) printf "%d %d\n", p, d/k}')
    if isnum "$LASTHB" && isnum "$PERIOD" && [ "$PERIOD" -gt 0 ]; then
      NEXTHB=$((LASTHB+PERIOD))
      if [ "$NEXTHB" -gt "$LASTM" ]; then
        WINDOW_MSG="geoclue passe toutes les ~${PERIOD} s ; le passage attendu à t≈${NEXTHB} s (≈ $(fmt $((LASTU+NEXTHB-LASTM)))) manque : gel entre le dernier message et cette heure, si ce message avait pu être écrit sur disque (les ~30 dernières secondes peuvent être perdues)"
      else
        WINDOW_MSG="geoclue (~${PERIOD} s) : aucun passage manquant, la tâche ne borne pas le gel"
      fi
    fi
  fi

  # État actuel de l'alimentation
  PS_MSG=""
  for f in /sys/class/power_supply/*; do
    PS_MSG="$PS_MSG$(basename "$f") (type=$(cat "$f/type" 2>/dev/null) online=$(cat "$f/online" 2>/dev/null) status=$(cat "$f/status" 2>/dev/null) capacity=$(cat "$f/capacity" 2>/dev/null)) ; "
  done

  {
    echo "| Élément | Valeur |"
    echo "|---|---|"
    echo "| Rapport généré le | $(date '+%F %T') |"
    echo "| Boot analysé (journald) | $B — sélection $SEL_MODE |"
    echo "| **Dernier message journalisé** (borne basse du gel) | $(fmt "$LASTU") |"
    echo "| Uptime au dernier message (monotonic) | $(dur "$LASTM") |"
    echo "| Début de boot estimé (dernier message − uptime) | $(fmt "$START_EST") |"
    echo "| Cohérence de l'horloge | $CLOCK_MSG |"
    echo "| Fenêtre du gel (tâche périodique) | $WINDOW_MSG |"
    echo "| Démarrage suivant | $NEXT_MSG |"
    echo "| Veille dans ce boot | $SLEEP_MSG |"
    echo "| Alimentation ACTUELLE (≠ au moment du gel, non journalisée) | $PS_MSG |"
    echo
    echo "### Boots récents"
    echo
    cat "$BOOTS_TABLE"
    echo
    echo "Pour analyser un autre boot : \`bash collecte_incident_linux.sh -2\` (indice de la première colonne). Les durées de la commande \`last\` ne sont pas fiables en cas de saut d'horloge : se fier à ce tableau."
  } >>"$SUMMARY"

  # Activité dans les dernières minutes (ACTIVITY_WINDOW_SEC) AVANT le dernier message (monotonic)
  THR=$((LASTM-ACTIVITY_WINDOW_SEC)); [ "$THR" -lt 0 ] && THR=0
  {
    echo
    echo "### Activité dans les $((ACTIVITY_WINDOW_SEC/60)) dernières minutes avant le dernier message"
    echo
    echo "Sources de messages (nombre de lignes par processus) :"
    echo
    echo '~~~text'
    sed -nE 's/^\[ *([0-9]+)\.[0-9]+\] [^ ]+ ([^: ]+):.*/\1 \2/p' "$TMP/mono.txt" \
      | awk -v t="$THR" '$1>=t {sub(/\[[0-9]+\]$/,"",$2); c[$2]++} END{for(k in c) printf "%d %s\n", c[k], k}' \
      | sort -rn | head -12
    echo '~~~'
    echo
    echo "Applications lancées (unités \`app-*.scope\` démarrées) :"
    echo
    echo '~~~text'
    awk -v t="$THR" '
      match($0,/^\[ *[0-9]+/) {
        s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s)
        if (s+0>=t && $0 ~ /Started app-.*\.scope/ && match($0,/app-[^ ]*\.scope/)) {
          n=substr($0,RSTART,RLENGTH); sub(/-[0-9]+\.scope$/,"",n); c[n]++
        }
      }
      END{for(k in c) printf "%d %s\n", c[k], k}' "$TMP/mono.txt" | sort -rn | head -10
    echo '~~~'
  } >>"$SUMMARY"
else
  {
    echo "**Boot $B introuvable ou journal vide** (journal non persistant ? droits ? indice incorrect ?). Voir « Démarrages journald » plus bas."
    echo
    echo "### Boots récents"
    echo
    cat "$BOOTS_TABLE"
  } >>"$SUMMARY"
fi

# =====================================================================
# 3. Corps technique du rapport
# =====================================================================
h2 "1. Horloge et contexte système actuel"
emit "date '+%F %T %Z (%z)'"
emit "timedatectl"
emit_priv "hwclock --show"
emit "cat /sys/devices/system/clocksource/clocksource0/current_clocksource"
emit "uname -r"
emit "cat /proc/cmdline"
emit "uptime -s"
emit "last -x -F -n 12 | head -20"
emit 'for f in /sys/class/power_supply/*; do echo "$f: $(cat $f/type 2>/dev/null) online=$(cat $f/online 2>/dev/null) $(cat $f/status 2>/dev/null) $(cat $f/capacity 2>/dev/null)%"; done'

h2 "2. Démarrages journald et persistance"
emit "journalctl --list-boots --no-pager | tail -n 10"
emit "ls -ld /var/log/journal 2>&1"
emit "journalctl --disk-usage"
emit "ls -lh /var/log/syslog 2>&1"
emit "df -h / | tail -n 2"

h2 "3. Fin du boot analysé ($B) — 120 dernières lignes"
note "Heures murales (\`short-iso\`) : à relativiser si l'horloge a sauté. Dernier uptime monotonic : ${LASTM:-?} s."
emit "journalctl -b $B -n 120 --no-pager -o short-iso"

h2 "4. Lignes suspectes du boot analysé (matériel, graphique, énergie)"
note "Les lignes Xorg \`(II)\`, \`(==)\`, \`(--)\` et \`Modeline\` sont exclues (bruit) ; \`(EE)\` et \`(WW)\` sont conservées."
PAT='amdgpu|nvidia|NVRM|Xid|\bdrm\b|snd_hda|\baer\b|pcie|PCIe Bus Error|\bmce\b|machine check|hardware error|lockup|watchdog|power state|D3hot|\brcu|hung task|segfault|\boops\b|panic|BUG:|ACPI (BIOS )?Error|thermal|throttl|atkbd|i8042|\(EE\)|\(WW\)'
emit "journalctl -b $B --no-pager -o short-iso | grep -vE '\\((II|==|--)\\)|Modeline' | grep -iE '$PAT' | tail -n 80"
emit "journalctl -k -b $B -p warning --no-pager -o short-iso | tail -n 40"
emit "journalctl -b $B -p err --no-pager -o short-iso | tail -n 60"
note "Messages supprimés par journald (nombre de lignes concernées) :"
emit "journalctl -b $B --no-pager | grep -ciE 'messages suppressed|suppressed [0-9]+ messages'"

h2 "5. Traces de crash persistantes (pstore, rapports)"
emit_priv "ls -la /sys/fs/pstore /var/lib/systemd/pstore"
emit "ls -la /var/crash 2>&1 | tail -n 10"

h2 "6. Inventaire PCI, GPU et états d'énergie (état ACTUEL)"
collect_pci_inventory

h2 "6.1. État des pilotes graphiques"
emit "lsmod | grep -E '^(nvidia|nouveau|amdgpu)' | awk '{print \$1}' | sort -u"

h2 "6.2. Informations NVIDIA (si disponibles)"
emit "if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi --query-gpu=name,uuid,driver_version,pstate,power.draw --format=csv; else echo 'nvidia-smi indisponible'; fi"

h2 "6.3. Paramètres du pilote NVIDIA"
emit "grep -rH -iE 'DynamicPowerManagement|NVreg' /etc/modprobe.d /proc/driver/nvidia/params 2>/dev/null || true"

h2 "6.4. Sélection graphique PRIME (si disponible)"
emit "if command -v prime-select >/dev/null 2>&1; then prime-select query; else echo 'prime-select indisponible'; fi"

h2 "7. C-states et paramètres amdgpu actifs"
emit 'for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do echo "$(basename $s): $(cat $s/name) lat=$(cat $s/latency)us"; done'
emit 'for p in runpm dcdebugmask ppfeaturemask sg_display; do echo "amdgpu.$p = $(cat /sys/module/amdgpu/parameters/$p 2>/dev/null)"; done'
emit "grep -iE 'processor.max_cstate|amdgpu|nvidia|tsc' /etc/default/grub"

h2 "8. Firmware et microcode"
emit "echo \"BIOS : \$(cat /sys/class/dmi/id/bios_version) (\$(cat /sys/class/dmi/id/bios_date))\""
emit "grep -m1 microcode /proc/cpuinfo"
emit "dpkg -l amd64-microcode 2>&1 | tail -n 2"
emit "journalctl -k -b 0 --no-pager | grep -iE 'microcode:' | head -n 5"
emit "journalctl -k -b 0 --no-pager | grep -iE 'Speculative Return Stack|Transient Scheduler' | head -n 5"

# =====================================================================
# 4. Questions, nom de fichier et assemblage
# =====================================================================

# Résumé console
echo
if [ "$ANALYSIS_OK" = "1" ]; then
  echo "Boot analysé        : $B ($SEL_MODE)"
  echo "Dernier message     : $(fmt "$LASTU")"
  echo "Uptime (monotonic)  : $(dur "$LASTM")"
  echo "Horloge             : $CLOCK_MSG" | cut -c1-200
else
  echo "Boot $B introuvable ou journal vide : rapport partiel."
fi
echo

ask() { # $1 = question, $2 = nom de variable
  local v=""
  if [ -t 0 ]; then read -r -e -p "$1 " v; fi
  [ -z "$v" ] && v="non précisé"
  printf -v "$2" '%s' "$v"
}
if [ -t 0 ]; then echo "Quelques questions (Entrée = non précisé) :"; fi
ask "1/5 Heure à laquelle vous avez constaté le gel (HH:MM) :" A_HEURE
ask "2/5 Symptômes (écran interne, HDMI, clavier, Verr. Maj) :" A_SYMP
ask "3/5 Activité en cours au moment du gel :" A_ACT
ask "4/5 Secteur ou batterie au moment du gel :" A_PWR
ask "5/5 Démarrage précédent (arrêt complet / redémarrage / depuis Windows, démarrage rapide ?) :" A_BOOT

finalize
echo
echo "Terminé. Rapport : $FINAL"
echo "Pour consulter : less \"$FINAL\""
echo "Fichier en lecture réservée (600). Il peut contenir des données personnelles : le relire avant tout partage."
