#!/usr/bin/env bash
#
# lexmark-toner.sh — Detecta y muestra el nivel de todos los consumibles
# de impresoras Lexmark: tóner (K/C/M/Y), waste toner, tambor (OPC/photoconductor),
# fusor, unidad de transferencia, desarrollador y más.
#
# Usa dos fuentes SNMP:
#   1. Printer-MIB estándar (RFC 1759) — 1.3.6.1.2.1.43.11
#   2. LEXMARK-MPS-MIB privado — 1.3.641.4.4 (currentSuppliesTable)
#
# Uso: ./lexmark-toner.sh -H <IP> [-C comunidad] [-v versión] [--json] [--oids]
#   -H       IP o hostname de la impresora        (obligatorio)
#   -C       Community string SNMP               (por defecto: public)
#   -v       Versión SNMP: 1, 2c o 3             (por defecto: 2c)
#   --json   Salida en JSON para integración
#   --oids   Muestra los OIDs exactos detectados
#
# Ejemplo:
#   ./lexmark-toner.sh -H 192.168.1.50
#   ./lexmark-toner.sh -H 192.168.1.50 --json
#   ./lexmark-toner.sh -H 192.168.1.50 --oids
#
# Requisitos: snmpwalk y snmpget (paquete net-snmp / snmp-utils)
#
set -euo pipefail

# ── Colores ────────────────────────────────────────────────────────────────────
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
MAGENTA=$'\033[1;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# ── Valores por defecto ───────────────────────────────────────────────────────
COMMUNITY="public"
SNMP_VERSION="2c"
HOST=""
OUTPUT_MODE="human"   # human | json | oids

# ── OIDs del Printer-MIB (mib-2.43) ───────────────────────────────────────────
# Tabla: prtMarkerSupplies = 1.3.6.1.2.1.43.11
#   prtMarkerSuppliesEntry = .43.11.1.1
#     .4 = prtMarkerSuppliesClass   (3=consumed, 4=receptacle)
#     .5 = prtMarkerSuppliesType   (ver tabla abajo)
#     .6 = prtMarkerSuppliesDescription
#     .7 = prtMarkerSuppliesSupplyUnit
#     .8 = prtMarkerSuppliesMaxCapacity
#     .9 = prtMarkerSuppliesLevel
#
# Tipos (PrtMarkerSuppliesTypeTC):
#   1=other  2=unknown  3=toner  4=wasteToner  5=ink  6=inkCartridge
#   7=inkRibbon  8=wasteInk  9=opc(photoconductor)  10=developer
#   11=fuserOil  12=solidWax  13=ribbonWax  14=wasteWax
#   15=fuser  16=coronaWire  17=fuserOilWick  18=cleanerUnit
#   19=fuserCleaningPad  20=transferUnit  21=tonerCartridge  22=fuserOiler
#
# Clases (PrtMarkerSuppliesClassTC):
#   3=supplyThatIsConsumed (se gasta: tóner, drum, fusor...)
#   4=receptacleThatIsFilled (se llena: waste toner, waste ink...)
#
OID_DESC="1.3.6.1.2.1.43.11.1.1.6"       # prtMarkerSuppliesDescription
OID_TYPE="1.3.6.1.2.1.43.11.1.1.5"       # prtMarkerSuppliesType
OID_CLASS="1.3.6.1.2.1.43.11.1.1.4"     # prtMarkerSuppliesClass
OID_UNIT="1.3.6.1.2.1.43.11.1.1.7"       # prtMarkerSuppliesSupplyUnit
OID_MAX="1.3.6.1.2.1.43.11.1.1.8"         # prtMarkerSuppliesMaxCapacity
OID_LEVEL="1.3.6.1.2.1.43.11.1.1.9"       # prtMarkerSuppliesLevel

# ── OIDs del LEXMARK-MPS-MIB (enterprise 641) ─────────────────────────────────
# lexmark = 1.3.6.1.4.1.641
# lexmarkModules = .641.4
# mps = .641.4.4  (lexmarkModules.4)
#   mpsMibModule = .641.4.4.1
#   inventory = .641.4.4.3
#     supplyInventoryTable = .641.4.4.3.2
#     hwInventoryTable = .641.4.4.3.4
#   stats = .641.4.4.5
#     supplyStats = .641.4.4.5.4
#       currentSuppliesTable = .641.4.4.5.4.7
#         currentSuppliesEntry = .641.4.4.5.4.7.1
#           .1  = currentSupplyIndex
#           .3  = currentSupplyType         (SupplyTypeTC)
#           .4  = currentSupplyColorantValue
#           .5  = currentSupplyDescription
#           .6  = currentSupplySerialNumber
#           .7  = currentSupplyPartNumber
#           .11 = currentSupplyCurrentStatus
#           .13 = currentSupplyCapacityUnit  (UnitsTC)
#           .14 = currentSupplyCapacity
#           .15 = currentSupplyFirstKnownLevel
#           .16 = currentSupplyCurrentLevel
#           .20 = currentSupplyDaysRemaining
#
# SupplyTypeTC (LEXMARK-MPS-MIB):
#   1=unknown  2=other  3=inkCartridge  4=inkBottle  5=inkPrinthead
#   6=toner  7=photoconductor  8=transferModule  9=fuser
#   10=wastetonerBox  11=staples  12=holepunchBox
#   13=tonerMicr  14=photoconductorMicr
#
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

# ── Mapeo de tipos numéricos a nombres legibles ───────────────────────────────
# Printer-MIB (PrtMarkerSuppliesTypeTC)
declare -A PMIB_TYPE_NAMES=(
    [1]="other"  [2]="unknown"  [3]="toner"  [4]="wasteToner"
    [5]="ink"  [6]="inkCartridge"  [7]="inkRibbon"  [8]="wasteInk"
    [9]="photoconductor"  [10]="developer"
    [11]="fuserOil"  [12]="solidWax"  [13]="ribbonWax"  [14]="wasteWax"
    [15]="fuser"  [16]="coronaWire"  [17]="fuserOilWick"  [18]="cleanerUnit"
    [19]="fuserCleaningPad"  [20]="transferUnit"  [21]="tonerCartridge"
    [22]="fuserOiler"
)

