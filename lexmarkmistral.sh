#!/bin/bash

# =============================================================================
# Script: scan_lexmark_printer.sh
# Descripción: Escanea una impresora Lexmark mediante SNMP y muestra los niveles
#              de consumibles (tóner, unidad de imagen, fusor, depósito residual)
#              con sus OID específicos.
# Uso: ./scan_lexmark_printer.sh <IP_PRINTER> [COMMUNITY_STRING]
# Ejemplo: ./scan_lexmark_printer.sh 192.168.1.100 public
# =============================================================================

# --- Configuración ---
COMMUNITY="public"
TIMEOUT=5

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

if ! command -v snmpwalk &> /dev/null || ! command -v snmpget &> /dev/null; then
    echo "❌ Error: Se requiere net-snmp."
    echo "   Termux: pkg install net-snmp"
    exit 1
fi

print_header() {
    echo ""
    echo "============================================================================="
    echo "  🖨️  ESCANEO SNMP DE IMPRESORA LEXMARK - $IP_PRINTER"
    echo "============================================================================="
}

print_section() {
    echo ""
    echo "--- $1 ---"
}

snmp_get() {
    timeout $TIMEOUT snmpget -v2c -c "$COMMUNITY" "$IP_PRINTER" "$1" 2>/dev/null | grep -v "Timeout" | grep -v "No Such" | awk -F': ' '{print $2}' | sed 's/"//g'
}

snmp_walk() {
    timeout $TIMEOUT snmpwalk -v2c -c "$COMMUNITY" "$IP_PRINTER" "$1" 2>/dev/null | grep -v "Timeout" | grep -v "No Such" | sed 's/"//g'
}

OID_PRINTER_MIB="1.3.6.1.2.1.43"
OID_SERIAL="$OID_PRINTER_MIB.5.1.1.17.1"
OID_SUPPLIES_TABLE="$OID_PRINTER_MIB.11.1.1"

print_header

echo ""
SERIAL=$(snmp_get "$OID_SERIAL")
if [ -n "$SERIAL" ]; then
    echo "🆔 Serial Number: $SERIAL"
    echo "   OID: $OID_SERIAL"
else
    echo "⚠️  Serial Number: No disponible"
fi

print_section "📊 CONSUMIBLES DETECTADOS"

SUPPLIES_RAW=$(snmp_walk "$OID_SUPPLIES_TABLE.6.1")

if [ -z "$SUPPLIES_RAW" ]; then
    echo "❌ No se encontraron consumibles. Verifica la IP y comunidad SNMP."
    exit 1
fi

SUPPLIES_INDICES=$(echo "$SUPPLIES_RAW" | awk -F'[.]' '{print $NF}' | sort -u)

declare -A SUPPLIES_DESC SUPPLIES_TYPE SUPPLIES_LEVEL SUPPLIES_MAX SUPPLIES_UNIT

for IDX in $SUPPLIES_INDICES; do
    SUPPLIES_DESC[$IDX]=$(snmp_get "$OID_SUPPLIES_TABLE.6.1.$IDX")
    SUPPLIES_TYPE[$IDX]=$(snmp_get "$OID_SUPPLIES_TABLE.7.1.$IDX")
    SUPPLIES_LEVEL[$IDX]=$(snmp_get "$OID_SUPPLIES_TABLE.9.1.$IDX")
    SUPPLIES_MAX[$IDX]=$(snmp_get "$OID_SUPPLIES_TABLE.8.1.$IDX")
    SUPPLIES_UNIT[$IDX]=$(snmp_get "$OID_SUPPLIES_TABLE.10.1.$IDX")
done

calculate_percent() {
    local level=$1 max=$2 unit=$3
    if [ "$level" = "-1" ]; then echo "⚪ OTRO"
    elif [ "$level" = "-2" ]; then echo "🔴 DESCONOCIDO"
    elif [ "$level" = "-3" ]; then echo "⚠️  NO SOPORTA %"
    elif [ "$max" -gt 0 ] 2>/dev/null && [ "$level" -ge 0 ] 2>/dev/null; then
        if [ "$unit" = "19" ]; then echo "${level}%"
        else percent=$((level * 100 / max)); echo "${percent}%"
        fi
    else echo "$level"
    fi
}

