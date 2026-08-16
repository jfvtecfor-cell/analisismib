#!/bin/bash

# =============================================================================
# Script: scan_hp_printer.sh
# Descripción: Escanea una impresora HP mediante SNMP y muestra los niveles de
#              consumibles (tóner, depósito residual, fusor) y contadores.
# Uso: ./scan_hp_printer.sh <IP_PRINTER> [COMMUNITY_STRING]
# Ejemplo: ./scan_hp_printer.sh 192.168.1.100 public
# =============================================================================

# --- Configuración ---
COMMUNITY="public"  # Comunidad SNMP por defecto
TIMEOUT=5          # Timeout en segundos para comandos SNMP

# --- Validación de parámetros ---
if [ -z "$1" ]; then
    echo "❌ Uso: $0 <IP_PRINTER> [COMMUNITY_STRING]"
    echo "   Ejemplo: $0 192.168.1.100 public"
    exit 1
fi

IP_PRINTER="$1"
if [ -n "$2" ]; then
    COMMUNITY="$2"
fi

# Verificar si net-snmp está instalado
if ! command -v snmpwalk &> /dev/null || ! command -v snmpget &> /dev/null; then
    echo "❌ Error: Se requiere net-snmp (paquete 'snmp' o 'net-snmp')."
    echo "   Instálalo con: pkg install net-snmp  (Termux/Android)"
    echo "                o: sudo apt install snmp  (Debian/Ubuntu)"
    exit 1
fi

# --- Funciones auxiliares ---
print_header() {
    echo ""
    echo "============================================================================="
    echo "  🖨️  ESCANEO SNMP DE IMPRESORA HP - $IP_PRINTER"
    echo "============================================================================="
}

print_section() {
    echo ""
    echo "--- $1 ---"
}

# Función para obtener valor SNMP con timeout
snmp_get() {
    timeout $TIMEOUT snmpget -v2c -c "$COMMUNITY" "$IP_PRINTER" "$1" 2>/dev/null | grep -v "Timeout" | grep -v "No Such" | awk -F': ' '{print $2}'
}

# Función para obtener tabla SNMP
snmp_walk() {
    timeout $TIMEOUT snmpwalk -v2c -c "$COMMUNITY" "$IP_PRINTER" "$1" 2>/dev/null | grep -v "Timeout" | grep -v "No Such"
}

# --- OID principales ---
OID_PRINTER_MIB="1.3.6.1.2.1.43"
OID_SERIAL="$OID_PRINTER_MIB.5.1.1.17.1"                  # prtGeneralSerialNumber
OID_SUPPLIES_TABLE="$OID_PRINTER_MIB.11.1.1"           # prtMarkerSuppliesTable
OID_MARKER_TABLE="$OID_PRINTER_MIB.10.2.1"             # prtMarkerTable

# --- Inicio del escaneo ---
print_header

# 1. Obtener Serial Number
echo ""
SERIAL=$(snmp_get "$OID_SERIAL")
if [ -n "$SERIAL" ]; then
    echo "🆔 Serial Number: $SERIAL"
    echo "   OID: $OID_SERIAL"
else
    echo "⚠️  Serial Number: No disponible"
fi

# 2. Obtener lista de consumibles (prtMarkerSuppliesTable)
print_section "📊 CONSUMIBLES (Tóner, Depósito Residual, Fusor, etc.)"

# Obtener todos los índices de consumibles
SUPPLIES_INDICES=$(snmp_walk "$OID_SUPPLIES_TABLE.1" | awk -F'[.]' '{print $NF}')

if [ -z "$SUPPLIES_INDICES" ]; then
    echo "❌ No se encontraron consumibles. Verifica la IP y comunidad SNMP."
    exit 1
fi

# Arrays para almacenar información
declare -A SUPPLIES_DESC
declare -A SUPPLIES_TYPE
declare -A SUPPLIES_LEVEL
declare -A SUPPLIES_MAX
declare -A SUPPLIES_UNIT

# Obtener datos de cada consumible
for IDX in $SUPPLIES_INDICES; do
    DESC=$(snmp_get "$OID_SUPPLIES_TABLE.6.1.$IDX" | sed 's/"//g')
    TYPE=$(snmp_get "$OID_SUPPLIES_TABLE.7.1.$IDX")
    LEVEL=$(snmp_get "$OID_SUPPLIES_TABLE.9.1.$IDX")
    MAX=$(snmp_get "$OID_SUPPLIES_TABLE.8.1.$IDX")
    UNIT=$(snmp_get "$OID_SUPPLIES_TABLE.10.1.$IDX")

    SUPPLIES_DESC[$IDX]="$DESC"
    SUPPLIES_TYPE[$IDX]="$TYPE"
    SUPPLIES_LEVEL[$IDX]="$LEVEL"
    SUPPLIES_MAX[$IDX]="$MAX"
    SUPPLIES_UNIT[$IDX]="$UNIT"