# LEXMARK-MPS-MIB (SupplyTypeTC)
declare -A MPS_TYPE_NAMES=(
    [1]="unknown"  [2]="other"  [3]="inkCartridge"  [4]="inkBottle"
    [5]="inkPrinthead"  [6]="toner"  [7]="photoconductor"
    [8]="transferModule"  [9]="fuser"  [10]="wastetonerBox"
    [11]="staples"  [12]="holepunchBox"  [13]="tonerMicr"
    [14]="photoconductorMicr"
)

# Etiquetas y colores por tipo de consumible
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

# ── Patrones de color para identificar K/C/M/Y ───────────────────────────────
declare -A COLOR_PATTERNS=(
    ["black"]="black|negro"
    ["cyan"]="cyan|cian"
    ["magenta"]="magenta"
    ["yellow"]="yellow|amarillo"
)

# ── Parseo de argumentos ───────────────────────────────────────────────────────
usage() {
    echo "Uso: $0 -H <IP> [-C comunidad] [-v versión] [--json] [--oids]"
    echo "  -H       IP o hostname de la impresora (obligatorio)"
    echo "  -C       Community string (defecto: public)"
    echo "  -v       Versión SNMP: 1, 2c o 3 (defecto: 2c)"
    echo "  --json   Salida en JSON para integración"
    echo "  --oids   Muestra los OIDs exactos detectados"
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
        -h|--help) usage ;;
        *) args+=("$1"); shift ;;
    esac
done
[[ ${#args[@]} -gt 0 ]] && { echo "${RED}Argumentos no reconocidos: ${args[*]}${RESET}"; usage; }
[[ -z "$HOST" ]] && { echo "${RED}Error: falta la IP/host (-H)${RESET}"; usage; }

# ── Verificar dependencias ─────────────────────────────────────────────────────
for cmd in snmpwalk snmpget; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "${RED}Error: no se encontró '$cmd'. Instala net-snmp.${RESET}"
        echo "  Debian/Ubuntu: sudo apt install snmp"
        echo "  RHEL/Fedora:   sudo dnf install net-snmp-utils"
        exit 1
    }
done

SNMP_FLAGS=(-v "$SNMP_VERSION" -c "$COMMUNITY")

# ── Funciones auxiliares ──────────────────────────────────────────────────────

# Extraer sufijo de índice de línea snmpwalk
# Quita el OID base y deja solo <hrDeviceIndex>.<supplyIndex>
get_suffix_pmib() {
    echo "$1" | sed -n 's/^\([0-9.]*\).*/\1/p' | sed 's/^1\.3\.6\.1\.2\.1\.43\.11\.1\.1\.[0-9]\.//'
}

# Extraer sufijo para MPS-MIB (formato: deviceIndex.supplyIndex)
get_suffix_mps() {
    echo "$1" | sed -n 's/^\([0-9.]*\).*/\1/p' | sed 's/^1\.3\.6\.1\.4\.1\.641\.4\.4\.5\.4\.7\.1\.[0-9]*\.//'
}

get_int_value() {
    echo "$1" | sed -n 's/.*INTEGER: *\(-\?[0-9]*\).*/\1/p'
}

get_string_value() {
    echo "$1" | sed -n 's/.*STRING: *"\(.*\)"/\1/p'
}

to_int() { echo "$1" | sed 's/\..*//'; }

lowercase() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

progress_bar() {
    local pct="$1" color="$2" width=30
    local filled=$(( (pct * width) / 100 )) empty=$(( width - filled ))
    printf "${color}["
    printf "%${filled}s" '' | tr ' ' '█'
    printf "%${empty}s" '' | tr ' ' '░'
    printf "]${RESET}"
}

interpret_special() {
    case "$1" in
        -1) echo "OTRO" ;;
        -2) echo "DESCONOCIDO" ;;
        -3) echo "ACCION_REQUERIDA" ;;
        *)  echo "" ;;
    esac
}

# Generar clave única para un consumible
# Combina tipo + color si aplica
make_key() {
    local type_name="$1" desc_lower="$2"
    # Si es tóner o tonerCartridge, intentar identificar color
    if [[ "$type_name" == "toner" ]] || [[ "$type_name" == "tonerCartridge" ]]; then
        for color in black cyan magenta yellow; do
            pattern="${COLOR_PATTERNS[$color]}"
            if echo "$desc_lower" | grep -iqE "$pattern"; then
                echo "${color}"
                return
            fi
        done
        # Si no se identifica color, usar tipo
        echo "${type_name}_unknown"
        return
    fi
    echo "$type_name"
}

# Determinar si un tipo es un receptáculo (se llena)
is_receptacle() {
    local type_name="$1" class_val="$2"
    if [[ "$type_name" == "wasteToner" ]] || [[ "$type_name" == "wastetonerBox" ]] \
       || [[ "$type_name" == "wasteInk" ]] || [[ "$type_name" == "wasteWax" ]]; then
        return 0
    fi
    [[ "$class_val" == "4" ]] && return 0
    return 1
}

# ── Paso 1: Walk de consumibles (Printer-MIB) ────────────────────────────────
# Esta tabla estándar debería estar en todas las impresoras Lexmark

mapfile -t DESC_LINES < <(snmpwalk "${SNMP_FLAGS[@]}" "$HOST" "$OID_DESC" 2>&1) || {
    echo "${RED}Error: no se pudo conectar a la impresora.${RESET}"
    echo "Verifica IP, community y que SNMP esté activado."
    exit 2
}

if [[ "${#DESC_LINES[@]}" -eq 0 ]] || [[ "${DESC_LINES[0]}" == *"Timeout"* ]] || [[ "${DESC_LINES[0]}" == *"No Response"* ]]; then
    echo "${RED}Error: sin respuesta SNMP. Verifica IP y community.${RESET}"
    exit 2
fi

# Obtener tipos y clases
mapfile -t TYPE_LINES < <(snmpwalk "${SNMP_FLAGS[@]}" "$HOST" "$OID_TYPE" 2>/dev/null || true)

# Mapa: suffix -> type_val
declare -A SUFFIX_TYPE
for line in "${TYPE_LINES[@]}"; do
    [[ "$line" != *"INTEGER:"* ]] && continue
    suffix=$(get_suffix_pmib "$line")
    type_val=$(get_int_value "$line")
    SUFFIX_TYPE[$suffix]=$type_val
done

