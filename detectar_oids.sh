#!/bin/bash
#
# detectar_oids.sh
#
# Detecta automaticamente los OIDs de nivel (prtMarkerSuppliesLevel) de los
# consumibles de una impresora, usando la tabla estandar Printer-MIB
# (RFC 3805), rama 1.3.6.1.2.1.43.11.1.1
#
# Uso:
#   ./detectar_oids.sh <IP> [community]
#
# Ejemplo:
#   ./detectar_oids.sh 192.168.1.50 public
#

IP="$1"
COMMUNITY="${2:-public}"

if [ -z "$IP" ]; then
    echo "Uso: $0 <IP> [community]"
    exit 1
fi

BASE="1.3.6.1.2.1.43.11.1.1"
DESC_OID="${BASE}.6"   # prtMarkerSuppliesDescription
TYPE_OID="${BASE}.5"   # prtMarkerSuppliesType
LEVEL_BASE="${BASE}.9" # prtMarkerSuppliesLevel

echo "======================================================"
echo " Detectando consumibles en $IP ..."
echo "======================================================"

# Volcamos descripcion y tipo en una sola pasada cada uno
DESC_RAW=$(snmpwalk -v1 -c "$COMMUNITY" -Oqn "$IP" "$DESC_OID" 2>/dev/null)
TYPE_RAW=$(snmpwalk -v1 -c "$COMMUNITY" -Oqn "$IP" "$TYPE_OID" 2>/dev/null)

if [ -z "$DESC_RAW" ]; then
    echo "ERROR: no se ha podido consultar la impresora (revisa IP/community/conectividad)."
    exit 1
fi

# Funcion: busca por texto (case-insensitive) en la descripcion y
# devuelve el OID completo de nivel (columna 9) para ese indice
buscar_por_texto() {
    local patron="$1"
    local linea
    linea=$(echo "$DESC_RAW" | grep -i "$patron" | head -n1)
    if [ -z "$linea" ]; then
        echo ""
        return
    fi
    # linea tipo: 1.3.6.1.2.1.43.11.1.1.6.1.3 "Black Toner"
    local oid_completo indice
    oid_completo=$(echo "$linea" | awk '{print $1}')
    indice="${oid_completo##*.}"
    echo "${LEVEL_BASE}.1.${indice}"
}

# Funcion: busca por codigo de TIPO (columna 5) y devuelve el OID de nivel
buscar_por_tipo() {
    local codigo="$1"
    local linea
    linea=$(echo "$TYPE_RAW" | grep -E ": ${codigo}$| ${codigo}$" | head -n1)
    if [ -z "$linea" ]; then
        echo ""
        return
    fi
    local oid_completo indice
    oid_completo=$(echo "$linea" | awk '{print $1}')
    indice="${oid_completo##*.}"
    echo "${LEVEL_BASE}.1.${indice}"
}

echo ""
echo "--- Descripciones encontradas en la impresora ---"
echo "$DESC_RAW"
echo ""
echo "--- Tipos encontrados (codigo PrtMarkerSuppliesTypeTC) ---"
echo "$TYPE_RAW"
echo ""
echo "======================================================"
echo " OIDs detectados (nivel = prtMarkerSuppliesLevel)"
echo "======================================================"

# Toner por color: primero intenta por texto, si no encuentra, deja vacio
TONER_NEGRO=$(buscar_por_texto "black.*ton\|ton.*black\|negro")
TONER_CYAN=$(buscar_por_texto "cyan")
TONER_MAGENTA=$(buscar_por_texto "magenta")
TONER_YELLOW=$(buscar_por_texto "yellow\|amarillo")

# Tambores (drum / opc) - tipo 9 = opc(9)
DRUM_NEGRO=$(buscar_por_texto "black.*drum\|drum.*black\|black.*opc\|opc.*black")
DRUM_CYAN=$(buscar_por_texto "cyan.*drum\|drum.*cyan\|cyan.*opc")
DRUM_MAGENTA=$(buscar_por_texto "magenta.*drum\|drum.*magenta\|magenta.*opc")
DRUM_YELLOW=$(buscar_por_texto "yellow.*drum\|drum.*yellow\|yellow.*opc")
# Si no hay texto que distinga color en el tambor, probamos por tipo generico (unico tambor combinado)
DRUM_GENERICO=$(buscar_por_tipo "9")