done

# Función para calcular porcentaje
calculate_percent() {
    local level=$1
    local max=$2

    if [ "$level" = "-2" ]; then
        echo "🔴 AGOTADO"
    elif [ "$level" = "-3" ]; then
        echo "⚠️  NO SOPORTA % (LLC)"
    elif [ "$max" -gt 0 ] 2>/dev/null && [ "$level" -ge 0 ] 2>/dev/null; then
        percent=$((level * 100 / max))
        echo "${percent}%"
    else
        echo "$level"
    fi
}

# Identificar y mostrar consumibles
for IDX in $SUPPLIES_INDICES; do
    DESC="${SUPPLIES_DESC[$IDX]}"
    TYPE="${SUPPLIES_TYPE[$IDX]}"
    LEVEL="${SUPPLIES_LEVEL[$IDX]}"
    MAX="${SUPPLIES_MAX[$IDX]}"
    UNIT="${SUPPLIES_UNIT[$IDX]}"

    # Determinar el tipo de consumible
    case $TYPE in
        1)
            TYPE_NAME="Tóner"
            ;;
        2)
            TYPE_NAME="Fusor"
            ;;
        3)
            TYPE_NAME="Kit de Mantenimiento"
            ;;
        4)
            TYPE_NAME="Depósito Residual"
            ;;
        *)
            TYPE_NAME="Desconocido (Tipo $TYPE)"
            ;;
    esac

    # Calcular porcentaje
    PERCENT=$(calculate_percent $LEVEL $MAX)

    # Mostrar información
    echo ""
    echo "  📦 $DESC"
    echo "     Tipo: $TYPE_NAME"
    echo "     Nivel: $LEVEL / $MAX ($PERCENT)"
    echo "     OID:  $OID_SUPPLIES_TABLE.9.1.$IDX (Nivel), $OID_SUPPLIES_TABLE.8.1.$IDX (Máx)"

    # Asignar a variables específicas para el resumen final
    case "$DESC" in
        *"Black"*|*"Negro"*|*"K"*)
            BLACK_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"
            BLACK_LEVEL="$LEVEL"
            BLACK_PERCENT="$PERCENT"
            ;;
        *"Cyan"*)
            CYAN_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"
            CYAN_LEVEL="$LEVEL"
            CYAN_PERCENT="$PERCENT"
            ;;
        *"Magenta"*)
            MAGENTA_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"
            MAGENTA_LEVEL="$LEVEL"
            MAGENTA_PERCENT="$PERCENT"
            ;;
        *"Yellow"*|*"Amarillo"*)
            YELLOW_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"
            YELLOW_LEVEL="$LEVEL"
            YELLOW_PERCENT="$PERCENT"
            ;;
        *"Waste"*|*"Residual"*|*"Collection"*)
            WASTE_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"
            WASTE_LEVEL="$LEVEL"
            WASTE_PERCENT="$PERCENT"
            ;;
        *"Fuser"*|*"Fusor"*)
            FUSER_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"
            FUSER_LEVEL="$LEVEL"
            FUSER_PERCENT="$PERCENT"
            ;;
    esac
done

# 3. Resumen de consumibles solicitados
print_section "📋 RESUMEN DE CONSUMIBLES SOLICITADOS"

echo ""
echo "┌──────────────────────┬─────────────────────────────────────────────────────┬─────────────────────┐"
echo "│ Consumible            │ OID                                                 │ Nivel                │"
echo "├──────────────────────┼─────────────────────────────────────────────────────┼─────────────────────┤"

# Tóner Negro
if [ -n "$BLACK_OID" ]; then
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Negro" "$BLACK_OID" "$BLACK_PERCENT"
else
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Negro" "No encontrado" "-"
fi

# Tóner Cyan
if [ -n "$CYAN_OID" ]; then
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Cyan" "$CYAN_OID" "$CYAN_PERCENT"
else
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Cyan" "No encontrado" "-"
fi

# Tóner Magenta
if [ -n "$MAGENTA_OID" ]; then
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Magenta" "$MAGENTA_OID" "$MAGENTA_PERCENT"
else
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Magenta" "No encontrado" "-"
fi