# ── Estructuras de datos para resultados ──────────────────────────────────────
declare -A R_SUFFIX     # key -> suffix
declare -A R_DESC      # key -> descripción
declare -A R_TYPE      # key -> type_name
declare -A R_TYPE_ID   # key -> type_val numérico
declare -A R_CLASS     # key -> class_val
declare -A R_LEVEL     # key -> nivel
declare -A R_MAX       # key -> máximo
declare -A R_PCT       # key -> porcentaje
declare -A R_UNIT      # key -> unidad legible
declare -A R_UNIT_NUM  # key -> unidad numérica
declare -A R_SOURCE    # key -> "Printer-MIB" o "LEXMARK-MPS-MIB"
declare -a FOUND_KEYS  # keys en orden

# ── Procesar cada consumible del Printer-MIB ─────────────────────────────────
for line in "${DESC_LINES[@]}"; do
    [[ "$line" != *"STRING:"* ]] && continue

    suffix=$(get_suffix_pmib "$line")
    desc=$(get_string_value "$line")
    desc_lower=$(lowercase "$desc")
    type_val="${SUFFIX_TYPE[$suffix]:-0}"
    type_name="${PMIB_TYPE_NAMES[$type_val]:-unknown}"

    key=$(make_key "$type_name" "$desc_lower")

    # Evitar duplicados
    if [[ -n "${R_SUFFIX[$key]:-}" ]]; then
        continue
    fi

    R_SUFFIX[$key]="$suffix"
    R_DESC[$key]="$desc"
    R_TYPE[$key]="$type_name"
    R_TYPE_ID[$key]="$type_val"
    R_SOURCE[$key]="Printer-MIB"
    FOUND_KEYS+=("$key")
done

# ── Fallback: si no se encontraron por nombre, asignar por tipo ──────────────
if [[ "${#FOUND_KEYS[@]}" -eq 0 ]] && [[ "${#TYPE_LINES[@]}" -gt 0 ]]; then
    for line in "${TYPE_LINES[@]}"; do
        [[ "$line" != *"INTEGER:"* ]] && continue
        suffix=$(get_suffix_pmib "$line")
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

# ── Paso 2: Intentar LEXMARK-MPS-MIB para datos extra ────────────────────────
# Esta tabla privada puede dar: días restantes, número de serie, parte
# No todas las impresoras la soportan

MPS_AVAILABLE=false
mapfile -t MPS_TYPE_LINES < <(snmpwalk "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_TYPE" 2>/dev/null || true)

if [[ "${#MPS_TYPE_LINES[@]}" -gt 0 ]] && [[ "${MPS_TYPE_LINES[0]}" == *"INTEGER:"* ]]; then
    MPS_AVAILABLE=true

    # Obtener descripciones del MPS-MIB
    mapfile -t MPS_DESC_LINES < <(snmpwalk "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_DESC" 2>/dev/null || true)
    mapfile -t MPS_COLOR_LINES < <(snmpwalk "${SNMP_FLAGS[@]}" "$HOST" "$MPS_CURR_SUPPLY_COLOR" 2>/dev/null || true)

    # Crear mapas MPS: suffix -> valores
    declare -A MPS_TYPE_MAP MPS_DESC_MAP MPS_COLOR_MAP

    for line in "${MPS_TYPE_LINES[@]}"; do
        [[ "$line" != *"INTEGER:"* ]] && continue
        mps_suffix=$(get_suffix_mps "$line")
        mps_type_val=$(get_int_value "$line")
        MPS_TYPE_MAP[$mps_suffix]=$mps_type_val
    done

    for line in "${MPS_DESC_LINES[@]}"; do
        [[ "$line" != *"STRING:"* ]] && continue
        mps_suffix=$(get_suffix_mps "$line")
        mps_desc=$(get_string_value "$line")
        MPS_DESC_MAP[$mps_suffix]="$mps_desc"
    done

    for line in "${MPS_COLOR_LINES[@]}"; do
        [[ "$line" != *"STRING:"* ]] && continue
        mps_suffix=$(get_suffix_mps "$line")
        mps_color=$(get_string_value "$line")
        MPS_COLOR_MAP[$mps_suffix]="$mps_color"
    done

    # Para cada entrada MPS, intentar enriquecer o añadir
    for mps_suffix in "${!MPS_TYPE_MAP[@]}"; do
        mps_type_val="${MPS_TYPE_MAP[$mps_suffix]}"
        mps_type_name="${MPS_TYPE_NAMES[$mps_type_val]:-unknown}"
        mps_desc="${MPS_DESC_MAP[$mps_suffix]:-$mps_type_name}"
        mps_color="${MPS_COLOR_MAP[$mps_suffix]:-}"
        mps_desc_lower=$(lowercase "$mps_desc ${mps_color}")

        # Construir key
        if [[ "$mps_type_name" == "toner" ]]; then
            key=$(make_key "toner" "$mps_desc_lower")
        elif [[ "$mps_type_name" == "photoconductor" ]]; then
            key=$(make_key "photoconductor" "$mps_desc_lower")
        else
            key="$mps_type_name"
        fi

        # Si ya existe en Printer-MIB, enriquecer con días restantes después
        # Si no existe, añadir desde MPS
        if [[ -z "${R_SUFFIX[$key]:-}" ]]; then
            R_SUFFIX[$key]="$mps_suffix"
            R_DESC[$key]="$mps_desc"
            R_TYPE[$key]="$mps_type_name"
            R_TYPE_ID[$key]="$mps_type_val"
            R_SOURCE[$key]="LEXMARK-MPS-MIB"
            FOUND_KEYS+=("$key")
        fi
    done
fi

# ── Si no hay resultados ───────────────────────────────────────────────────────
if [[ "${#FOUND_KEYS[@]}" -eq 0 ]]; then
    if [[ "$OUTPUT_MODE" == "json" ]]; then
        echo '{"error":"no_supplies_detected","supplies":[]}'
    else
        echo "${RED}No se detectaron consumibles en la impresora.${RESET}"
        echo ""
        echo "${DIM}Respuestas SNMP obtenidas:${RESET}"
        for line in "${DESC_LINES[@]}"; do
            echo "  $line"
        done
    fi
    exit 3
fi

