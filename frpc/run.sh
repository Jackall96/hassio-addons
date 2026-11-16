#!/usr/bin/env bash
# ============================================================================
# FRP Tunnel (frpc) - add-on de Home Assistant
#
#   (a) Lee las opciones validadas de /data/options.json (el Supervisor las
#       escribe antes de cada arranque) usando jq. Sin bashio: solo bash + jq.
#   (b) AUTODIAGNOSTICO: prueba con TCP puro (/dev/tcp, sin dependencias) que
#       puertos responden en 127.0.0.1, ::1 y en la(s) IP(s) LAN del host.
#       El add-on corre con host_network, por lo que ve exactamente la misma
#       pila de red del host HAOS que usa Home Assistant Core.
#   (c) Genera /data/frpc.toml con la sintaxis TOML moderna de frp (>= 0.52).
#   (d) exec frpc para que reciba SIGTERM y cierre limpio.
#
# El token solo se loguea parcialmente (primeros 6 caracteres).
# ============================================================================
set -eu
trap 'exit 0' INT TERM

OPTIONS_FILE="/data/options.json"
FRPC_BIN="${FRPC_BIN:-/usr/local/bin/frpc}"
FRPC_CONFIG="/data/frpc.toml"

log()  { echo "[frpc] $*"; }
warn() { echo "[frpc] [AVISO] $*"; }
die()  { echo "[frpc] [ERROR] $*" >&2; exit 1; }

# --- helpers ----------------------------------------------------------------

# Escapa un string para insertarlo entre comillas dobles en TOML.
toml_str() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Prueba TCP via /dev/tcp. Retorna:
#   0   = ABIERTO (algo acepta la conexion)
#   124 = sin respuesta en el timeout (filtrado tipo drop o host caido)
#   otro = RECHAZADO (RST / connection refused: NADA escucha ahi)
tcp_probe() {
    local host="$1" port="$2" secs="${3:-3}" rc=0
    timeout "$secs" bash -c 'exec 3<>/dev/tcp/$1/$2' _ "$host" "$port" >/dev/null 2>&1 || rc=$?
    return "$rc"
}

describe_rc() {
    case "$1" in
        0)   echo "ABIERTO" ;;
        124) echo "CERRADO (sin respuesta: posiblemente filtrado o host caido)" ;;
        *)   echo "CERRADO (connection refused o sin ruta: nada escucha ahi)" ;;
    esac
}

is_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -le 65535 ]
}

# Igual que is_port pero rechaza 0 y ceros a la izquierda ('0700' no es TOML valido)
is_port_nonzero() {
    case "$1" in ''|0|0[0-9]*) return 1 ;; esac
    is_port "$1"
}

# Lee una opcion booleana respetando el false real (jq '//' se come los false)
bool_opt() {
    jq -r --arg k "$1" --argjson def "$2" '
        .[$k] as $v |
        if $v == null then $def
        elif ($v|type) == "boolean" then $v
        else ($v|tostring|ascii_downcase|IN("true","1","yes","on"))
        end | if . then "true" else "false" end' "$OPTIONS_FILE"
}

# Rechaza caracteres de control (newline/CR/tab/ANSI): romperian el TOML y
# permitirian falsificar lineas de log
safe_print() {
    case "$1" in
        *[![:print:]]*) die "La opcion '${2}' contiene caracteres de control (newline/CR/tab) y no es valida" ;;
    esac
}

# IP o hostname (IPv6 sin corchetes)
is_host() { printf '%s' "$1" | grep -Eq '^([A-Za-z0-9_-]+\.)*[A-Za-z0-9_-]+$|^[0-9A-Fa-f:.]+$'; }

# --- (a) leer opciones --------------------------------------------------------

[ -f "$OPTIONS_FILE" ] || die "No existe $OPTIONS_FILE (reinstala el add-on)"
command -v jq >/dev/null 2>&1 || die "jq no esta disponible"
[ -x "$FRPC_BIN" ] || die "No se encuentra el binario frpc en $FRPC_BIN"