# Tóner Amarillo
if [ -n "$YELLOW_OID" ]; then
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Amarillo" "$YELLOW_OID" "$YELLOW_PERCENT"
else
    printf "│ %-18s │ %-51s │ %-15s │\n" "Tóner Amarillo" "No encontrado" "-"
fi

# Depósito Residual
if [ -n "$WASTE_OID" ]; then
    printf "│ %-18s │ %-51s │ %-15s │\n" "Depósito Residual" "$WASTE_OID" "$WASTE_PERCENT"
else
    printf "│ %-18s │ %-51s │ %-15s │\n" "Depósito Residual" "No encontrado" "-"
fi

# Fusor
if [ -n "$FUSER_OID" ]; then
    printf "│ %-18s │ %-51s │ %-15s │\n" "Fusor" "$FUSER_OID" "$FUSER_PERCENT"
else
    printf "│ %-18s │ %-51s │ %-15s │\n" "Fusor" "No encontrado" "-"
fi

echo "└──────────────────────┴─────────────────────────────────────────────────────┴─────────────────────┘"

# 4. Contadores de páginas
print_section "📈 CONTADORES DE PÁGINAS"

# Contador total de páginas (monocromo + color)
TOTAL_PAGES_OID="$OID_PRINTER_MIB.10.2.1.4.1.1"
TOTAL_PAGES=$(snmp_get "$TOTAL_PAGES_OID")
if [ -n "$TOTAL_PAGES" ]; then
    echo ""
    echo "  📄 Contador Total: $TOTAL_PAGES páginas"
    echo "     OID: $TOTAL_PAGES_OID"
else
    echo "  ⚠️  Contador Total: No disponible"
fi

# Contador de páginas por marcador (para separar negro/color)
print_section "🔢 CONTADORES POR MARCADOR (Negro/Color)"

MARKER_INDICES=$(snmp_walk "$OID_MARKER_TABLE.1.1" | awk -F'[.]' '{print $(NF-1)}' | sort -u)

if [ -n "$MARKER_INDICES" ]; then
    echo ""
    for IDX in $MARKER_INDICES; do
        MARKER_DESC=$(snmp_get "$OID_MARKER_TABLE.1.1.$IDX" | sed 's/"//g')
        MARKER_COUNTER=$(snmp_get "$OID_MARKER_TABLE.4.1.$IDX")

        # Determinar si es negro o color
        if echo "$MARKER_DESC" | grep -qi "black\|negro\|k"; then
            MARKER_TYPE="Negro"
            BLACK_COUNTER="$MARKER_COUNTER"
            BLACK_COUNTER_OID="$OID_MARKER_TABLE.4.1.$IDX"
        else
            MARKER_TYPE="Color"
            COLOR_COUNTER="$MARKER_COUNTER"
            COLOR_COUNTER_OID="$OID_MARKER_TABLE.4.1.$IDX"
        fi

        echo "  $MARKER_TYPE ($MARKER_DESC): $MARKER_COUNTER páginas"
        echo "     OID: $OID_MARKER_TABLE.4.1.$IDX"
    done

    # Resumen de contadores
    echo ""
    echo "┌──────────────────────┬─────────────────────────────────────────────────────┬─────────────────────┐"
    echo "│ Contador              │ OID                                                 │ Valor                │"
    echo "├──────────────────────┼─────────────────────────────────────────────────────┼─────────────────────┤"

    if [ -n "$BLACK_COUNTER_OID" ]; then
        printf "│ %-18s │ %-51s │ %-15s │\n" "Contador Negro" "$BLACK_COUNTER_OID" "$BLACK_COUNTER"
    else
        printf "│ %-18s │ %-51s │ %-15s │\n" "Contador Negro" "No encontrado" "-"
    fi

    if [ -n "$COLOR_COUNTER_OID" ]; then
        printf "│ %-18s │ %-51s │ %-15s │\n" "Contador Color" "$COLOR_COUNTER_OID" "$COLOR_COUNTER"
    else
        printf "│ %-18s │ %-51s │ %-15s │\n" "Contador Color" "No encontrado" "-"
    fi

    echo "└──────────────────────┴─────────────────────────────────────────────────────┴─────────────────────┘"
else
    echo "  ⚠️  No se encontraron contadores por marcador."
fi

# --- Final ---
echo ""
echo "============================================================================="
echo "  ✅ Escaneo completado para $IP_PRINTER"
echo "============================================================================="
echo ""