# ── Paso 3: Obtener nivel, capacidad, unidad y clase ─────────────────────────
for key in "${FOUND_KEYS[@]}"; do
    suffix="${R_SUFFIX[$key]}"
    source="${R_SOURCE[$key]}"

    if [[ "$source" == "Printer-MIB" ]]; then
        level_oid="${OID_LEVEL}.${suffix}"
        max_oid="${OID_MAX}.${suffix}"
        unit_oid="${OID_UNIT}.${suffix}"
        class_oid="${OID_CLASS}.${suffix}"
    else
        # LEXMARK-MPS-MIB
        level_oid="${MPS_CURR_SUPPLY_LEVEL}.${suffix}"
        max_oid="${MPS_CURR_SUPPLY_CAP}.${suffix}"
        unit_oid="${MPS_CURR_SUPPLY_CAP_UNIT}.${suffix}"
        class_oid=""  # No hay clase directa en MPS-MIB
    fi

    # Nivel actual
    level_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$level_oid" 2>/dev/null || echo "INTEGER: -2")
    level=$(get_int_value "$level_raw")
    R_LEVEL[$key]=$(to_int "$level")

    # Capacidad máxima
    max_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$max_oid" 2>/dev/null || echo "INTEGER: -2")
    max=$(get_int_value "$max_raw")
    R_MAX[$key]=$(to_int "$max")

    # Unidad de medida
    unit_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$unit_oid" 2>/dev/null || echo "INTEGER: 7")
    unit_val=$(get_int_value "$unit_raw")
    R_UNIT_NUM[$key]="$unit_val"
    case "$unit_val" in
        3)  R_UNIT[$key]="diezmilesimas de pulgada" ;;
        4)  R_UNIT[$key]="micrometros" ;;
        5)  R_UNIT[$key]="hojas" ;;
        7)  R_UNIT[$key]="impresiones" ;;
        8)  R_UNIT[$key]="paginas" ;;
        11) R_UNIT[$key]="porcentaje" ;;
        13) R_UNIT[$key]="porcentaje" ;;
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

    # Clase de consumible
    if [[ -n "$class_oid" ]]; then
        class_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$class_oid" 2>/dev/null || echo "INTEGER: 1")
        class_val=$(get_int_value "$class_raw")
    else
        # En MPS-MIB no hay class, inferir por tipo
        type_name="${R_TYPE[$key]}"
        if is_receptacle "$type_name" "0"; then
            class_val=4
        else
            class_val=3
        fi
    fi
    R_CLASS[$key]="$class_val"

    # Calcular porcentaje
    level_int="${R_LEVEL[$key]}"
    max_int="${R_MAX[$key]}"
    special=$(interpret_special "$level_int")

    if [[ -n "$special" ]]; then
        R_PCT[$key]="$special"
    elif [[ "$level_int" -ge 0 && "$max_int" -gt 0 ]]; then
        pct=$(( (level_int * 100) / max_int ))
        R_PCT[$key]="$pct"
    elif [[ "$level_int" -ge 0 && "$level_int" -le 100 ]]; then
        R_PCT[$key]="$level_int"
    else
        R_PCT[$key]="N/A"
    fi
done

# ── Paso 3b: Obtener número de serie y contadores de páginas ─────────────────
# Número de serie: múltiples fuentes con fallback
#   1. Printer-MIB: prtGeneralSerialNumber = 1.3.6.1.2.1.43.5.1.1.17
#   2. LEXMARK-MPS-MIB: deviceSerialNumber = 1.3.6.1.4.1.641.4.4.2.1.5
#   3. Lexmark privado: prtgenSerialNo = 1.3.6.1.4.1.641.2.1.2.1.6

OID_PRINTER_SERIAL="1.3.6.1.2.1.43.5.1.1.17"            # prtGeneralSerialNumber
OID_MPS_DEVICE_SERIAL="1.3.6.1.4.1.641.4.4.2.1.5"    # deviceSerialNumber
OID_LEX_SERIAL="1.3.6.1.4.1.641.2.1.2.1.6"             # prtgenSerialNo

PRINTER_SERIAL=""
PRINTER_MODEL=""

# Intentar Printer-MIB primero
serial_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_PRINTER_SERIAL" 2>/dev/null || true)
if [[ -n "$serial_raw" ]] && [[ "$serial_raw" == *"STRING:"* ]]; then
    PRINTER_SERIAL=$(get_string_value "$serial_raw")
fi

# Si no, intentar MPS-MIB
if [[ -z "$PRINTER_SERIAL" ]] && [[ "$MPS_AVAILABLE" == "true" ]]; then
    serial_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_MPS_DEVICE_SERIAL" 2>/dev/null || true)
    if [[ -n "$serial_raw" ]] && [[ "$serial_raw" == *"STRING:"* ]]; then
        PRINTER_SERIAL=$(get_string_value "$serial_raw")
    fi
fi

# Si no, intentar lexmark1.mib
if [[ -z "$PRINTER_SERIAL" ]]; then
    serial_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_LEX_SERIAL" 2>/dev/null || true)
    if [[ -n "$serial_raw" ]] && [[ "$serial_raw" == *"STRING:"* ]]; then
        PRINTER_SERIAL=$(get_string_value "$serial_raw")
    fi
fi

# Modelo de impresora (MPS-MIB)
if [[ "$MPS_AVAILABLE" == "true" ]]; then
    model_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "1.3.6.1.4.1.641.4.4.2.1.4" 2>/dev/null || true)
    if [[ -n "$model_raw" ]] && [[ "$model_raw" == *"STRING:"* ]]; then
        PRINTER_MODEL=$(get_string_value "$model_raw")
    fi
fi

# ── Contadores de páginas ────────────────────────────────────────────────────
# Fuente 1: lexmark1.mib (pgcount) — contadores simples
#   lexmark = 1.3.6.1.4.1.641
#   printer = .641.2
#   prtgen = .641.2.1
#   pgcount = .641.2.1.5
#     pgTotal = .641.2.1.5.1  (total páginas)
#     pgMono = .641.2.1.5.2   (páginas monocromo)
#     pgColor = .641.2.1.5.3  (páginas color)
#
# Fuente 2: LEXMARK-MPS-MIB (paperGeneralCountTable)
#   stats = .641.4.4.5
#   paperStats = .641.4.4.5.2
#   paperGeneralCountTable = .641.4.4.5.2.1
#     paperGeneralCountEntry = .641.4.4.5.2.1.1
#       .1 = index
#       .2 = type (16=printTotal, 17=printMono, 18=printColor)
#       .3 = units
#       .4 = value (Counter32)
#   Hay que hacer walk y filtrar por type
#
# Fuente 3: Printer-MIB (prtMarkerLifeCount)
#   prtMarkerLifeCount = 1.3.6.1.2.1.43.10.2.1.4  (total páginas vida de la impresora)
#   prtMarkerPowerOnCount = 1.3.6.1.2.1.43.10.2.1.5 (total desde último encendido)
#

