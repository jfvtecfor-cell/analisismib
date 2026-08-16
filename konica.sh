#!/bin/bash

# ==============================================================================
# Script para obtener OIDs, niveles de consumibles y contadores (Total, B/N, Color)
# Uso: ./check_bizhub_all.sh <IP_IMPRESORA> [COMUNIDAD_SNMP]
# ==============================================================================

IP="${1}"
COMMUNITY="${2:-public}"

if [ -z "$IP" ]; then
    echo "Error: Debes indicar la dirección IP."
    echo "Uso: $0 <IP_IMPRESORA> [COMUNIDAD]"
    exit 1
fi

if ! command -v snmpwalk &> /dev/null; then
    echo "Error: 'snmpwalk' no está instalado."
    exit 1
fi

echo "=========================================================================="
echo " Consultando Impresora: $IP (Comunidad: $COMMUNITY)"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# 1. CONTADORES DE PÁGINAS (Blanco/Negro, Color y Total)
# ------------------------------------------------------------------------------
echo -e "\n[+] CONTADORES DE PÁGINAS"
echo "--------------------------------------------------------------------------"

# OIDs típicos de Konica Minolta bizhub
OID_TOTAL_STD="1.3.6.1.2.1.43.10.2.1.4.1.1"          # Estándar Printer-MIB Total
OID_TOTAL_KM="1.3.6.1.4.1.18334.1.1.1.5.7.2.1.1.0"   # KM Total
OID_BN_KM="1.3.6.1.4.1.18334.1.1.1.5.7.2.1.3.0"      # KM Blanco y Negro
OID_COLOR_KM="1.3.6.1.4.1.18334.1.1.1.5.7.2.1.4.0"   # KM Color

# Alternativas de OIDs KM para ciertas series bizhub (C224, C258, C300i, etc.)
OID_BN_ALT="1.3.6.1.4.1.18334.1.1.1.5.7.2.2.1.5.2.1"
OID_COLOR_ALT="1.3.6.1.4.1.18334.1.1.1.5.7.2.2.1.5.3.1"

obtener_valor() {
    local oid="$1"
    local val=$(snmpget -v 2c -c "$COMMUNITY" -O qv "$IP" "$oid" 2>/dev/null | tr -d '" ')
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
    else
        echo ""
    fi
}

CNT_TOTAL=$(obtener_valor "$OID_TOTAL_STD")
[ -z "$CNT_TOTAL" ] && CNT_TOTAL=$(obtener_valor "$OID_TOTAL_KM")

CNT_BN=$(obtener_valor "$OID_BN_KM")
[ -z "$CNT_BN" ] && CNT_BN=$(obtener_valor "$OID_BN_ALT")

CNT_COLOR=$(obtener_valor "$OID_COLOR_KM")
[ -z "$CNT_COLOR" ] && CNT_COLOR=$(obtener_valor "$OID_COLOR_ALT")

echo "Contador Total      : ${CNT_TOTAL:-"No detectado"} (OID: $OID_TOTAL_STD)"
echo "Contador B/N        : ${CNT_BN:-"No detectado"} (OID: ${OID_BN_KM})"
echo "Contador Color      : ${CNT_COLOR:-"No detectado"} (OID: ${OID_COLOR_KM})"

# ------------------------------------------------------------------------------
# 2. CONSUMIBLES Y DEPÓSITO DE RESIDUOS
# ------------------------------------------------------------------------------
echo -e "\n[+] NIVELES DE CONSUMIBLES"
echo "--------------------------------------------------------------------------"

OID_DESC_BASE="1.3.6.1.2.1.43.11.1.1.6.1"
OID_LEVEL_BASE="1.3.6.1.2.1.43.11.1.1.9.1"
OID_MAX_BASE="1.3.6.1.2.1.43.11.1.1.8.1"

WALK_OUTPUT=$(snmpwalk -v 2c -c "$COMMUNITY" -O qn "$IP" "$OID_DESC_BASE" 2>/dev/null)

if [ -z "$WALK_OUTPUT" ]; then
    echo "Error: No se obtuvo respuesta para los consumibles."
    exit 1
fi

echo "$WALK_OUTPUT" | while read -r line; do
    full_oid=$(echo "$line" | awk '{print $1}')
    index="${full_oid##*.}"
    desc=$(echo "$line" | cut -d'"' -f2)

    if echo "$desc" | grep -iqE "black|cyan|magenta|yellow|waste|residuos|negro|amarillo"; then
        
        oid_level="${OID_LEVEL_BASE}.${index}"
        oid_max="${OID_MAX_BASE}.${index}"

        val_level=$(snmpget -v 2c -c "$COMMUNITY" -O qv "$IP" "$oid_level" 2>/dev/null | tr -d '" ')
        val_max=$(snmpget -v 2c -c "$COMMUNITY" -O qv "$IP" "$oid_max" 2>/dev/null | tr -d '" ')

        porcentaje="N/A"
        if [[ "$val_level" =~ ^-?[0-9]+$ ]] && [[ "$val_max" =~ ^[0-9]+$ ]] && [ "$val_max" -gt 0 ]; then
            if [ "$val_level" -ge 0 ]; then
                porcentaje="$(( (val_level * 100) / val_max ))%"
            elif [ "$val_level" -eq -3 ]; then
                porcentaje="OK (Suficiente)"
            fi
        fi

        echo "Consumible: $desc"
        echo "  ├─ OID Nivel Actual : $oid_level"
        echo "  ├─ OID Nivel Máximo : $oid_max"
        echo "  └─ Nivel / Estado   : $porcentaje (Lectura: $val_level/$val_max)"
        echo "--------------------------------------------------------------------------"
    fi
done
