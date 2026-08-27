

#!/usr/bin/env bash
#
# lexmar_copilot.sh — Detecta y muestra el nivel de todos los consumibles
# de impresoras Lexmark: tóner (K/C/M/Y), waste toner, tambor (OPC/photoconductor),
# fusor, unidad de transferencia, desarrollador y más.
#
# Uso: ./lexmar_copilot.sh -H <IP> [-C comunidad] [-v versión] [--json] [--oids] [--timeout segundos] [--debug]
#
# Notas de la mejora:
# - Parsing SNMP más robusto (extrae OIDs numéricos con regex tolerante)
# - Evita hacer muchos snmpget en el bucle: hace snmpwalk por columnas y mapea resultados
# - get_int/get_string tolerantes a varios formatos (INTEGER, Counter32, OCTET STRING, etc.)
# - Soporta --timeout y --debug
#
set -euo pipefail

# Colores
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
MAGENTA=$'\033[1;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Defaults
COMMUNITY="public"
SNMP_VERSION="2c"
HOST=""
OUTPUT_MODE="human"   # human | json | oids
SNMP_TIMEOUT=2
DEBUG=0

# OIDs Printer-MIB
OID_DESC="1.3.6.1.2.1.43.11.1.1.6"
OID_TYPE="1.3.6.1.2.1.43.11.1.1.5"
OID_CLASS="1.3.6.1.2.1.43.11.1.1.4"
OID_UNIT="1.3.6.1.2.1.43.11.1.1.7"
OID_MAX="1.3.6.1.2.1.43.11.1.1.8"
OID_LEVEL="1.3.6.1.2.1.43.11.1.1.9"

# LEXMARK-MPS-MIB
MPS_BASE="1.3.6.1.4.1.641.4.4"
MPS_CURR_SUPPLY_TYPE="${MPS_BASE}.5.4.7.1.3"
MPS_CURR_SUPPLY_DESC="${MPS_BASE}.5.4.7.1.5"
MPS_CURR_SUPPLY_COLOR="${MPS_BASE}.5.4.7.1.4"
MPS_CURR_SUPPLY_STATUS="${MPS_BASE}.5.4.7.1.11"
MPS_CURR_SUPPLY_CAP_UNIT="${MPS_BASE}.5.4.7.1.13"
MPS_CURR_SUPPLY_CAP="${MPS_BASE}.5.4.7.1.14"
MPS_CURR_SUPPLY_LEVEL="${MPS_BASE}.5.4.7.1.16"
MPS_CURR_SUPPLY_DAYS="${MPS_BASE}.5.4.7.1.20"
MPS_INVENTORY_TYPE="${MPS_BASE}.3.2.1.2"

# Mapas de tipos
declare -A PMIB_TYPE_NAMES=(
    [1]="other"  [2]="unknown"  [3]="toner"  [4]="wasteToner"
    [5]="ink"  [6]="inkCartridge"  [7]="inkRibbon"  [8]="wasteInk"
    [9]="photoconductor"  [10]="developer"
    [11]="fuserOil"  [12]="solidWax"  [13]="ribbonWax"  [14]="wasteWax"
    [15]="fuser"  [16]="coronaWire"  [17]="fuserOilWick"  [18]="cleanerUnit"
    [19]="fuserCleaningPad"  [20]="transferUnit"  [21]="tonerCartridge"
    [22]="fuserOiler"
)

declare -A MPS_TYPE_NAMES=(
    [1]="unknown"  [2]="other"  [3]="inkCartridge"  [4]="inkBottle"
    [5]="inkPrinthead"  [6]="toner"  [7]="photoconductor"
    [8]="transferModule"  [9]="fuser"  [10]="wastetonerBox"
    [11]="staples"  [12]="holepunchBox"  [13]="tonerMicr"
    [14]="photoconductorMicr"
)