OID_PG_TOTAL="1.3.6.1.4.1.641.2.1.5.1"     # pgTotal
OID_PG_MONO="1.3.6.1.4.1.641.2.1.5.2"      # pgMono
OID_PG_COLOR="1.3.6.1.4.1.641.2.1.5.3"     # pgColor
OID_MPS_COUNT_TYPE="1.3.6.1.4.1.641.4.4.5.2.1.1.2"   # paperGeneralCountType
OID_MPS_COUNT_VAL="1.3.6.1.4.1.641.4.4.5.2.1.1.4"   # paperGeneralCountValue
OID_PMIB_LIFE_COUNT="1.3.6.1.2.1.43.10.2.1.4"        # prtMarkerLifeCount
OID_PMIB_POWERON_COUNT="1.3.6.1.2.1.43.10.2.1.5"     # prtMarkerPowerOnCount

PAGE_TOTAL=""
PAGE_MONO=""
PAGE_COLOR=""
PAGE_POWERON=""
COUNTER_SOURCE=""

# Intentar lexmark1.mib primero (contadores directos K y color)
mono_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_PG_MONO" 2>/dev/null || true)
color_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_PG_COLOR" 2>/dev/null || true)
total_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_PG_TOTAL" 2>/dev/null || true)

if [[ -n "$mono_raw" ]] && [[ "$mono_raw" == *"INTEGER:"* ]] && [[ -n "$color_raw" ]] && [[ "$color_raw" == *"INTEGER:"* ]]; then
    PAGE_MONO=$(get_int_value "$mono_raw")
    PAGE_COLOR=$(get_int_value "$color_raw")
    if [[ -n "$total_raw" ]] && [[ "$total_raw" == *"INTEGER:"* ]]; then
        PAGE_TOTAL=$(get_int_value "$total_raw")
    else
        PAGE_TOTAL=$(( PAGE_MONO + PAGE_COLOR ))
    fi
    COUNTER_SOURCE="lexmark1.mib (pgcount)"
else
    # Fallback: LEXMARK-MPS-MIB paperGeneralCountTable
    # Hacer walk del type y value, luego cruzar
    if [[ "$MPS_AVAILABLE" == "true" ]]; then
        mapfile -t MPS_COUNT_TYPE_LINES < <(snmpwalk "${SNMP_FLAGS[@]}" "$HOST" "$OID_MPS_COUNT_TYPE" 2>/dev/null || true)
        mapfile -t MPS_COUNT_VAL_LINES < <(snmpwalk "${SNMP_FLAGS[@]}" "$HOST" "$OID_MPS_COUNT_VAL" 2>/dev/null || true)

        # Mapear suffix -> type y suffix -> value
        declare -A MPS_CT_TYPE MPS_CT_VAL
        for line in "${MPS_COUNT_TYPE_LINES[@]}"; do
            [[ "$line" != *"INTEGER:"* ]] && continue
            # Extraer sufijo (lo que va después del OID base)
            ct_suffix=$(echo "$line" | sed -n 's/^\([0-9.]*\).*/\1/p' | sed 's/^1\.3\.6\.1\.4\.1\.641\.4\.4\.5\.2\.1\.1\.2\.//')
            ct_type=$(get_int_value "$line")
            MPS_CT_TYPE[$ct_suffix]=$ct_type
        done
        for line in "${MPS_COUNT_VAL_LINES[@]}"; do
            [[ "$line" != *"Counter32:"* ]] && [[ "$line" != *"INTEGER:"* ]] && continue
            ct_suffix=$(echo "$line" | sed -n 's/^\([0-9.]*\).*/\1/p' | sed 's/^1\.3\.6\.1\.4\.1\.641\.4\.4\.5\.2\.1\.1\.4\.//')
            ct_val=$(get_int_value "$line")
            MPS_CT_VAL[$ct_suffix]=$ct_val
        done

        # Buscar type 16 (printTotal), 17 (printMono), 18 (printColor)
        for ct_suffix in "${!MPS_CT_TYPE[@]}"; do
            ct_type="${MPS_CT_TYPE[$ct_suffix]}"
            ct_val="${MPS_CT_VAL[$ct_suffix]:-0}"
            case "$ct_type" in
                16) PAGE_TOTAL="$ct_val" ;;
                17) PAGE_MONO="$ct_val" ;;
                18) PAGE_COLOR="$ct_val" ;;
            esac
        done

        if [[ -n "$PAGE_MONO" ]] || [[ -n "$PAGE_COLOR" ]]; then
            COUNTER_SOURCE="LEXMARK-MPS-MIB (paperGeneralCountTable)"
            [[ -z "$PAGE_TOTAL" ]] && [[ -n "$PAGE_MONO" ]] && [[ -n "$PAGE_COLOR" ]] && PAGE_TOTAL=$(( PAGE_MONO + PAGE_COLOR ))
        fi
    fi
fi

# Si aún no hay total, usar prtMarkerLifeCount del Printer-MIB
if [[ -z "$PAGE_TOTAL" ]]; then
    life_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_PMIB_LIFE_COUNT" 2>/dev/null || true)
    if [[ -n "$life_raw" ]] && [[ "$life_raw" == *"INTEGER:"* ]]; then
        PAGE_TOTAL=$(get_int_value "$life_raw")
        [[ -z "$COUNTER_SOURCE" ]] && COUNTER_SOURCE="Printer-MIB (prtMarkerLifeCount)"
    fi
fi

# Contador desde último encendido (siempre del Printer-MIB)
poweron_raw=$(snmpget "${SNMP_FLAGS[@]}" "$HOST" "$OID_PMIB_POWERON_COUNT" 2>/dev/null || true)
if [[ -n "$poweron_raw" ]] && [[ "$poweron_raw" == *"INTEGER:"* ]]; then
    PAGE_POWERON=$(get_int_value "$poweron_raw")