for IDX in $SUPPLIES_INDICES; do
    DESC="${SUPPLIES_DESC[$IDX]}"
    TYPE="${SUPPLIES_TYPE[$IDX]}"
    LEVEL="${SUPPLIES_LEVEL[$IDX]}"
    MAX="${SUPPLIES_MAX[$IDX]}"
    UNIT="${SUPPLIES_UNIT[$IDX]}"

    case "$DESC" in
        *"Toner"*|*"Cartridge"*|*"Black"*|*"Cyan"*|*"Magenta"*|*"Yellow"*|*"Amarillo"*) TYPE_NAME="Tóner" ;;
        *"Imaging Unit"*|*"Unidad de Imagen"*) TYPE_NAME="Unidad de Imagen" ;;
        *"Fuser"*|*"Fusor"*) TYPE_NAME="Fusor" ;;
        *"Waste"*|*"Residual"*|*"Collection"*|*"Depósito"*) TYPE_NAME="Depósito Residual" ;;
        *"Transfer"*|*"Módulo de Transferencia"*) TYPE_NAME="Módulo de Transferencia" ;;
        *"Maintenance"*) TYPE_NAME="Kit de Mantenimiento" ;;
        *) TYPE_NAME="Desconocido" ;;
    esac

    PERCENT=$(calculate_percent $LEVEL $MAX $UNIT)

    echo ""
    echo "  📦 $DESC"
    echo "     Tipo: $TYPE_NAME"
    echo "     Nivel: $LEVEL / $MAX"
    echo "     Unidad: $UNIT"
    echo "     Porcentaje: $PERCENT"
    echo "     OID Nivel: $OID_SUPPLIES_TABLE.9.1.$IDX"
    echo "     OID Máximo: $OID_SUPPLIES_TABLE.8.1.$IDX"

    case "$DESC" in
        *"Black"*|*"Negro"*) BLACK_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"; BLACK_MAX_OID="$OID_SUPPLIES_TABLE.8.1.$IDX"; BLACK_LEVEL="$LEVEL"; BLACK_MAX="$MAX"; BLACK_PERCENT="$PERCENT" ;;
        *"Cyan"*) CYAN_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"; CYAN_MAX_OID="$OID_SUPPLIES_TABLE.8.1.$IDX"; CYAN_LEVEL="$LEVEL"; CYAN_MAX="$MAX"; CYAN_PERCENT="$PERCENT" ;;
        *"Magenta"*) MAGENTA_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"; MAGENTA_MAX_OID="$OID_SUPPLIES_TABLE.8.1.$IDX"; MAGENTA_LEVEL="$LEVEL"; MAGENTA_MAX="$MAX"; MAGENTA_PERCENT="$PERCENT" ;;
        *"Yellow"*|*"Amarillo"*) YELLOW_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"; YELLOW_MAX_OID="$OID_SUPPLIES_TABLE.8.1.$IDX"; YELLOW_LEVEL="$LEVEL"; YELLOW_MAX="$MAX"; YELLOW_PERCENT="$PERCENT" ;;
        *"Imaging Unit"*) IMAGING_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"; IMAGING_MAX_OID="$OID_SUPPLIES_TABLE.8.1.$IDX"; IMAGING_LEVEL="$LEVEL"; IMAGING_MAX="$MAX"; IMAGING_PERCENT="$PERCENT" ;;
        *"Fuser"*) FUSER_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"; FUSER_MAX_OID="$OID_SUPPLIES_TABLE.8.1.$IDX"; FUSER_LEVEL="$LEVEL"; FUSER_MAX="$MAX"; FUSER_PERCENT="$PERCENT" ;;
        *"Waste"*|*"Residual"*) WASTE_OID="$OID_SUPPLIES_TABLE.9.1.$IDX"; WASTE_MAX_OID="$OID_SUPPLIES_TABLE.8.1.$IDX"; WASTE_LEVEL="$LEVEL"; WASTE_MAX="$MAX"; WASTE_PERCENT="$PERCENT" ;;
    esac
