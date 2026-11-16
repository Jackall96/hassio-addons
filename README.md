# Jackall Add-ons

Repositorio personal de apps (add-ons) de Home Assistant. Contiene:

- **FRP Tunnel** (`frp_tunnel`) — cliente [frp](https://github.com/fatedier/frp) (`frpc` **v0.72.0**, estable de nov-2026) para exponer Home Assistant (o cualquier puerto local) mediante un túnel TCP contra tu propio servidor `frps`. Sin `privileged`, sin `devices` y sin image precompilada: el Supervisor construye la imagen localmente en tu dispositivo al instalar.

## Instalación

Requisitos: Home Assistant **OS** o **Supervised** (las apps no se pueden instalar en HA Container) y usuario administrador. No hace falta cuenta de GitHub (no confundir con el Marketplace, el antiguo HACS, que no instala apps).

1. **Ajustes → Apps → Instalar app** (en inglés: *Settings → Apps → Install app*).
2. Menú **⋮** (esquina superior derecha) → **Repositorios** (*Repositories*) → **Añadir** (*Add*).
3. Pega la URL de este repositorio Git y pulsa **Añadir**.
   - También puedes generar un enlace de un clic: `https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=<URL-del-repo>`
   - Se puede sufijar una rama como canal: `<URL>#rama-beta`.
4. Busca **FRP Tunnel** en la tienda (los repos nuevos aparecen al final) → **Instalar**.
5. Pestaña **Configuración**: rellena al menos `serverip` → **Guardar** → **Iniciar**.

Si algo falla: en **Ajustes → Sistema → Registros** cambia la fuente de *Home Assistant Core* a **Supervisor**. Un error "no es un repositorio de apps válido" suele ser un `repository.json` ausente o un `config.yaml` inválido.

## Opciones de FRP Tunnel

| Opción | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `serverip` | `str` (obligatoria) | `""` | IP o host del servidor frps. Debe coincidir con su `bindAddr`. IPv6 sin corchetes. |
| `serverport` | `port` | `7000` | `bindPort` del servidor frps. |
| `token` | `str?` (opcional) | `""` | `auth.token` compartido con frps. Vacío solo si el servidor no usa token. |
| `localip` | `str` | `127.0.0.1` | Dirección local que se expone. Con `host_network` el add-on comparte red con HA Core, así que `127.0.0.1` llega directamente a Home Assistant. |
| `localport` | `int` | `8123` | Puerto local a exponer. **Ojo:** desde HA 2026.8 las instalaciones nuevas de HAOS escuchan por defecto en el **80**. |
| `remoteport` | `int` | `8123` | Puerto público en el frps. `0` = frps asigna uno aleatorio. |
| `encryption` | `bool` | `true` | `transport.useEncryption` del proxy. |
| `compression` | `bool` | `true` | `transport.useCompression` del proxy. |

Ejemplo de `frps.toml` mínimo en el servidor:

```toml
bindAddr = "0.0.0.0"
bindPort = 7000
auth.token = "tu-token-secreto"   # mismo valor que la opción token
```

## Autodiagnóstico al arrancar

Antes de lanzar `frpc`, el add-on loguea un informe de qué puertos responden en `127.0.0.1`, `::1` y la IP LAN del host (prueba `localport`, `80`, `8123` y `443`), y si el frps es alcanzable:

```
DIAG: 127.0.0.1:80 ABIERTO
DIAG: 127.0.0.1:8123 CERRADO (connection refused: nada escucha en ese puerto/direccion)
DIAG: 192.168.178.61:8123 CERRADO (connection refused: nada escucha en ese puerto/direccion)
DIAG: frps 203.0.113.10:7000 ABIERTO
```

Cómo leerlo:

- **ABIERTO** — algo escucha ahí.
- **CERRADO (connection refused)** — RST: el tráfico llega, pero nada escucha en ese puerto/dirección.
- **CERRADO (sin respuesta)** — filtrado (drop) o host caído.

Si `8123` sale *refused* y `80` abierto, tu instalación es nueva (HA ≥ 2026.8): pon `localport: 80`. Si todo está *refused*, revisa **Ajustes → Sistema → Red → Servidor HTTP**: el puerto real y las *Listen addresses* **vacías** (el uso de `server_host` está deprecated y se rompe en 2026.6), y los logs de Core buscando `Now listening on port N`.

## Desarrollo

- Versión de frp pineada en el Dockerfile (`ARG FRP_VERSION=0.72.0`), descargada del release oficial y verificada con `frp_sha256_checksums.txt` durante el build.
- `BUILD_FROM` lleva default propio desde Supervisor 2026.04; el Supervisor pasa `BUILD_ARCH` (`amd64`→asset `amd64`, `aarch64`→asset `arm64`) y `BUILD_VERSION`.
- Tras cambiar `run.sh` o el `Dockerfile`: página de la app → **Rebuild**, o por CLI `ha apps rebuild --force local_frp_tunnel`.