declare -A SUPPLY_ANSI_DEFAULT=(
    ["toner"]="$BOLD"
    ["tonerCartridge"]="$BOLD"
    ["wasteToner"]="$RED"
    ["wastetonerBox"]="$RED"
    ["photoconductor"]="$BLUE"
    ["photoconductorMicr"]="$BLUE"
    ["fuser"]="$MAGENTA"
    ["developer"]="$CYAN"
    ["transferUnit"]="$GREEN"
    ["transferModule"]="$GREEN"
    ["fuserOil"]="$YELLOW"
    ["fuserOilWick"]="$YELLOW"
    ["fuserCleaningPad"]="$YELLOW"
    ["fuserOiler"]="$YELLOW"
    ["coronaWire"]="$YELLOW"
    ["cleanerUnit"]="$DIM"
    ["other"]="$DIM"
    ["unknown"]="$DIM"
)

declare -A SUPPLY_LABEL_ES=(
    ["toner"]="Tóner"
    ["tonerCartridge"]="Cartucho de Tóner"
    ["wasteToner"]="Waste Toner"
    ["wastetonerBox"]="Waste Toner Bottle"
    ["photoconductor"]="Tambor (OPC)"
    ["photoconductorMicr"]="Tambor MICR (OPC)"
    ["fuser"]="Fusor"
    ["developer"]="Desarrollador"
    ["transferUnit"]="Unidad de Transferencia"
    ["transferModule"]="Módulo de Transferencia"
    ["fuserOil"]="Aceite de Fusor"
    ["fuserOilWick"]="Mecha de Aceite"
    ["fuserCleaningPad"]="Almohadilla Limpieza Fusor"
    ["fuserOiler"]="Lubricador de Fusor"
    ["coronaWire"]="Cable Corona"
    ["cleanerUnit"]="Unidad Limpieza"
    ["other"]="Otro"
    ["unknown"]="Desconocido"
    ["ink"]="Tinta"
    ["inkCartridge"]="Cartucho de Tinta"
    ["inkRibbon"]="Cinta de Tinta"
    ["wasteInk"]="Waste Ink"
    ["solidWax"]="Cera Sólida"
    ["ribbonWax"]="Cinta de Cera"
    ["wasteWax"]="Waste Wax"
    ["staples"]="Grapas"
    ["holepunchBox"]="Perforadora"
)

declare -A COLOR_PATTERNS=(
    ["black"]="black|negro"
    ["cyan"]="cyan|cian"
    ["magenta"]="magenta"
    ["yellow"]="yellow|amarillo"
)

usage() {
    echo "Uso: $0 -H <IP> [-C comunidad] [-v versión] [--json] [--oids] [--timeout segundos] [--debug]"
    exit 1
}

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H) HOST="$2"; shift 2 ;;
        -C) COMMUNITY="$2"; shift 2 ;;
        -v) SNMP_VERSION="$2"; shift 2 ;;
        --json) OUTPUT_MODE="json"; shift ;;
        --oids) OUTPUT_MODE="oids"; shift ;;
        --timeout) SNMP_TIMEOUT="$2"; shift 2 ;;
        --debug) DEBUG=1; shift ;;
        -h|--help) usage ;;
        *) args+=("$1"); shift ;;
    esac