SERVER_IP=$(jq -r '.serverip // ""' "$OPTIONS_FILE")
SERVER_PORT=$(jq -r '.serverport // 7000' "$OPTIONS_FILE")
TOKEN=$(jq -r '.token // ""' "$OPTIONS_FILE")
LOCAL_IP=$(jq -r '.localip // "127.0.0.1"' "$OPTIONS_FILE")
LOCAL_PORT=$(jq -r '.localport // 8123' "$OPTIONS_FILE")
REMOTE_PORT=$(jq -r '.remoteport // 8123' "$OPTIONS_FILE")
ENCRYPTION=$(bool_opt encryption true)
COMPRESSION=$(bool_opt compression true)

# localip vacia => loopback (jq '//' solo sustituye null/false, no cadenas vacias)
[ -n "$LOCAL_IP" ] || LOCAL_IP="127.0.0.1"

[ -n "$SERVER_IP" ] || die "La opcion 'serverip' esta vacia: configura la IP/host de tu servidor frps y guarda la configuracion."
safe_print "$SERVER_IP" serverip
safe_print "$TOKEN"    token
safe_print "$LOCAL_IP" localip
is_host "$SERVER_IP" || die "serverip invalida: '$SERVER_IP' (usa IP o hostname; IPv6 sin corchetes)"
is_host "$LOCAL_IP"  || die "localip invalida: '$LOCAL_IP'"
is_port_nonzero "$SERVER_PORT" || die "serverport invalido: '$SERVER_PORT'"
is_port_nonzero "$LOCAL_PORT"  || die "localport invalido: '$LOCAL_PORT'"
is_port "$REMOTE_PORT" || die "remoteport invalido: '$REMOTE_PORT' (0 = frps asigna uno aleatorio)"

log "Configuracion: frps=${SERVER_IP}:${SERVER_PORT} | tunel ${LOCAL_IP}:${LOCAL_PORT} -> frps:${REMOTE_PORT} | encripcion=${ENCRYPTION} compresion=${COMPRESSION}"
if [ -n "$TOKEN" ]; then
    log "Token: configurado (${#TOKEN} caracteres)"
else
    warn "Sin token configurado: tu servidor frps debe estar sin auth.token para que el tunel funcione."
fi

# --- (b) autodiagnostico de puertos -------------------------------------------

log "----------------------------------------------------------------------"
log "AUTODIAGNOSTICO de puertos (add-on con host_network: misma red que HA)"
log "----------------------------------------------------------------------"

# Direcciones a probar: loopback IPv4/IPv6 + IPs globales del host
# (se excluyen rangos internos de docker y link-local, que no aportan info)
DIAG_HOSTS="127.0.0.1 ::1"
LAN_IPS=$(
    { ip addr show scope global 2>/dev/null || true; } \
      | awk '/^[[:space:]]*inet /{print $2}' | cut -d/ -f1 \
      | grep -Ev '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
      | grep -E '^[0-9a-fA-F.:]+$' \
      || true
)
if [ -z "$LAN_IPS" ] && command -v hostname >/dev/null 2>&1; then
    LAN_IPS=$(hostname -i 2>/dev/null | tr ' ' '\n' \
        | grep -Ev '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|%|\[)' \
        | grep -E '^[0-9a-fA-F.:]+$' || true)
fi
for ip_ in $LAN_IPS; do
    DIAG_HOSTS="$DIAG_HOSTS $ip_"
done
log "Direcciones a probar: ${DIAG_HOSTS}"

# Puertos a probar: el configurado + candidatos habituales de HA (sin duplicar)
DIAG_PORTS=$(printf '%s\n' "$LOCAL_PORT" 80 8123 443 | awk '!seen[$0]++')

target_open=0
for h_ in $DIAG_HOSTS; do
    for p_ in $DIAG_PORTS; do
        rc_=0
        tcp_probe "$h_" "$p_" 3 || rc_=$?
        target_=""
        if [ "$h_" = "$LOCAL_IP" ] && [ "$p_" = "$LOCAL_PORT" ]; then
            target_="  <== objetivo del tunel"
            if [ "$rc_" -eq 0 ]; then
                target_open=1
            fi
        fi
        echo "DIAG: ${h_}:${p_} $(describe_rc "$rc_")${target_}"
    done
done

# Sonda explicita del OBJETIVO del tunel (funciona aunque localip sea un
# hostname o una IP fuera de la matriz de diagnostico)
rc_=0
tcp_probe "$LOCAL_IP" "$LOCAL_PORT" 3 || rc_=$?
echo "DIAG: OBJETIVO ${LOCAL_IP}:${LOCAL_PORT} $(describe_rc "$rc_")"
if [ "$rc_" -eq 0 ]; then
    target_open=1
