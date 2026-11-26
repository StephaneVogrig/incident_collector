#!/usr/bin/env bash
#
# syscfg.sh : modification et restauration de propriétés système (/sys)
#
#   sudo ./syscfg.sh set      Applique les paramètres de test (après backup automatique)
#   sudo ./syscfg.sh status   Affiche un tableau comparant chaque propriété (Nom, Actuel, Sauvegardé)
#   sudo ./syscfg.sh restore  Restaure les propriétés à leur état d'origine
#

set -euo pipefail

STATE_DIR="/var/lib/syscfg"
BACKUP_FILE="$STATE_DIR/backup.env"

# Format : "NOM_LOGIQUE|/chemin/dans/sys|valeur_test"
TARGETS=(
    "PLATFORM_PROFILE|/sys/firmware/acpi/platform_profile|performance"
)

die() {
    echo "Erreur : $*" >&2
    exit 1
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Lance ce script avec sudo ou en root."
}

# Lit la valeur active d'un fichier sysfs (gère les listes type "[balanced] performance")
read_sysfs_value() {
    # local path="$1"
    # [[ -r "$path" ]] || { echo "<illisible>"; return 0; }

    # local raw
    # raw="$(tr -d '\n' < "$path")"

    # if [[ "$raw" =~ \[([^\]]+)\] ]]; then
    #     printf '%s\n' "${BASH_REMATCH[1]}"
    # else
    #     printf '%s\n' "$raw"
    # fi
}

# Trouve le chemin sysfs associé à un nom logique
get_path_for_name() {
    # local target_name="$1"
    # local entry name path test_val

    # for entry in "${TARGETS[@]}"; do
    #     IFS='|' read -r name path test_val <<< "$entry"
    #     if [[ "$name" == "$target_name" ]]; then
    #         printf '%s\n' "$path"
    #         return 0
    #     fi
    # done
    # return 1
}

save_baseline() {
    require_root
    [[ -f "$BACKUP_FILE" ]] && return 0

    # install -d -m 0700 "$STATE_DIR"

    # local tmp_file
    # tmp_file="$(mktemp "$STATE_DIR/.baseline.XXXXXX")"
    # chmod 0600 "$tmp_file"

    # local entry name path test_val val
    # for entry in "${TARGETS[@]}"; do
    #     IFS='|' read -r name path test_val <<< "$entry"
    #     if [[ -r "$path" ]]; then
    #         val="$(read_sysfs_value "$path")"
    #         printf '%s=%q\n' "$name" "$val" >> "$tmp_file"
    #     else
    #         echo "Avertissement : $name ($path) introuvable ou non lisible, ignoré." >&2
    #     fi
    # done

    # mv -f "$tmp_file" "$BACKUP_FILE"
    # echo "Sauvegarde initiale enregistrée dans $BACKUP_FILE"
}

cmd_set() {
    require_root
    # save_baseline

    # local entry name path test_val
    # for entry in "${TARGETS[@]}"; do
    #     IFS='|' read -r name path test_val <<< "$entry"

    #     if [[ ! -e "$path" ]]; then
    #         echo "Ignoré ($name) : $path inexistant." >&2
    #         continue
    #     fi
    #     if [[ ! -w "$path" ]]; then
    #         echo "Ignoré ($name) : $path non accessible en écriture." >&2
    #         continue
    #     fi

    #     printf '%s\n' "$test_val" > "$path"
    #     echo "Appliqué $name -> $test_val"
    # done
}

cmd_restore() {
    require_root
    [[ -f "$BACKUP_FILE" ]] || die "Aucune sauvegarde trouvée ($BACKUP_FILE)."

    # # Charge les variables sauvegardées (ex: PLATFORM_PROFILE=balanced)
    # # shellcheck disable=SC1090
    # source "$BACKUP_FILE"

    # local entry name path test_val saved_val
    # for entry in "${TARGETS[@]}"; do
    #     IFS='|' read -r name path test_val <<< "$entry"

    #     if [[ -v "$name" ]]; then
    #         saved_val="${!name}"
    #         if [[ -w "$path" ]]; then
    #             printf '%s\n' "$saved_val" > "$path"
    #             echo "Restauré $name <- $saved_val"
    #         else
    #             echo "Ignoré ($name) : $path non accessible en écriture." >&2
    #         fi
    #     fi
    # done
}

cmd_status() {
    # local -A saved=()
    # if [[ -f "$BACKUP_FILE" ]]; then
    #     # shellcheck disable=SC1090
    #     source "$BACKUP_FILE"
    # fi

    # printf "%-20s %-18s %-18s %s\n" "CIBLE" "ACTUEL" "SAUVEGARDÉ" "CHEMIN"
    # printf "%-20s %-18s %-18s %s\n" "-----" "------" "----------" "------"

    # local entry name path test_val current_val saved_val
    # for entry in "${TARGETS[@]}"; do
    #     IFS='|' read -r name path test_val <<< "$entry"
    #     current_val="$(read_sysfs_value "$path")"
    #     saved_val="${!name:-<aucun>}"
    #     printf "%-20s %-18s %-18s %s\n" "$name" "$current_val" "$saved_val" "$path"
    # done
}

usage() {
    local exit_code="${1:-1}"
    # Lit les lignes commençant par '#' après le shebang jusqu'à la première ligne vide,
    # puis retire le '# ' en début de ligne
    awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
    exit "$exit_code"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        status)         cmd_status ;;
        set)            cmd_set ;;
        restore)        cmd_restore ;;
        help|-h|--help) usage 0 ;;
        *)              usage 1 ;;
    esac
}
main "$@"