done
[[ ${#args[@]} -gt 0 ]] && { echo "${RED}Argumentos no reconocidos: ${args[*]}${RESET}"; usage; }
[[ -z "$HOST" ]] && { echo "${RED}Error: falta la IP/host (-H)${RESET}"; usage; }

for cmd in snmpwalk snmpget; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "${RED}Error: no se encontró '$cmd'. Instala net-snmp.${RESET}"
        exit 1
    }
done

SNMP_FLAGS=( -v "$SNMP_VERSION" -c "$COMMUNITY" -t "$SNMP_TIMEOUT" )
# Add -On so we get numeric OIDs; keep default output formatting (we parse tolerant)
SNMP_OPTS=( -On )

debug() { [[ "$DEBUG" -eq 1 ]] && echo "${DIM}[DEBUG]${RESET}" "$*" >&2; }

# Extrae primer OID numérico encontrado en la línea
get_oid() {
    echo "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true
}

# Suffix para Printer-MIB: eliminar el prefijo hasta prtMarkerSuppliesEntry y el primer campo (atributo)
get_suffix_pmib() {
    oid=$(get_oid "$1")
    [[ -z "$oid" ]] && echo "" && return
    suffix=${oid#1.3.6.1.2.1.43.11.1.1.}
    # quitar el número de atributo seguido de dot
    suffix=${suffix#*.}
    echo "$suffix"
}

# Suffix para MPS-MIB: similar al anterior
get_suffix_mps() {
    oid=$(get_oid "$1")
    [[ -z "$oid" ]] && echo "" && return
    suffix=${oid#1.3.6.1.4.1.641.4.4.5.4.7.1.}
    suffix=${suffix#*.}
    echo "$suffix"
}

# Int value: toma el primer número entero que aparezca
get_int_value() {
    echo "$1" | grep -oE '-?[0-9]+' | head -n1 || true
}

# String value: intenta extraer entre comillas o todo lo que venga después de ': '
get_string_value() {
    # Si hay "..." preferimos el contenido entre comillas
    if echo "$1" | grep -q '"'; then
        echo "$1" | sed -n 's/.*"\(.*\)".*/\1/p' || true
    else
        # quitar prefijo hasta ': '
        echo "$1" | sed -n 's/^[^:]*:[[:space:]]*//p' || true
    fi
}

to_int() { echo "$1" | sed 's/\..*//'; }
lowercase() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

progress_bar() {
    local pct="$1" color="$2" width=30
    local filled=$(( (pct * width) / 100 )) empty=$(( width - filled ))
    printf "%s[" "$color"
    printf "%${filled}s" '' | tr ' ' '█'
    printf "%${empty}s" '' | tr ' ' '░'
    printf "]%s" "$RESET"
}

interpret_special() {
    case "$1" in
        -1) echo "OTRO" ;;
        -2) echo "DESCONOCIDO" ;;
        -3) echo "ACCION_REQUERIDA" ;;
        *)  echo "" ;;
    esac
}

make_key() {
    local type_name="$1" desc_lower="$2"
    if [[ "$type_name" == "toner" ]] || [[ "$type_name" == "tonerCartridge" ]]; then
        for color in black cyan magenta yellow; do
            pattern="${COLOR_PATTERNS[$color]}"
            if echo "$desc_lower" | grep -iqE "$pattern"; then
                echo "${color}"
                return
            fi
        done
        echo "${type_name}_unknown"
        return
    fi
    echo "$type_name"
}

is_receptacle() {
    local type_name="$1" class_val="$2"
    if [[ "$type_name" == "wasteToner" ]] || [[ "$type_name" == "wastetonerBox" ]] || [[ "$type_name" == "wasteInk" ]] || [[ "$type_name" == "wasteWax" ]]; then
        return 0
    fi
    [[ "$class_val" == "4" ]] && return 0
    return 1
}

# --- Step 1: Walk descriptions and types (Printer-MIB)
mapfile -t DESC_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_DESC" 2>&1 || true)
if [[ ${#DESC_LINES[@]} -eq 0 ]]; then
    echo "${RED}Error: no se pudo obtener prtMarkerSuppliesDescription. Verifica SNMP.${RESET}" >&2
    exit 2
fi

mapfile -t TYPE_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_TYPE" 2>/dev/null || true)

declare -A SUFFIX_TYPE
for line in "${TYPE_LINES[@]}"; do
    # extraer suffix y valor
    oid=$(get_oid "$line")
    [[ -z "$oid" ]] && continue
    suffix=${oid#1.3.6.1.2.1.43.11.1.1.}
    suffix=${suffix#*.}
    val=$(get_int_value "$line")
    SUFFIX_TYPE[$suffix]="$val"
done

# Result structures
declare -A R_SUFFIX R_DESC R_TYPE R_TYPE_ID R_CLASS R_LEVEL R_MAX R_PCT R_UNIT R_UNIT_NUM R_SOURCE
declare -a FOUND_KEYS

for line in "${DESC_LINES[@]}"; do
    # saltar líneas sin string
    if ! echo "$line" | grep -qiE 'STRING:|OCTET STRING|"'; then
        continue
    fi
    suffix=$(get_suffix_pmib "$line")
    [[ -z "$suffix" ]] && continue
    desc=$(get_string_value "$line")
    desc_lower=$(lowercase "$desc")
    type_val="${SUFFIX_TYPE[$suffix]:-0}"
    type_name="${PMIB_TYPE_NAMES[$type_val]:-unknown}"
    key=$(make_key "$type_name" "$desc_lower")
    if [[ -n "${R_SUFFIX[$key]:-}" ]]; then
        debug "skipping duplicate key $key"
        continue
    fi
    R_SUFFIX[$key]="$suffix"
    R_DESC[$key]="$desc"
    R_TYPE[$key]="$type_name"
    R_TYPE_ID[$key]="$type_val"
    R_SOURCE[$key]="Printer-MIB"
    FOUND_KEYS+=("$key")
done

# Fallback: si no detectamos por desc, agregar por type
if [[ ${#FOUND_KEYS[@]} -eq 0 ]] && [[ ${#TYPE_LINES[@]} -gt 0 ]]; then
    for line in "${TYPE_LINES[@]}"; do
        oid=$(get_oid "$line") || continue
        suffix=${oid#1.3.6.1.2.1.43.11.1.1.}
        suffix=${suffix#*.}
        type_val=$(get_int_value "$line")
        type_name="${PMIB_TYPE_NAMES[$type_val]:-unknown}"
        key="${type_name}_$(echo "$suffix" | tr '.' '_')"
        if [[ -z "${R_SUFFIX[$key]:-}" ]]; then
            R_SUFFIX[$key]="$suffix"
            R_DESC[$key]="$type_name"
            R_TYPE[$key]="$type_name"
            R_TYPE_ID[$key]="$type_val"
            R_SOURCE[$key]="Printer-MIB"
            FOUND_KEYS+=("$key")
        fi
    done
fi

# Step 2: MPS-MIB
MPS_AVAILABLE=false
mapfile -t MPS_TYPE_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_TYPE" 2>/dev/null || true)
if [[ ${#MPS_TYPE_LINES[@]} -gt 0 ]] && echo "${MPS_TYPE_LINES[0]}" | grep -qiE 'INTEGER:'; then
    MPS_AVAILABLE=true
    mapfile -t MPS_DESC_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_DESC" 2>/dev/null || true)
    mapfile -t MPS_COLOR_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_COLOR" 2>/dev/null || true)

    declare -A MPS_TYPE_MAP MPS_DESC_MAP MPS_COLOR_MAP
    for line in "${MPS_TYPE_LINES[@]}"; do
        oid=$(get_oid "$line") || continue
        suffix=${oid#${MPS_BASE}.5.4.7.1.}
        suffix=${suffix#*.}
        val=$(get_int_value "$line")
        MPS_TYPE_MAP[$suffix]="$val"
    done
    for line in "${MPS_DESC_LINES[@]}"; do
        oid=$(get_oid "$line") || continue
        suffix=${oid#${MPS_BASE}.5.4.7.1.}
        suffix=${suffix#*.}
        val=$(get_string_value "$line")
        MPS_DESC_MAP[$suffix]="$val"
    done
    for line in "${MPS_COLOR_LINES[@]}"; do
        oid=$(get_oid "$line") || continue
        suffix=${oid#${MPS_BASE}.5.4.7.1.}
        suffix=${suffix#*.}
        val=$(get_string_value "$line")
        MPS_COLOR_MAP[$suffix]="$val"
    done

    for mps_suffix in "${!MPS_TYPE_MAP[@]}"; do
        mps_type_val="${MPS_TYPE_MAP[$mps_suffix]}"
        mps_type_name="${MPS_TYPE_NAMES[$mps_type_val]:-unknown}"
        mps_desc="${MPS_DESC_MAP[$mps_suffix]:-$mps_type_name}"
        mps_color="${MPS_COLOR_MAP[$mps_suffix]:-}"
        mps_desc_lower=$(lowercase "$mps_desc $mps_color")
        if [[ "$mps_type_name" == "toner" ]]; then
            key=$(make_key "toner" "$mps_desc_lower")
        elif [[ "$mps_type_name" == "photoconductor" ]]; then
            key=$(make_key "photoconductor" "$mps_desc_lower")
        else
            key="$mps_type_name"
        fi
        if [[ -z "${R_SUFFIX[$key]:-}" ]]; then
            R_SUFFIX[$key]="$mps_suffix"
            R_DESC[$key]="$mps_desc"
            R_TYPE[$key]="$mps_type_name"
            R_TYPE_ID[$key]="$mps_type_val"
            R_SOURCE[$key]="LEXMARK-MPS-MIB"
            FOUND_KEYS+=("$key")
        else
            debug "enriqueciendo existente $key desde MPS"
        fi
    done
fi

if [[ ${#FOUND_KEYS[@]} -eq 0 ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo '{"error":"no_supplies_detected","supplies":[]}'
    else
        echo "${RED}No se detectaron consumibles en la impresora.${RESET}"
    fi
    exit 3
fi

# Step 3: Batch walk de LEVEL, MAX, UNIT, CLASS para Printer-MIB y MPS-MIB
mapfile -t LEVEL_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_LEVEL" 2>/dev/null || true)
mapfile -t MAX_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_MAX" 2>/dev/null || true)
mapfile -t UNIT_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_UNIT" 2>/dev/null || true)
mapfile -t CLASS_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_CLASS" 2>/dev/null || true)

declare -A PMIB_LEVEL_MAP PMIB_MAX_MAP PMIB_UNIT_MAP PMIB_CLASS_MAP
for line in "${LEVEL_LINES[@]}"; do
    oid=$(get_oid "$line") || continue
    suffix=${oid#1.3.6.1.2.1.43.11.1.1.}
    suffix=${suffix#*.}
    val=$(get_int_value "$line")
    PMIB_LEVEL_MAP[$suffix]="$val"
done
for line in "${MAX_LINES[@]}"; do
    oid=$(get_oid "$line") || continue
    suffix=${oid#1.3.6.1.2.1.43.11.1.1.}
    suffix=${suffix#*.}
    val=$(get_int_value "$line")
    PMIB_MAX_MAP[$suffix]="$val"
done
for line in "${UNIT_LINES[@]}"; do
    oid=$(get_oid "$line") || continue
    suffix=${oid#1.3.6.1.2.1.43.11.1.1.}
    suffix=${suffix#*.}
    val=$(get_int_value "$line")
    PMIB_UNIT_MAP[$suffix]="$val"
done
for line in "${CLASS_LINES[@]}"; do
    oid=$(get_oid "$line") || continue
    suffix=${oid#1.3.6.1.2.1.43.11.1.1.}
    suffix=${suffix#*.}
    val=$(get_int_value "$line")
    PMIB_CLASS_MAP[$suffix]="$val"
done

# MPS maps
if [[ "$MPS_AVAILABLE" == true ]]; then
    mapfile -t MPS_LEVEL_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_LEVEL" 2>/dev/null || true)
    mapfile -t MPS_MAX_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_CAP" 2>/dev/null || true)
    mapfile -t MPS_UNIT_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_CAP_UNIT" 2>/dev/null || true)

    declare -A MPS_LEVEL_MAP MPS_MAX_MAP MPS_UNIT_MAP
    for line in "${MPS_LEVEL_LINES[@]}"; do
        oid=$(get_oid "$line") || continue
        suffix=${oid#${MPS_BASE}.5.4.7.1.}
        suffix=${suffix#*.}
        val=$(get_int_value "$line")
        MPS_LEVEL_MAP[$suffix]="$val"
    done
    for line in "${MPS_MAX_LINES[@]}"; do
        oid=$(get_oid "$line") || continue
        suffix=${oid#${MPS_BASE}.5.4.7.1.}
        suffix=${suffix#*.}
        val=$(get_int_value "$line")
        MPS_MAX_MAP[$suffix]="$val"
    done
    for line in "${MPS_UNIT_LINES[@]}"; do
        oid=$(get_oid "$line") || continue
        suffix=${oid#${MPS_BASE}.5.4.7.1.}
        suffix=${suffix#*.}
        val=$(get_int_value "$line")
        MPS_UNIT_MAP[$suffix]="$val"
    done
fi

# Ahora poblar R_LEVEL,R_MAX,R_UNIT_NUM,R_CLASS y calcular pct
for key in "${FOUND_KEYS[@]}"; do
    suffix="${R_SUFFIX[$key]}"
    source="${R_SOURCE[$key]}"
    if [[ "$source" == "Printer-MIB" ]]; then
        R_LEVEL[$key]="${PMIB_LEVEL_MAP[$suffix]:--2}"
        R_MAX[$key]="${PMIB_MAX_MAP[$suffix]:--2}"
        R_UNIT_NUM[$key]="${PMIB_UNIT_MAP[$suffix]:-7}"
        R_CLASS[$key]="${PMIB_CLASS_MAP[$suffix]:-3}"
    else
        R_LEVEL[$key]="${MPS_LEVEL_MAP[$suffix]:--2}"
        R_MAX[$key]="${MPS_MAX_MAP[$suffix]:-2}"
        R_UNIT_NUM[$key]="${MPS_UNIT_MAP[$suffix]:-7}"
        # inferir clase
        type_name="${R_TYPE[$key]}"
        if is_receptacle "$type_name" "0"; then
            R_CLASS[$key]=4
        else
            R_CLASS[$key]=3
        fi
    fi

    # unidad legible
    unit_val="${R_UNIT_NUM[$key]}"
    case "$unit_val" in
        3)  R_UNIT[$key]="diezmilesimas de pulgada" ;;
        4)  R_UNIT[$key]="micrometros" ;;
        5)  R_UNIT[$key]="hojas" ;;
        7)  R_UNIT[$key]="impresiones" ;;
        8)  R_UNIT[$key]="paginas" ;;
        11|13) R_UNIT[$key]="porcentaje" ;;
        16) R_UNIT[$key]="microlitros" ;;
        17) R_UNIT[$key]="centimetros" ;;
        18) R_UNIT[$key]="metros" ;;
        19) R_UNIT[$key]="pulgadas" ;;
        21) R_UNIT[$key]="gramos" ;;
        22) R_UNIT[$key]="onzas" ;;
        34) R_UNIT[$key]="milisegundos" ;;
        35) R_UNIT[$key]="segundos" ;;
        *)  R_UNIT[$key]="unidad $unit_val" ;;
    esac

    level_int="${R_LEVEL[$key]}"
    max_int="${R_MAX[$key]}"
    special=$(interpret_special "$level_int")
    if [[ -n "$special" ]]; then
        R_PCT[$key]="$special"
    elif [[ "$level_int" =~ ^-?[0-9]+$ ]] && [[ "$level_int" -ge 0 ]] && [[ "$max_int" -gt 0 ]]; then
        pct=$(( (level_int * 100) / max_int ))
        R_PCT[$key]="$pct"
    elif [[ "$level_int" =~ ^[0-9]+$ ]] && [[ "$level_int" -le 100 ]]; then
        R_PCT[$key]="$level_int"
    else
        R_PCT[$key]="N/A"
    fi
done

# --- Device serial/model (same logic que antes)
OID_PRINTER_SERIAL="1.3.6.1.2.1.43.5.1.1.17"
OID_MPS_DEVICE_SERIAL="1.3.6.1.4.1.641.4.4.2.1.5"
OID_LEX_SERIAL="1.3.6.1.4.1.641.2.1.2.1.6"
PRINTER_SERIAL=""
PRINTER_MODEL=""
serial_raw=$(snmpget "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_PRINTER_SERIAL" 2>/dev/null || true)
if [[ -n "$serial_raw" ]]; then
    PRINTER_SERIAL=$(get_string_value "$serial_raw")
fi
if [[ -z "$PRINTER_SERIAL" ]] && [[ "$MPS_AVAILABLE" == true ]]; then
    serial_raw=$(snmpget "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_MPS_DEVICE_SERIAL" 2>/dev/null || true)
    PRINTER_SERIAL=$(get_string_value "$serial_raw" || true)
fi
if [[ -z "$PRINTER_SERIAL" ]]; then
    serial_raw=$(snmpget "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_LEX_SERIAL" 2>/dev/null || true)
    PRINTER_SERIAL=$(get_string_value "$serial_raw" || true)
fi
if [[ "$MPS_AVAILABLE" == true ]]; then
    model_raw=$(snmpget "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "1.3.6.1.4.1.641.4.4.2.1.4" 2>/dev/null || true)
    PRINTER_MODEL=$(get_string_value "$model_raw" || true)
fi

# Page counters (mantener lógica previa: lexmark1.mib, MPS, Printer-MIB)
OID_PG_TOTAL="1.3.6.1.4.1.641.2.1.5.1"
OID_PG_MONO="1.3.6.1.4.1.641.2.1.5.2"
OID_PG_COLOR="1.3.6.1.4.1.641.2.1.5.3"
OID_MPS_COUNT_TYPE="1.3.6.1.4.1.641.4.4.5.2.1.1.2"
OID_MPS_COUNT_VAL="1.3.6.1.4.1.641.4.4.5.2.1.1.4"
OID_PMIB_LIFE_COUNT="1.3.6.1.2.1.43.10.2.1.4"
OID_PMIB_POWERON_COUNT="1.3.6.1.2.1.43.10.2.1.5"
PAGE_TOTAL="" PAGE_MONO="" PAGE_COLOR="" PAGE_POWERON="" COUNTER_SOURCE=""

mono_raw=$(snmpget "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_PG_MONO" 2>/dev/null || true)
color_raw=$(snmpget "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_PG_COLOR" 2>/dev/null || true)
total_raw=$(snmpget "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_PG_TOTAL" 2>/dev/null || true)
if [[ -n "$mono_raw" ]] && echo "$mono_raw" | grep -qi 'INTEGER\|Counter32'; then
    PAGE_MONO=$(get_int_value "$mono_raw")
    PAGE_COLOR=$(get_int_value "$color_raw")
    if [[ -n "$total_raw" ]] && echo "$total_raw" | grep -qi 'INTEGER\|Counter32'; then
        PAGE_TOTAL=$(get_int_value "$total_raw")
    else
        PAGE_TOTAL=$(( PAGE_MONO + PAGE_COLOR ))
    fi
    COUNTER_SOURCE="lexmark1.mib (pgcount)"
else
    if [[ "$MPS_AVAILABLE" == true ]]; then
        mapfile -t MPS_COUNT_TYPE_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_MPS_COUNT_TYPE" 2>/dev/null || true)
        mapfile -t MPS_COUNT_VAL_LINES < <(snmpwalk "${SNMP_OPTS[@]}" "${SNMP_FLAGS[@]}" "$HOST" "$OID_MPS_COUNT_VAL" 2>/dev/null || tr