fi

# ── Paso 4: Salida ────────────────────────────────────────────────────────────

# Colores ANSI por key
get_ansi() {
    local key="$1" type_name="$2"
    # Primero intentar por color (black/cyan/magenta/yellow)
    case "$key" in
        black)   echo "$BOLD" ;;
        cyan)    echo "$CYAN" ;;
        magenta) echo "$MAGENTA" ;;
        yellow)  echo "$YELLOW" ;;
        *)       echo "${SUPPLY_ANSI_DEFAULT[$type_name]:-$BOLD}" ;;
    esac
}

get_label() {
    local key="$1" type_name="$2" desc="$3"
    case "$key" in
        black)   echo "Tóner Negro (K)" ;;
        cyan)    echo "Tóner Cian (C)" ;;
        magenta) echo "Tóner Magenta (M)" ;;
        yellow)  echo "Tóner Amarillo (Y)" ;;
        *)
            local label="${SUPPLY_LABEL_ES[$type_name]:-$type_name}"
            # Si hay descripción con color, añadir
            desc_lower=$(lowercase "$desc")
            if echo "$desc_lower" | grep -iq "black\|negro"; then
                label="${label} — Negro"
            elif echo "$desc_lower" | grep -iq "cyan\|cian"; then
                label="${label} — Cian"
            elif echo "$desc_lower" | grep -iq "magenta"; then
                label="${label} — Magenta"
            elif echo "$desc_lower" | grep -iq "yellow\|amarillo"; then
                label="${label} — Amarillo"
            fi
            echo "$label"
            ;;
    esac
}

# ── Modo JSON ────────────────────────────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "json" ]]; then
    echo "{"
    echo "  \"host\": \"${HOST}\","
    echo "  \"snmp_version\": \"${SNMP_VERSION}\","
    echo "  \"supplies\": ["

    first=true
    for key in "${FOUND_KEYS[@]}"; do
        if [[ "$first" == "true" ]]; then first=false; else echo ","; fi

        suffix="${R_SUFFIX[$key]}"
        type_name="${R_TYPE[$key]}"
        type_id="${R_TYPE_ID[$key]}"
        desc="${R_DESC[$key]}"
        class_val="${R_CLASS[$key]}"
        level="${R_LEVEL[$key]}"
        max="${R_MAX[$key]}"
        pct="${R_PCT[$key]}"
        unit="${R_UNIT[$key]}"
        unit_num="${R_UNIT_NUM[$key]}"
        source="${R_SOURCE[$key]}"
        label=$(get_label "$key" "$type_name" "$desc")

        # Clase legible
        case "$class_val" in
            3) class_str="supplyThatIsConsumed" ;;
            4) class_str="receptacleThatIsFilled" ;;
            *) class_str="other" ;;
        esac

        # Waste?
        is_waste=false
        if is_receptacle "$type_name" "$class_val"; then is_waste=true; fi

        # Porcentaje como número o string
        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            pct_json="$pct"
        else
            pct_json="\"$pct\""
        fi

        # OIDs según fuente
        if [[ "$source" == "Printer-MIB" ]]; then
            oid_desc="${OID_DESC}.${suffix}"
            oid_type="${OID_TYPE}.${suffix}"
            oid_class="${OID_CLASS}.${suffix}"
            oid_unit="${OID_UNIT}.${suffix}"
            oid_max="${OID_MAX}.${suffix}"
            oid_level="${OID_LEVEL}.${suffix}"
        else
            oid_desc="${MPS_CURR_SUPPLY_DESC}.${suffix}"
            oid_type="${MPS_CURR_SUPPLY_TYPE}.${suffix}"
            oid_class=""
            oid_unit="${MPS_CURR_SUPPLY_CAP_UNIT}.${suffix}"
            oid_max="${MPS_CURR_SUPPLY_CAP}.${suffix}"
            oid_level="${MPS_CURR_SUPPLY_LEVEL}.${suffix}"
        fi

        cat <<JSONEOF
    {
      "name": "${key}",
      "label": "${label}",
      "description": "${desc}",
      "type": "${type_name}",
      "type_id": ${type_id:-0},
      "class": "${class_str}",
      "class_id": ${class_val:-1},
      "is_waste": ${is_waste},
      "source": "${source}",
      "suffix": "${suffix}",
      "oid_description": "${oid_desc}",
      "oid_type": "${oid_type}",
      "oid_class": "${oid_class}",
      "oid_unit": "${oid_unit}",
      "oid_max_capacity": "${oid_max}",
      "oid_level": "${oid_level}",
      "level": ${level},
      "max_capacity": ${max},
      "unit": "${unit}",
      "unit_id": ${unit_num},
      "percent": ${pct_json}
    }
JSONEOF
    done

    echo ""
    echo "  ],"
    # Información del dispositivo
    echo "  \"device\": {"
    echo "    \"serial_number\": \"${PRINTER_SERIAL}\","
    echo "    \"model\": \"${PRINTER_MODEL}\""
    echo "  },"
    # Contadores
    echo "  \"counters\": {"
    echo "    \"source\": \"${COUNTER_SOURCE}\","
    if [[ -n "$PAGE_TOTAL" ]]; then
        echo "    \"total_pages\": ${PAGE_TOTAL},"
    else
        echo "    \"total_pages\": null,"
    fi
    if [[ -n "$PAGE_MONO" ]]; then
        echo "    \"mono_pages\": ${PAGE_MONO},"
    else
        echo "    \"mono_pages\": null,"
    fi
    if [[ -n "$PAGE_COLOR" ]]; then
        echo "    \"color_pages\": ${PAGE_COLOR},"
    else
        echo "    \"color_pages\": null,"
    fi
    if [[ -n "$PAGE_POWERON" ]]; then
        echo "    \"poweron_pages\": ${PAGE_POWERON}"
    else
        echo "    \"poweron_pages\": null"
    fi
    echo "  }"
    echo "}"
    exit 0
fi