# Banda de transferencia - tipo 20 = tranferUnit(20)
TRANSFER_BAND=$(buscar_por_texto "transfer.*belt\|transfer.*unit\|banda.*transfer")
[ -z "$TRANSFER_BAND" ] && TRANSFER_BAND=$(buscar_por_tipo "20")

# Fusor - tipo 15 = fuser(15)
FUSER=$(buscar_por_texto "fuser\|fusor")
[ -z "$FUSER" ] && FUSER=$(buscar_por_tipo "15")

# Deposito de residuos - tipo 4 = wasteToner(4)
DEPOSITO_RESIDUAL=$(buscar_por_texto "waste.*ton\|residual\|waste.*box\|waste.*bottle")
[ -z "$DEPOSITO_RESIDUAL" ] && DEPOSITO_RESIDUAL=$(buscar_por_tipo "4")

mostrar() {
    local nombre="$1"
    local valor="$2"
    if [ -n "$valor" ]; then
        printf "%-22s %s\n" "$nombre" "$valor"
    else
        printf "%-22s %s\n" "$nombre" "NO DETECTADO"
    fi
}

mostrar "TONER_OID_NEGRO"      "$TONER_NEGRO"
mostrar "TONER_OID_CYAN"       "$TONER_CYAN"
mostrar "TONER_OID_MAGENTA"    "$TONER_MAGENTA"
mostrar "TONER_OID_YELLOW"     "$TONER_YELLOW"
mostrar "DRUM_OID_NEGRO"       "$DRUM_NEGRO"
mostrar "DRUM_OID_CYAN"        "$DRUM_CYAN"
mostrar "DRUM_OID_MAGENTA"     "$DRUM_MAGENTA"
mostrar "DRUM_OID_YELLOW"      "$DRUM_YELLOW"
mostrar "DRUM_OID_GENERICO"    "$DRUM_GENERICO"
mostrar "TRANSFER_BAND_OID"    "$TRANSFER_BAND"
mostrar "FUSER_OID"            "$FUSER"
mostrar "DEPOSITO_RESIDUAL_OID" "$DEPOSITO_RESIDUAL"

echo ""
echo "======================================================"
echo " Listo para copiar/pegar en tu script principal:"
echo "======================================================"
echo "TONER_OID_NEGRO=\"$TONER_NEGRO\""
echo "TONER_OID_CYAN=\"$TONER_CYAN\""
echo "TONER_OID_MAGENTA=\"$TONER_MAGENTA\""
echo "TONER_OID_YELLOW=\"$TONER_YELLOW\""
echo "DRUM_OID_NEGRO=\"$DRUM_NEGRO\""
echo "DRUM_OID_CYAN=\"$DRUM_CYAN\""
echo "DRUM_OID_MAGENTA=\"$DRUM_MAGENTA\""
echo "DRUM_OID_YELLOW=\"$DRUM_YELLOW\""
echo "TRANSFER_BAND_OID=\"$TRANSFER_BAND\""
echo "FUSER_OID=\"$FUSER\""
echo "DEPOSITO_RESIDUAL_OID=\"$DEPOSITO_RESIDUAL\""
echo ""
echo "Nota: si DRUM_OID_NEGRO/CYAN/MAGENTA/YELLOW salieron vacios pero"
echo "DRUM_OID_GENERICO si tiene valor, tu impresora probablemente usa"
echo "un unico tambor combinado (comun en monocromo o en algunos modelos"
echo "de bajo coste). En ese caso usa DRUM_OID_GENERICO como tambor unico."
echo ""
echo "Revisa siempre la lista de 'Descripciones encontradas' de arriba"
echo "para confirmar visualmente que el texto coincide con lo esperado,"
echo "ya que la deteccion automatica depende del idioma/texto que use"
echo "el fabricante en el firmware."
