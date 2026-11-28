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
    "TEST_MODE    | /tmp/syscfg-sandbox/mode    | manual"
    "TEST_PROFILE | /tmp/syscfg-sandbox/profile | performance"
)

declare -A SAVED=()

load_backup() {
    local key val
    SAVED=()
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        SAVED["$key"]="$val"
    done < "$BACKUP_FILE"
}

die() {
    echo "Erreur : $*" >&2
    exit 1
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Le script doit etre demarre avec sudo ou en root."
}

trim() {
    local s="$1"
    # Supprime les espaces/tabulations en début et en fin
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s\n' "$s"
}

# Lit la valeur active d'un fichier sysfs (gère les listes type "[balanced] performance")
read_sysfs_value() {
    local path="$1"
    [[ -r "$path" ]] || { echo "<illisible>"; return 0; }

    local raw
    raw="$(tr -d '\n' < "$path")"

    if [[ "$raw" =~ \[([^\]]+)\] ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$raw"
    fi
}

# Trouve le chemin sysfs associé à un nom logique
get_path_for_name() {
    local target_name="$1"
    local entry name path test_val

    for entry in "${TARGETS[@]}"; do
        IFS='|' read -r name path test_val <<< "$entry"
        if [[ "$name" == "$target_name" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

save_backup() {
    require_root
    [[ -f "$BACKUP_FILE" ]] && return 0

    install -d -m 0700 "$STATE_DIR"

    local tmp_file
    tmp_file="$(mktemp "$STATE_DIR/.baseline.XXXXXX")"
    chmod 0600 "$tmp_file"

    for_each_target _save_on_target

    mv -f "$tmp_file" "$BACKUP_FILE"
    echo "Sauvegarde initiale enregistrée dans $BACKUP_FILE"
}

# Appelle <callback> <name> <path> <test_val> pour chaque entrée de TARGETS
for_each_target() {
    local callback="$1"
    local entry raw_name raw_path raw_val name path test_val

    for entry in "${TARGETS[@]}"; do
        IFS='|' read -r raw_name raw_path raw_val <<< "$entry"
        name="$(trim "$raw_name")"
        path="$(trim "$raw_path")"
        test_val="$(trim "$raw_val")"

        "$callback" "$name" "$path" "$test_val"
    done
}

# ------------- callback -----------------

_save_one_target() {
    local name="$1" path="$2" _test_val="$3"
    local val

    if [[ -r "$path" ]]; then
        val="$(read_sysfs_value "$path")"
        printf '%s=%s\n' "$name" "$val" >> "$tmp_file"
    else
        echo "Avertissement : $name ($path) introuvable ou non lisible, ignoré." >&2
    fi
}

_set_one_target() {
    local name="$1" path="$2" test_val="$3"

    if [[ ! -e "$path" ]]; then
        echo "Ignoré ($name) : $path inexistant." >&2
        return 0
    fi
    if [[ ! -w "$path" ]]; then
        echo "Ignoré ($name) : $path non accessible en écriture." >&2
        return 0
    fi

    printf '%s\n' "$test_val" > "$path"
    echo "Appliqué $name -> $test_val"
}

_restore_one_target() {
    local name="$1" path="$2" _test_val="$3"
    local saved_val

    if [[ -n "${SAVED[$name]+x}" ]]; then
        saved_val="${SAVED[$name]}"
        if [[ -w "$path" ]]; then
            printf '%s\n' "$saved_val" > "$path"
            echo "Restauré $name <- $saved_val"
        else
            echo "Ignoré ($name) : $path non accessible en écriture." >&2
        fi
    fi
}

_status_one_target() {
    local name="$1" path="$2" _test_val="$3"
    local current_val saved_val

    current_val="$(read_sysfs_value "$path")"
    saved_val="${SAVED[$name]:-<aucun>}"
    printf "%-20s %-18s %-18s %s\n" "$name" "$current_val" "$saved_val" "$path"
}

# ------------- Commandes ----------------

cmd_set() {
    require_root
    save_backup
    for_each_target _set_one_target
}

cmd_restore() {
    require_root
    [[ -f "$BACKUP_FILE" ]] || die "Aucune sauvegarde trouvée ($BACKUP_FILE)."
    # shellcheck disable=SC1090
    source "$BACKUP_FILE"
    for_each_target _restore_one_target
    rm -f "$BACKUP_FILE"
}

cmd_status() {
    if [[ -f "$BACKUP_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$BACKUP_FILE"
    fi

    printf "%-20s %-18s %-18s %s\n" "CIBLE" "ACTUEL" "SAUVEGARDÉ" "CHEMIN"
    printf "%-20s %-18s %-18s %s\n" "-----" "------" "----------" "------"
    for_each_target _status_one_target
}

usage() {
    local exit_code="${1:-1}"
    # Lit les lignes commençant par '#' après le shebang jusqu'à la première ligne vide,
    # puis retire le '# ' en début de ligne
    awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
    exit "$exit_code"
}

# ----------------------------------

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
