#!/usr/bin/env bash
# Génère un relevé matériel au format Markdown.

# -u : variable non définie = erreur
# -o pipefail : un pipe renvoie le code de la 1re commande en échec
# pas de -e : le script continue si une collecte échoue
set -uo pipefail

# locale C.UTF-8 : sorties non traduites et déterministes, mais UTF-8 conservé (accents corrects)
export LC_ALL=C.UTF-8

OUTPUT_FILE="caracteristiques_materiel_$(date +%Y-%m-%d).md"
DATE_CREATION=$(date "+%d/%m/%Y à %H:%M:%S")

ROWS=$(mktemp) || { echo "❌ Impossible de créer un fichier temporaire (mktemp)." >&2; exit 1; }
trap 'rm -f "$ROWS"' EXIT

# --- utilitaires ---

# séparateur non blanc : préserve les champs vides
SEP=$'\x1f'

# échappe une valeur pour une cellule de tableau Markdown
esc() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//|/\\|}
    s=${s//\`/\\\`}
    s=${s//\*/\\*}
    s=${s//&/"&amp;"}
    s=${s//</"&lt;"}
    s=${s//>/"&gt;"}
    s=${s//$'\n'/ }
    printf '%s' "$s"
}
have() { command -v "$1" >/dev/null 2>&1; }
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
code() {
    local s=${1:-}
    if [ -n "$s" ] && [ "$s" != "—" ]; then
        s=${s//|/\\|}
        s=${s//\`/\'}
        s=${s//$'\n'/ }
        printf '`%s`' "$s"
    else
        printf '—'
    fi
}
add_row() { # composant | modèle | id | pilote
    printf '| %s | %s | %s | %s |\n' "$1" "$2" "${3:-—}" "${4:-—}" >> "$ROWS"
}

# --- check sudo et commandes ---
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Lancez avec sudo pour obtenir le détail des barrettes RAM (le reste fonctionne sans root)." >&2
fi
for cmd in lspci lsusb lsblk dmidecode; do
    have "$cmd" || echo "⚠️  Commande absente : $cmd (sections correspondantes incomplètes)" >&2
done

# --- Système / firmware (sysfs, lisible sans root) ---
dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null | trim; }
MARQUE=$(dmi sys_vendor)
MARQUE=${MARQUE:-Inconnue}
MARQUE=$(esc "$MARQUE")
MODELE=$(dmi product_name)
MODELE=${MODELE:-Inconnu}
MODELE=$(esc "$MODELE")

OS_NAME=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")
OS_NAME=${OS_NAME:-$(uname -o)}
OS_NAME=$(esc "$OS_NAME")
KERNEL=$(uname -r)
KERNEL=$(code "$KERNEL")

BIOS_VER=$(dmi bios_version)
BIOS_VER=${BIOS_VER:-N/A}
BIOS_VER=$(code "$BIOS_VER")

BIOS_DATE=$(dmi bios_date)
BIOS_DATE=${BIOS_DATE:-N/A}
BIOS_DATE=$(esc "$BIOS_DATE")

# --- Aide PCI : une ligne TSV par périphérique correspondant ---
# sortie : slot \t nom \t id \t pilote \t modules
pci_each() {
    have lspci || return 0
    lspci -nn | grep -E "$1" | while IFS= read -r line; do
        slot=${line%% *}
        name=$(sed -E 's/^[^ ]+ [^:]+: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*$//' <<<"$line")
        id=$(grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' <<<"$line" | tail -n 1 | tr -d '[]')
        detail=$(lspci -k -s "$slot" 2>/dev/null)
        drv=$(sed -n 's/^[[:space:]]*Kernel driver in use: //p' <<<"$detail" | head -n 1)
        mods=$(sed -n 's/^[[:space:]]*Kernel modules: //p' <<<"$detail" | head -n 1)
        printf '%s%s%s%s%s%s%s%s%s\n' "$slot" "$SEP" "$name" "$SEP" "$id" "$SEP" "$drv" "$SEP" "$mods"
    done
}

# 1. CPU
CPU_MODEL=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)
CPU_MODEL=$(esc "${CPU_MODEL:-Inconnu}")
add_row "**CPU**" "$CPU_MODEL ($(nproc --all) threads)" "—" "—"

# 2. GPU : détection par code de classe PCI (03xx), classement iGPU/dGPU par vendeur + bus
gpu_kind() { # $1 = slot, $2 = id vendor:device
    local bus=${1%:*}; bus=${bus##*:}
    case ${2%%:*} in
        10de) echo dgpu ;;                                   # NVIDIA
        8086) [ "$bus" = 00 ] && echo igpu || echo dgpu ;;   # Intel : bus 00 = intégré, sinon Arc
        *)    echo unknown ;;                                # AMD & autres : indécidable par vendeur
    esac
}
GPU_FOUND=0
while IFS=$SEP read -r slot name id drv mods; do
    [ -z "$slot" ] && continue
    GPU_FOUND=1
    case $(gpu_kind "$slot" "$id") in
        dgpu) label="**GPU dédié (dGPU)** \`$slot\`" ;;
        igpu) label="**GPU intégré (iGPU)** \`$slot\`" ;;
        *)    label="**GPU (type indéterminé)** \`$slot\`" ;;
    esac
    if [ -z "$drv" ]; then
        d="*Aucun chargé lors du relevé*${mods:+ (modules : \`$mods\`)}"
    else d=$(code "$drv"); fi
    add_row "$label" "$(esc "$name")" "$(code "$id")" "$d"
done < <(pci_each '\[03[0-9a-f]{2}\]:')
[ "$GPU_FOUND" -eq 0 ] && add_row "**GPU**" "Non détecté" "—" "—"

# 3. Réseau
for spec in "Wi-Fi|Network controller" "Ethernet|Ethernet controller"; do
    label=${spec%%|*}; pat=${spec#*|}; found=0
    while IFS=$SEP read -r slot name id drv mods; do
        [ -z "$slot" ] && continue; found=1
        add_row "**$label**" "$(esc "$name")" "$(code "$id")" "$(code "$drv")"
    done < <(pci_each "$pat")
    [ "$found" -eq 0 ] && add_row "**$label**" "Non détecté" "—" "—"
done

# 4. Bluetooth : détecté par classe USB e0 (Wireless Controller), pas par nom de vendeur
BT_FOUND=0
BT_DRV=$(lsmod 2>/dev/null | awk '$1 ~ /^(btusb|btmtk|btintel|btrtl|btbcm)$/ {print $1}' | paste -sd/ -)
declare -A BT_DEVS=()
for d in /sys/bus/usb/devices/*; do
    [[ $d == *:* ]] && continue
    [ -f "$d/idVendor" ] || continue
    if grep -qsx e0 "$d/bDeviceClass" "$d"/*:*/bInterfaceClass; then
        BT_DEVS[$d]=1
        BT_FOUND=1
        id="$(<"$d/idVendor"):$(<"$d/idProduct")"
        name="$(cat "$d/manufacturer" 2>/dev/null | trim) $(cat "$d/product" 2>/dev/null | trim)"
        add_row "**Bluetooth**" "$(esc "$name")" "$(code "$id")" "$(code "${BT_DRV:-—}")"
    fi
done
[ "$BT_FOUND" -eq 0 ] && add_row "**Bluetooth**" "Non détecté" "—" "—"

# 5. Audio (tous les contrôleurs : HDMI du dGPU + codec interne)
AUDIO_FOUND=0
while IFS=$SEP read -r slot name id drv mods; do
    [ -z "$slot" ] && continue; AUDIO_FOUND=1
    add_row "**Audio** \`$slot\`" "$(esc "$name")" "$(code "$id")" "$(code "$drv")"
done < <(pci_each 'Audio device|Multimedia audio controller')
[ "$AUDIO_FOUND" -eq 0 ] && add_row "**Audio**" "Non détecté" "—" "—"
CODEC=$(grep -hi "^Codec:" /proc/asound/card*/codec* 2>/dev/null | sed 's/^Codec:[[:space:]]*//' | sort -u | paste -sd, -)
[ -n "$CODEC" ] && add_row "**Codec audio**" "$(esc "$CODEC")" "—" "—"

# 6. Clavier ASUS / WMI
if have lsusb; then
    KBD_LINE=$(lsusb | grep -iE "ID 0b05:(1866|19b6|1854)" | head -n 1)
    if [ -n "$KBD_LINE" ]; then
        KBD_ID=$(awk '{print $6}' <<<"$KBD_LINE")
        KBD_NAME=$(cut -d' ' -f7- <<<"$KBD_LINE")
        if grep -q '^hid_asus' <<<"$(lsmod)"; then KBD_DRV="hid-asus"; else KBD_DRV="—"; fi
        add_row "**Clavier / RGB ASUS**" "$(esc "$KBD_NAME")" "$(code "$KBD_ID")" "$(code "$KBD_DRV")"
    fi
fi
grep -q '^asus_nb_wmi' <<< "$(lsmod 2>/dev/null)" && add_row "**Plateforme ASUS (WMI)**" "Interface ACPI/WMI" "—" '`asus-nb-wmi`'

# 7. Écran : résolution + pilote lus depuis le connecteur eDP, rien en dur
SCREEN_RES=$(xrandr 2>/dev/null | awk '/ connected/ {c=1; next} c && /\*/ {print $1 " @ " $2; exit}' | tr -d '*+')
[ -z "$SCREEN_RES" ] && SCREEN_RES=$(cat /sys/class/drm/card*-eDP-*/modes 2>/dev/null | head -n 1)
[ -z "$SCREEN_RES" ] && SCREEN_RES="résolution non détectée (Wayland sans XWayland ?)"
SCREEN_DRV="—"
for c in /sys/class/drm/card*-eDP-*; do
    [ -e "$c/device/driver" ] && SCREEN_DRV=$(basename "$(readlink -f "$c/device/driver")") && break
done
add_row "**Écran**" "Dalle intégrée ($SCREEN_RES)" "—" "$(code "$SCREEN_DRV")"

# 8. Batterie : sysfs + calcul de santé (sans dépendance à upower)
BAT_FOUND=0
for b in /sys/class/power_supply/BAT*; do
    [ -d "$b" ] || continue; BAT_FOUND=1
    unit=Wh; full=; design=
    if [ -r "$b/energy_full" ]; then full=$(<"$b/energy_full"); design=$(<"$b/energy_full_design")
    elif [ -r "$b/charge_full" ]; then full=$(<"$b/charge_full"); design=$(<"$b/charge_full_design"); unit=Ah
    fi
    if [ -n "$full" ] && [ -n "$design" ] && [ "$design" -gt 0 ] 2>/dev/null; then
        info=$(awk -v f="$full" -v d="$design" -v u="$unit" 'BEGIN{printf "Capacité : %.1f / %.1f %s (santé : %.0f %%)", f/1e6, d/1e6, u, 100*f/d}')
    else info="Capacité non lisible"; fi
    bdrv=$(basename "$(readlink -f "$b/device/driver" 2>/dev/null)" 2>/dev/null)
    add_row "**Batterie ($(basename "$b"))**" "$(esc "$info")" "—" "$(code "${bdrv:-—}")"
done
[ "$BAT_FOUND" -eq 0 ] && add_row "**Batterie**" "Non détectée" "—" "—"

# 9. RAM (dmidecode, root requis)
if have dmidecode && [ "$EUID" -eq 0 ]; then
    dmidecode -t memory 2>/dev/null | awk '
    BEGIN { RS=""; FS="\n" }
    $2 == "Memory Device" {
        split("", v)
        for (i = 3; i <= NF; i++) {
            line = $i; sub(/^[ \t]+/, "", line)
            k = index(line, ": ")
            if (k == 0) continue
            v[substr(line, 1, k - 1)] = substr(line, k + 2)
        }
        if (v["Size"] == "" || v["Size"] ~ /No Module|Not Installed/) next
        speed = v["Configured Memory Speed"]
        if (speed == "") speed = v["Configured Clock Speed"]
        if (speed == "") speed = v["Speed"]
        gsub(/[ \t]+$/, "", v["Part Number"]); gsub(/[ \t]+$/, "", v["Manufacturer"])
        printf "| **RAM (%s)** | %s %s @ %s — %s `%s` | — | — |\n", v["Locator"], v["Size"], v["Type"], speed, v["Manufacturer"], v["Part Number"]
    }' >> "$ROWS"
else
    add_row "**RAM**" "*Relancer avec \`sudo\` pour les détails des barrettes*" "—" "—"
fi

# 10. Stockage (NVMe, SATA, USB… tous les disques)
if have lsblk; then
    while read -r name type; do
        [ "$type" = disk ] || continue
        case $name in zram*) continue ;; esac
        dev="/dev/$name"
        model=$(lsblk -dn -o MODEL "$dev" 2>/dev/null | trim)
        size=$(lsblk -dn -o SIZE "$dev" 2>/dev/null | trim)
        tran=$(lsblk -dn -o TRAN "$dev" 2>/dev/null | trim)
        mounts=$(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' | paste -sd+ -)
        mt=${mounts:+ ($mounts)}
        pciid="—"; fw=""; drv="—"
        if [[ $name == nvme* ]]; then
            ctrl=${name%%n[0-9]*}
            fw=$(cat "/sys/class/nvme/$ctrl/firmware_rev" 2>/dev/null | trim)
            addr=$(basename "$(readlink -f "/sys/class/nvme/$ctrl/device" 2>/dev/null)")
            pciid=$(lspci -n -s "$addr" 2>/dev/null | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}' | tail -n 1)
            drv=nvme
        else
            drv=$(basename "$(readlink -f "/sys/block/$name/device/driver" 2>/dev/null)" 2>/dev/null)
        fi
        model="$(esc "$model")"
        fw="$(esc "$fw")"
        add_row "**Disque ($name${tran:+, $tran}$mt)**" "${model:-Modèle inconnu} $size${fw:+ (FW \`$fw\`)}" "$(code "${pciid:-—}")" "$(code "${drv:-—}")"
    done < <(lsblk -dn -o NAME,TYPE 2>/dev/null)
fi

# 11. USB externes : attribut sysfs "removable", hubs (classe 09) et Bluetooth exclus
USB_LIST=""
for d in /sys/bus/usb/devices/*; do
    [[ $d == *:* ]] && continue
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/removable" 2>/dev/null)" = removable ] || continue
    [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue
    [ -n "${BT_DEVS[$d]:-}" ] && continue
    id="$(<"$d/idVendor"):$(<"$d/idProduct")"
    id="$(esc "$id")"
    name="$(cat "$d/manufacturer" 2>/dev/null | trim) $(cat "$d/product" 2>/dev/null | trim)"
    name="$(trim <<< "$name")"
    USB_LIST+="$(esc "$name") (\`$id\`), "
done
USB_LIST=${USB_LIST%, }
add_row "**Périphériques USB**" "${USB_LIST:-Aucun périphérique externe détecté}" "—" "—"

# --- Écriture du fichier ---
if ! {
cat <<EOF
# Caractéristiques du matériel

**Données récupérées le** $DATE_CREATION<br>
**Marque :** $MARQUE<br>
**Modèle :** $MODELE<br>

| Composant | Modèle exact | ID matériel | Pilote noyau |
| :--- | :--- | :--- | :--- |
EOF
cat "$ROWS"
SGFX="Non installé / N/A"
have supergfxctl && SGFX=$(supergfxctl -g 2>/dev/null || echo "N/A")
cat <<EOF

## Informations Système & Firmware

* **Système d'exploitation :** $OS_NAME
* **Noyau Linux :** $KERNEL
* **Version du BIOS :** $BIOS_VER (Date : $BIOS_DATE)
* **Mode graphique (supergfxctl) :** $SGFX
EOF
} > "$OUTPUT_FILE"; then
    echo "❌ Échec d'écriture de $OUTPUT_FILE (droits, disque plein ?)." >&2
    exit 1
fi

# rend le fichier à l'utilisateur d'origine si lancé via sudo
if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$OUTPUT_FILE" || echo "⚠️ chown échoué" >&2
fi

echo "✅ Fichier généré avec succès : $OUTPUT_FILE"
