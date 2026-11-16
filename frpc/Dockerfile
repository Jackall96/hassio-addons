# FRP Tunnel (frpc) - add-on de Home Assistant
#
# Reglas 2026 aplicadas:
# - Desde Supervisor 2026.04.0 BUILD_FROM ya NO se pasa por defecto al
#   construir, por lo que el ARG lleva un default (imagen base oficial
#   multi-arch, pineada). Para sobreescribirla:
#   docker build --build-arg BUILD_FROM=ghcr.io/home-assistant/base-debian:trixie .
# - El Supervisor/builder si pasan BUILD_ARCH ('amd64' | 'aarch64') y
#   BUILD_VERSION. No hace falta build.json/build.yaml (deprecated).
# - Sin clave 'image' en config.yaml => el Supervisor construye esta imagen
#   localmente en el dispositivo al instalar el add-on.

ARG BUILD_FROM=ghcr.io/home-assistant/base:3.23
FROM ${BUILD_FROM}

# Version estable de frp (nov-2026): https://github.com/fatedier/frp/releases
ARG FRP_VERSION=0.72.0
ARG FRP_BASE_URL=https://github.com/fatedier/frp/releases/download

# Arquitectura pasada por el Supervisor: 'amd64' o 'aarch64'
# (los assets de frp usan amd64 / arm64; el mapeo se hace en el RUN).
ARG BUILD_ARCH=amd64
ARG BUILD_VERSION

# jq ya viene en la imagen base; reinstalacion explicita por si se cambia BUILD_FROM.
# iproute2 es necesario: el applet 'ip' de busybox no soporta '-4 -o' y el
# autodiagnostico de IPs LAN lo necesita de verdad.
RUN apk add --no-cache jq iproute2

# Descarga frpc pineado + verificacion sha256 contra los checksums oficiales
# del release (frp_sha256_checksums.txt). Mapea BUILD_ARCH -> asset de frp:
#   amd64   -> frp_<v>_linux_amd64.tar.gz
#   aarch64 -> frp_<v>_linux_arm64.tar.gz
RUN set -eux; \
    case "${BUILD_ARCH}" in \
        amd64) frp_arch="amd64" ;; \
        aarch64) frp_arch="arm64" ;; \
        *) echo "Arquitectura no soportada por este add-on: ${BUILD_ARCH}" >&2; exit 1 ;; \
    esac; \
    tarball="frp_${FRP_VERSION}_linux_${frp_arch}.tar.gz"; \
    curl -fsSL -o "/tmp/${tarball}" "${FRP_BASE_URL}/v${FRP_VERSION}/${tarball}"; \
    curl -fsSL -o /tmp/frp_sha256_checksums.txt "${FRP_BASE_URL}/v${FRP_VERSION}/frp_sha256_checksums.txt"; \
    grep " ${tarball}\$" /tmp/frp_sha256_checksums.txt > /tmp/frp_checksum.txt; \
    cd /tmp; \
    sha256sum -c frp_checksum.txt; \
    tar -xzf "${tarball}"; \
    install -m 0755 "frp_${FRP_VERSION}_linux_${frp_arch}/frpc" /usr/local/bin/frpc; \
    /usr/local/bin/frpc -v; \
    rm -rf /tmp/frp_*

LABEL org.opencontainers.image.title="FRP Tunnel (frpc) para Home Assistant" \
      org.opencontainers.image.description="Cliente frp que expone Home Assistant mediante un tunel TCP contra un servidor frps" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.url="https://github.com/fatedier/frp"

COPY run.sh /run.sh
# Normaliza posibles finales de linea CRLF (por si el repo se edita en Windows)
RUN sed -i 's/\r$//' /run.sh && chmod 0755 /run.sh

CMD [ "/run.sh" ]