# ── Modo OIDs ─────────────────────────────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "oids" ]]; then
    echo "# OIDs exactos detectados para ${HOST}"
    echo "#"
    echo "# Printer-MIB:        1.3.6.1.2.1.43.11.1.1 (prtMarkerSuppliesEntry)"
    echo "# LEXMARK-MPS-MIB: 1.3.6.1.4.1.641.4.4.5.4.7.1 (currentSuppliesEntry)"
    echo "#"
    echo "# Formato Printer-MIB: <OID_base>.<hrDeviceIndex>.<supplyIndex>"
    echo "# Formato MPS-MIB:     <OID_base>.<deviceIndex>.<supplyIndex>"
    echo ""

    for key in "${FOUND_KEYS[@]}"; do
        suffix="${R_SUFFIX[$key]}"
        type_name="${R_TYPE[$key]}"
        type_id="${R_TYPE_ID[$key]}"
        desc="${R_DESC[$key]}"
        source="${R_SOURCE[$key]}"
        label=$(get_label "$key" "$type_name" "$desc")

        echo "# ${label} — ${desc} (type=${type_name}, id=${type_id}, src=${source})"

        if [[ "$source" == "Printer-MIB" ]]; then
            echo "DESC    ${OID_DESC}.${suffix}"
            echo "TYPE    ${OID_TYPE}.${suffix}"
            echo "CLASS   ${OID_CLASS}.${suffix}"
            echo "UNIT    ${OID_UNIT}.${suffix}"
            echo "MAX     ${OID_MAX}.${suffix}"
            echo "LEVEL   ${OID_LEVEL}.${suffix}"
        else
            echo "DESC    ${MPS_CURR_SUPPLY_DESC}.${suffix}"
            echo "TYPE    ${MPS_CURR_SUPPLY_TYPE}.${suffix}"
            echo "UNIT    ${MPS_CURR_SUPPLY_CAP_UNIT}.${suffix}"
            echo "MAX     ${MPS_CURR_SUPPLY_CAP}.${suffix}"
            echo "LEVEL   ${MPS_CURR_SUPPLY_LEVEL}.${suffix}"
            echo "DAYS    ${MPS_CURR_SUPPLY_DAYS}.${suffix}"
        fi
        echo ""
    done

    echo "# ── Número de serie ──────────────────────────────────────────────"
    echo "# Printer-MIB:        ${OID_PRINTER_SERIAL}  (prtGeneralSerialNumber)"
    echo "# LEXMARK-MPS-MIB:  ${OID_MPS_DEVICE_SERIAL}  (deviceSerialNumber)"
    echo "# Lexmark privado:    ${OID_LEX_SERIAL}  (prtgenSerialNo)"
    echo "#"
    if [[ -n "$PRINTER_SERIAL" ]]; then
        echo "SERIAL  ${PRINTER_SERIAL}"
    else
        echo "SERIAL  (no detectado)"
    fi
    echo ""

    echo "# ── Contadores de páginas ───────────────────────────────────────"
    echo "# lexmark1.mib (pgcount):"
    echo "#   TOTAL  ${OID_PG_TOTAL}"
    echo "#   MONO   ${OID_PG_MONO}"
    echo "#   COLOR  ${OID_PG_COLOR}"
    echo "#"
    echo "# LEXMARK-MPS-MIB (paperGeneralCountTable):"
    echo "#   TYPE   ${OID_MPS_COUNT_TYPE}  (16=printTotal, 17=printMono, 18=printColor)"
    echo "#   VALUE  ${OID_MPS_COUNT_VAL}"
    echo "#"
    echo "# Printer-MIB (prtMarker):"
    echo "#   LIFE      ${OID_PMIB_LIFE_COUNT}  (total páginas vida impresora)"
    echo "#   POWERON   ${OID_PMIB_POWERON_COUNT}  (páginas desde último encendido)"
    echo "#"
    echo "# Valores detectados (fuente: ${COUNTER_SOURCE:-ninguna}):"
    if [[ -n "$PAGE_TOTAL" ]]; then
        echo "TOTAL_PAGES     ${PAGE_TOTAL}"
    else
        echo "TOTAL_PAGES     (no disponible)"
    fi
    if [[ -n "$PAGE_MONO" ]]; then
        echo "MONO_PAGES      ${PAGE_MONO}"
    else
        echo "MONO_PAGES      (no disponible)"
    fi
    if [[ -n "$PAGE_COLOR" ]]; then
        echo "COLOR_PAGES     ${PAGE_COLOR}"
    else
        echo "COLOR_PAGES     (no disponible)"
    fi
    if [[ -n "$PAGE_POWERON" ]]; then
        echo "POWERON_PAGES   ${PAGE_POWERON}"
    else
        echo "POWERON_PAGES   (no disponible)"
    fi
    exit 0
fi

# ── Modo humano (por defecto) ────────────────────────────────────────────────
echo ""
echo "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo "${BOLD}  Monitor de Consumibles — Lexmark SNMP${RESET}"
echo "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo "  Host:       ${CYAN}${HOST}${RESET}"
echo "  Community:  ${CYAN}${COMMUNITY}${RESET}"
echo "  SNMP:       ${CYAN}v${SNMP_VERSION}${RESET}"
if [[ "$MPS_AVAILABLE" == "true" ]]; then
    echo "  MPS-MIB:    ${GREEN}disponible${RESET}"
else
    echo "  MPS-MIB:    ${DIM}no disponible (solo Printer-MIB)${RESET}"
fi
if [[ -n "$PRINTER_SERIAL" ]]; then
    echo "  Serie:      ${CYAN}${PRINTER_SERIAL}${RESET}"
fi
if [[ -n "$PRINTER_MODEL" ]]; then
    echo "  Modelo:     ${CYAN}${PRINTER_MODEL}${RESET}"
fi
echo ""

echo "${BOLD}Consumibles detectados (${#FOUND_KEYS[@]}):${RESET}"
echo "${DIM}────────────────────────────────────────────────────────────────${RESET}"
echo ""