done

print_section "📋 RESUMEN DE CONSUMIBLES SOLICITADOS"

echo ""
echo "┌──────────────────────────┬────────────────────────────────────────────────────────────┬──────────────────────┬─────────────────────────────────────────────────────────────┐"
echo "│ Consumible               │ OID (Nivel)                                    │ OID (Máximo)            │ Nivel / %                                            │"
echo "├──────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────┼─────────────────────────────────────────────────────────────┤"

[ -n "$BLACK_OID" ] && printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Negro" "$BLACK_OID" "$BLACK_MAX_OID" "$BLACK_LEVEL/$BLACK_MAX ($BLACK_PERCENT)" || printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Negro" "No encontrado" "-" "-"
[ -n "$CYAN_OID" ] && printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Cyan" "$CYAN_OID" "$CYAN_MAX_OID" "$CYAN_LEVEL/$CYAN_MAX ($CYAN_PERCENT)" || printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Cyan" "No encontrado" "-" "-"
[ -n "$MAGENTA_OID" ] && printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Magenta" "$MAGENTA_OID" "$MAGENTA_MAX_OID" "$MAGENTA_LEVEL/$MAGENTA_MAX ($MAGENTA_PERCENT)" || printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Magenta" "No encontrado" "-" "-"
[ -n "$YELLOW_OID" ] && printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Amarillo" "$YELLOW_OID" "$YELLOW_MAX_OID" "$YELLOW_LEVEL/$YELLOW_MAX ($YELLOW_PERCENT)" || printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Tóner Amarillo" "No encontrado" "-" "-"
[ -n "$IMAGING_OID" ] && printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Unidad de Imagen" "$IMAGING_OID" "$IMAGING_MAX_OID" "$IMAGING_LEVEL/$IMAGING_MAX ($IMAGING_PERCENT)" || printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Unidad de Imagen" "No encontrado" "-" "-"
[ -n "$FUSER_OID" ] && printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Fusor" "$FUSER_OID" "$FUSER_MAX_OID" "$FUSER_LEVEL/$FUSER_MAX ($FUSER_PERCENT)" || printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Fusor" "No encontrado" "-" "-"
[ -n "$WASTE_OID" ] && printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Depósito Residual" "$WASTE_OID" "$WASTE_MAX_OID" "$WASTE_LEVEL/$WASTE_MAX ($WASTE_PERCENT)" || printf "│ %-20s │ %-50s │ %-20s │ %-50s │\n" "Depósito Residual" "No encontrado" "-" "-"

echo "└──────────────────────────┴────────────────────────────────────────────────────────────┴──────────────────────┴─────────────────────────────────────────────────────────────┘"

print_section "ℹ️  INFORMACIÓN ADICIONAL"

echo ""
echo "📌 Para calcular el porcentaje manualmente:"
echo "   Porcentaje = (Valor_Actual / Valor_Máximo) × 100"
echo ""
echo "📌 OID base de consumibles (PRINTER-MIB):"
echo "   - Descripción:  $OID_SUPPLIES_TABLE.6.1.x"
echo "   - Nivel:       $OID_SUPPLIES_TABLE.9.1.x  ← Usa este para el valor actual"
echo "   - Máximo:      $OID_SUPPLIES_TABLE.8.1.x  ← Usa este para la capacidad máxima"
echo ""
echo "📌 Valores especiales de nivel:"
echo "   -1 = Otro (no hay restricciones)"
echo "   -2 = Desconocido"
echo "   -3 = No soporta porcentaje (ej: depósito residual)"

echo ""
echo "============================================================================="
echo "  ✅ Escaneo completado para $IP_PRINTER"
echo "============================================================================="
echo ""