fi

# Se alcanza el servidor frps? (distingue fallo de DNS de puerto cerrado)
if ! nslookup "$SERVER_IP" >/dev/null 2>&1; then
    warn "El nombre '${SERVER_IP}' no resuelve (DNS): revisa la opcion serverip."
fi
rc_=0
tcp_probe "$SERVER_IP" "$SERVER_PORT" 5 || rc_=$?
echo "DIAG: frps ${SERVER_IP}:${SERVER_PORT} $(describe_rc "$rc_")"
if [ "$rc_" -ne 0 ]; then
    warn "El servidor frps no responde en ${SERVER_IP}:${SERVER_PORT}: frpc reintentara el login hasta que sea alcanzable (loginFailExit = false)."
fi

# Recomendaciones si el objetivo local sigue cerrado
if [ "$target_open" -ne 1 ]; then
    skip_wait_=0
    rc_=0
    tcp_probe "127.0.0.1" 80 3 || rc_=$?
    if [ "$rc_" -eq 0 ] && [ "$LOCAL_PORT" != "80" ]; then
        warn "127.0.0.1:80 esta ABIERTO pero el tunel apunta a ${LOCAL_IP}:${LOCAL_PORT}."
        warn "Desde HA 2026.8 las instalaciones NUEVAS de HAOS escuchan por defecto en el puerto 80 (8123 solo redirige durante el onboarding). Prueba a poner 'localport: 80'."
        skip_wait_=1
    else
        warn "Nada escucha (todavia) en ${LOCAL_IP}:${LOCAL_PORT}."
        warn "Revisa: Ajustes > Sistema > Red > Servidor HTTP (mira el puerto real y deja 'Listen addresses' VACIO: server_host esta deprecated y se rompe en 2026.6) y los logs de Core buscando 'Now listening on port N'."
    fi
    # startup: services arranca junto a HA Core, que puede tardar unos segundos
    # (si ya se sabe que el objetivo esta mal configurado, no se espera)
    i_=0
    while [ "$i_" -lt 6 ] && [ "$skip_wait_" -ne 1 ]; do
        i_=$((i_ + 1))
        sleep 5
        rc_=0
        tcp_probe "$LOCAL_IP" "$LOCAL_PORT" 3 || rc_=$?
        if [ "$rc_" -eq 0 ]; then
            echo "DIAG: ${LOCAL_IP}:${LOCAL_PORT} ABIERTO tras esperar (intento ${i_}/6)"
            target_open=1
            break
        fi
        echo "DIAG: esperando a que algo escuche en ${LOCAL_IP}:${LOCAL_PORT} (intento ${i_}/6)..."
    done
fi

# --- (c) generar /data/frpc.toml ----------------------------------------------

log "Generando configuracion frpc en ${FRPC_CONFIG}"
umask 077
{
    echo "# Generado automaticamente por el add-on FRP Tunnel. No editar a mano."
    echo "serverAddr = \"$(toml_str "$SERVER_IP")\""
    echo "serverPort = ${SERVER_PORT}"
    # frpc NO debe morir si el frps no esta accesible al arrancar: reintenta
    echo "loginFailExit = false"
    if [ -n "$TOKEN" ]; then
        echo ""
        echo "[auth]"
        echo "method = \"token\""
        echo "token = \"$(toml_str "$TOKEN")\""
    fi
    echo ""
    echo "[log]"
    echo "level = \"info\""
    echo ""
    echo "[[proxies]]"
    echo "name = \"hass\""
    echo "type = \"tcp\""
    echo "localIP = \"$(toml_str "$LOCAL_IP")\""
    echo "localPort = ${LOCAL_PORT}"
    echo "remotePort = ${REMOTE_PORT}"
    echo ""
    echo "[proxies.transport]"
    echo "useEncryption = ${ENCRYPTION}"
    echo "useCompression = ${COMPRESSION}"
} > "$FRPC_CONFIG"
chmod 600 "$FRPC_CONFIG"

# --- (d) arrancar frpc ---------------------------------------------------------

log "Arrancando frpc con ${FRPC_CONFIG}"
exec "$FRPC_BIN" -c "$FRPC_CONFIG"