for key in "${FOUND_KEYS[@]}"; do
    type_name="${R_TYPE[$key]}"
    ansi=$(get_ansi "$key" "$type_name")
    label=$(get_label "$key" "$type_name" "${R_DESC[$key]}")
    desc="${R_DESC[$key]}"
    suffix="${R_SUFFIX[$key]}"
    type_id="${R_TYPE_ID[$key]}"
    class_val="${R_CLASS[$key]}"
    level="${R_LEVEL[$key]}"
    max="${R_MAX[$key]}"
    pct="${R_PCT[$key]}"
    unit="${R_UNIT[$key]}"
    source="${R_SOURCE[$key]}"

    # Clase legible
    case "$class_val" in
        3) class_str="consumible" ;;
        4) class_str="receptaculo" ;;
        *) class_str="otro" ;;
    esac

    # Waste?
    waste=false
    if is_receptacle "$type_name" "$class_val"; then waste=true; fi

    echo "  ${ansi}${label}${RESET}  ${DIM}— ${desc}${RESET}"
    echo "  ${DIM}Tipo SNMP:      ${type_name} (id=${type_id})  Clase: ${class_str}${RESET}"
    echo "  ${DIM}Fuente:         ${source}${RESET}"
    echo "  ${DIM}Índice:         ${suffix}${RESET}"

    if [[ "$source" == "Printer-MIB" ]]; then
        echo "  ${DIM}OID nivel:      ${OID_LEVEL}.${suffix}${RESET}"
        echo "  ${DIM}OID máximo:    ${OID_MAX}.${suffix}${RESET}"
    else
        echo "  ${DIM}OID nivel:      ${MPS_CURR_SUPPLY_LEVEL}.${suffix}${RESET}"
        echo "  ${DIM}OID máximo:    ${MPS_CURR_SUPPLY_CAP}.${suffix}${RESET}"
    fi

    echo "  ${DIM}Nivel actual:   ${level} / ${max} ${unit}${RESET}"

    if [[ "$pct" == "OTRO" ]] || [[ "$pct" == "DESCONOCIDO" ]] || [[ "$pct" == "ACCION_REQUERIDA" ]]; then
        echo "  ${RED}Estado: ${pct}${RESET}"
    elif [[ "$pct" =~ ^[0-9]+$ ]]; then
        if [[ "$waste" == "true" ]]; then
            # Receptáculo: se llena, más lleno = peor
            bar_color="$RED"
            printf "  Llenado:        %3d%%  " "$pct"
            progress_bar "$pct" "$bar_color"
            if [[ "$pct" -ge 90 ]]; then
                echo "  ${RED}${BOLD}URGENTE: casi lleno${RESET}"
            elif [[ "$pct" -ge 75 ]]; then
                echo "  ${YELLOW}Revisar pronto${RESET}"
            else
                echo ""
            fi
        else
            # Consumible: se vacía, menos = peor
            if [[ "$pct" -ge 30 ]]; then
                bar_color="$GREEN"
            elif [[ "$pct" -ge 10 ]]; then
                bar_color="$YELLOW"
            else
                bar_color="$RED"
            fi
            printf "  Nivel:          %3d%%  " "$pct"
            progress_bar "$pct" "$bar_color"
            echo ""
        fi
    else
        echo "  Nivel:          $pct"
    fi
    echo ""
done

# ── Resumen compacto ──────────────────────────────────────────────────────────
echo "${BOLD}Resumen:${RESET}"
echo "${DIM}────────────────────────────────────────────────────────────────${RESET}"
for key in "${FOUND_KEYS[@]}"; do
    type_name="${R_TYPE[$key]}"
    ansi=$(get_ansi "$key" "$type_name")
    label=$(get_label "$key" "$type_name" "${R_DESC[$key]}")
    pct="${R_PCT[$key]}"
    level="${R_LEVEL[$key]}"
    max="${R_MAX[$key]}"

    waste=false
    if is_receptacle "$type_name" "${R_CLASS[$key]}"; then waste=true; fi

    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if [[ "$waste" == "true" ]]; then
            printf "  ${ansi}%-22s${RESET} %3d%% lleno   (%s / %s)\n" "$label" "$pct" "$level" "$max"
        else
            printf "  ${ansi}%-22s${RESET} %3d%% restante (%s / %s)\n" "$label" "$pct" "$level" "$max"
        fi
    else
        printf "  ${ansi}%-22s${RESET} %s\n" "$label" "$pct"
    fi
done
echo ""

# ── Contadores de páginas ──────────────────────────────────────────────────────
if [[ -n "$PAGE_TOTAL" ]] || [[ -n "$PAGE_MONO" ]] || [[ -n "$PAGE_COLOR" ]]; then
    echo "${BOLD}Contadores de páginas:${RESET}"
    echo "${DIM}────────────────────────────────────────────────────────────────${RESET}"
    if [[ -n "$COUNTER_SOURCE" ]]; then
        echo "  ${DIM}Fuente: ${COUNTER_SOURCE}${RESET}"
    fi
    if [[ -n "$PAGE_TOTAL" ]]; then
        printf "  ${BOLD}%-22s${RESET} %'d páginas\n" "Total:" "$PAGE_TOTAL"
    fi
    if [[ -n "$PAGE_MONO" ]]; then
        printf "  ${BOLD}%-22s${RESET} %'d páginas\n" "Monocromo (negro):" "$PAGE_MONO"
    fi
    if [[ -n "$PAGE_COLOR" ]]; then
        printf "  ${BOLD}%-22s${RESET} %'d páginas\n" "Color:" "$PAGE_COLOR"
    fi
    if [[ -n "$PAGE_POWERON" ]]; then
        printf "  ${DIM}%-22s${RESET} %'d páginas\n" "Desde encendido:" "$PAGE_POWERON"
    fi
    echo ""
fi

# ── Código de salida ──────────────────────────────────────────────────────────
# 0 = OK, 1 = alerta (consumible <10% o waste >90%), 2 = error conexión
exit_code=0
for key in "${FOUND_KEYS[@]}"; do
    pct="${R_PCT[$key]}"
    type_name="${R_TYPE[$key]}"
    waste=false
    if is_receptacle "$type_name" "${R_CLASS[$key]}"; then waste=true; fi

    if [[ "$pct" =~ ^[0-9]+$ ]]; then
        if [[ "$waste" == "true" ]]; then
            [[ "$pct" -ge 90 ]] && exit_code=1
        else
            [[ "$pct" -lt 10 ]] && exit_code=1
        fi
    fi
done

if [[ "$exit_code" -eq 1 ]]; then
    echo "${RED}${BOLD}⚠  Alerta: revisar consumibles.${RESET}"
fi

exit "$exit_code"
