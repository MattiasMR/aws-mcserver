#!/bin/bash
# =====================================================================
#  Setup de servidor Minecraft (Forge) en Amazon Linux 2023 (ARM)
#  - Instalación de Java (8/17/21)
#  - Desempaqueta Server Pack (zip)
#  - Autodetecta/instala Forge (o forzado/omitido)
#  - Crea servicio systemd
#  - RAM configurable (flags o variables)
# =====================================================================
set -euo pipefail

# --------------------- Defaults (editables o por flags) ---------------
JAVA_VERSION="${JAVA_VERSION:-8}"          # 8 | 17 | 21
SERVER_PORT="${SERVER_PORT:-25565}"        # abre en SG
MC_USER="${MC_USER:-minecraft}"
MC_HOME="${MC_HOME:-/opt/minecraft}"
MC_DIR="$MC_HOME/server"
SERVICE_NAME="${SERVICE_NAME:-minecraft}"

# Memoria (puedes sobreescribir por env o flags)
XMS="${XMS:-4G}"
XMX="${XMX:-4G}"

# Dónde obtener el Server Pack:
# - por URL directa (CDN de CurseForge/Modrinth) o
# - desde un archivo ya subido a /tmp/serverpack.zip
MODPACK_URL="${MODPACK_URL:-}"             # --url
MODPACK_LOCAL="${MODPACK_LOCAL:-/tmp/serverpack.zip}" # --local

# Forge: "auto" (recomendado), "none" (omitir), o "MC-FORGE" ej: 1.12.2-14.23.5.2860
FORGE_MODE="${FORGE_MODE:-auto}"           # --forge auto|none|<ver>

# --------------------------- Ayuda/flags -------------------------------
usage() {
  cat <<EOF
Uso:
  sudo ./setup.sh [opciones]

Opciones:
  -j, --java <8|17|21>       Versión de Java (default: $JAVA_VERSION)
  -u, --url  <URL>           URL directa del serverpack.zip (CDN)
  -l, --local <PATH>         Ruta local del serverpack.zip (default: $MODPACK_LOCAL)
  -f, --forge <auto|none|VER>Autodetecta/omite/instala Forge VER (p.ej. 1.20.1-47.2.0)
  -s, --xms <RAM>            Xms (default: $XMS)  ej: 6G
  -x, --xmx <RAM>            Xmx (default: $XMX)
  -p, --port <PORT>          Puerto (default: $SERVER_PORT)
  -n, --name <SERVICE>       Nombre servicio systemd (default: $SERVICE_NAME)
  -d, --dir  <DIR>           Carpeta server (default: $MC_DIR)
  -h, --help                 Mostrar ayuda

También puedes usar variables de entorno: JAVA_VERSION, MODPACK_URL, MODPACK_LOCAL,
FORGE_MODE, XMS, XMX, SERVER_PORT, SERVICE_NAME, MC_HOME, MC_USER.
Ejemplo:
  XMS=6G XMX=6G sudo ./setup.sh \\
    --java 8 --url "https://mediafilez.forgecdn.net/.../serverpack.zip"
EOF
  exit 0
}

# Parseo simple de flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--java) JAVA_VERSION="$2"; shift 2;;
    -u|--url) MODPACK_URL="$2"; shift 2;;
    -l|--local) MODPACK_LOCAL="$2"; shift 2;;
    -f|--forge) FORGE_MODE="$2"; shift 2;;
    -s|--xms) XMS="$2"; shift 2;;
    -x|--xmx) XMX="$2"; shift 2;;
    -p|--port) SERVER_PORT="$2"; shift 2;;
    -n|--name) SERVICE_NAME="$2"; shift 2;;
    -d|--dir) MC_DIR="$2"; MC_HOME="$(dirname "$MC_DIR")"; shift 2;;
    -h|--help) usage;;
    *) echo "Opción desconocida: $1" >&2; usage;;
  esac
done

log()  { echo -e "\e[1;32m[*]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err()  { echo -e "\e[1;31m[✗]\e[0m $*" >&2; }

# -------------------- Mapear paquete de Java --------------------------
case "$JAVA_VERSION" in
  8)  JAVA_PKG="java-1.8.0-amazon-corretto" ;;
  17) JAVA_PKG="java-17-amazon-corretto" ;;
  21) JAVA_PKG="java-21-amazon-corretto" ;;
  *)  err "JAVA_VERSION inválida: $JAVA_VERSION (usa 8, 17 o 21)"; exit 1 ;;
esac

# -------------------- Paquetes base (sin curl) ------------------------
log "Instalando paquetes base y Java $JAVA_VERSION..."
sudo dnf -y install unzip wget dos2unix jq "$JAVA_PKG" >/dev/null

# -------------------- Usuario/carpeta del servidor --------------------
log "Creando usuario y carpetas..."
sudo useradd -r -m -d "$MC_HOME" "$MC_USER" 2>/dev/null || true
sudo mkdir -p "$MC_DIR"
sudo chown -R "$MC_USER:$MC_USER" "$MC_HOME"

# -------------------- Descargar/usar el Server Pack -------------------
TMP_ZIP="/tmp/serverpack.zip"
if [[ -n "${MODPACK_URL:-}" ]]; then
  log "Descargando Server Pack desde URL (recuerda: URL *directa* del CDN)..."
  if ! wget -q --content-disposition --trust-server-names -O "$TMP_ZIP" "$MODPACK_URL"; then
    warn "No pude descargar (¿403?). Intento con archivo local: $MODPACK_LOCAL"
  fi
fi

if [[ ! -f "$TMP_ZIP" && -f "$MODPACK_LOCAL" ]]; then
  log "Usando ZIP local: $MODPACK_LOCAL"
  sudo cp -f "$MODPACK_LOCAL" "$TMP_ZIP"
fi

if [[ ! -f "$TMP_ZIP" ]]; then
  err "No tengo el ZIP del Server Pack. Pasa --url o sube a $TMP_ZIP."
  exit 1
fi

# -------------------- Descomprimir y aplanar --------------------------
log "Descomprimiendo Server Pack en $MC_DIR..."
sudo -u "$MC_USER" bash -lc "
  set -e
  cd '$MC_DIR'
  unzip -o '$TMP_ZIP' >/dev/null

  # Aplanar si hay una sola carpeta raíz
  dirs=( \$(find . -mindepth 1 -maxdepth 1 -type d) )
  if (( \${#dirs[@]} == 1 )) && [[ ! -e mods && ! -e config && ! -e scripts ]]; then
    top=\"\${dirs[0]}\"
    shopt -s dotglob nullglob
    mv \"\$top\"/* .
    shopt -u dotglob nullglob
    rmdir \"\$top\" || true
  fi
"

# -------------------- Funciones de instalación Forge ------------------
forge_installer_url() {
  local ver="$1"
  echo "https://maven.minecraftforge.net/net/minecraftforge/forge/$ver/forge-$ver-installer.jar"
}

install_forge_from_installer() {
  local installer="$1"
  log "Instalando Forge con $installer (modo servidor, headless)..."
  sudo -u "$MC_USER" bash -lc "
    set -e
    cd '$MC_DIR'
    # Para 1.12.2 agregar vanilla jar si falta (Forge lo usa)
    if [[ '$installer' == *'1.12.2'* && ! -f minecraft_server.1.12.2.jar ]]; then
      wget -q -O minecraft_server.1.12.2.jar \
        https://launcher.mojang.com/v1/objects/886945bfb2b978778c3a0288fd7fab09d315b25f/server.jar || true
    fi
    java -jar '$installer' --installServer --debug >/dev/null
  "
}

autodetect_or_install_forge() {
  # 0) ¿Ya hay jar ejecutable de Forge?
  if sudo -u "$MC_USER" bash -lc "cd '$MC_DIR' && ls -1 forge-*.jar 2>/dev/null | grep -vq installer"; then
    log "Forge ya presente (jar ejecutable)."
    return 0
  fi

  # 1) ¿Hay un installer dentro del pack?
  local found_inst
  found_inst="$(sudo -u "$MC_USER" bash -lc "cd '$MC_DIR' && ls -1 forge-*-installer.jar 2>/dev/null | head -n1 || true")"
  if [[ -n "${found_inst:-}" ]]; then
    install_forge_from_installer "$found_inst"
    return 0
  fi

  # 2) Intentar deducir desde manifest.json (si existe)
  local manifest
  manifest="$(sudo -u "$MC_USER" bash -lc "cd '$MC_DIR' && find . -maxdepth 2 -name manifest.json | head -n1 || true")"
  if [[ -n "${manifest:-}" ]]; then
    # Usar jq si está disponible, si no, regex con grep/sed
    local mc forgeid forgever fullver
    if command -v jq >/dev/null 2>&1; then
      mc="$(jq -r '.minecraft.version // empty' "$manifest")"
      forgeid="$(jq -r '.minecraft.modLoaders[]?.id // empty' "$manifest" | grep -E '^forge-' | head -n1 || true)"
    else
      mc="$(grep -oE '"version"\s*:\s*"[^"]+"' "$manifest" | head -n1 | sed -E 's/.*"version"\s*:\s*"([^"]+)".*/\1/')"
      forgeid="$(grep -oE '"id"\s*:\s*"forge-[^"]+"' "$manifest" | head -n1 | sed -E 's/.*"id"\s*:\s*"forge-([^"]+)".*/forge-\1/')"
    fi
    if [[ -n "${mc:-}" && -n "${forgeid:-}" ]]; then
      forgever="${forgeid#forge-}"
      fullver="${mc}-${forgever}"
      log "Deducido Forge desde manifest: $fullver"
      local url; url="$(forge_installer_url "$fullver")"
      sudo -u "$MC_USER" bash -lc "cd '$MC_DIR' && wget -q -O forge-$fullver-installer.jar \"$url\""
      install_forge_from_installer "forge-$fullver-installer.jar"
      return 0
    fi
  fi

  warn "No pude autodetectar Forge desde el serverpack."
  return 1
}

# -------------------- Resolver modo Forge -----------------------------
case "$FORGE_MODE" in
  none)
    warn "FORGE_MODE=none → No se instalará Forge."
    ;;
  auto)
    log "FORGE_MODE=auto → Intento autodetección/instalación de Forge…"
    if ! autodetect_or_install_forge; then
      warn "Autodetección falló. Si tu pack necesita Forge, pásalo con --forge <MC-FORGE>."
    fi
    ;;
  *)
    # Modo forzado con versión explícita MC-FORGE
    log "Instalación de Forge forzada: $FORGE_MODE"
    url="$(forge_installer_url "$FORGE_MODE")"
    sudo -u "$MC_USER" bash -lc "cd '$MC_DIR' && wget -q -O forge-$FORGE_MODE-installer.jar \"$url\""
    install_forge_from_installer "forge-$FORGE_MODE-installer.jar"
    ;;
esac

# -------------------- Script de arranque ------------------------------
log "Creando script de arranque…"
sudo tee "$MC_DIR/start" >/dev/null <<'EOF_START'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Permite override por entorno (XMS/XMX)
XMS="${XMS:-4G}"
XMX="${XMX:-4G}"

pick_jar() {
  ls -1 forge-*.jar 2>/dev/null | grep -v installer | head -n1 && return 0
  ls -1 *forge*universal*.jar 2>/dev/null | head -n1 && return 0
  ls -1 server.jar minecraft_server*.jar 2>/dev/null | head -n1 && return 0
  return 1
}

JAR="$(pick_jar || true)"
if [[ -z "${JAR:-}" ]]; then
  echo "No encuentro el JAR del servidor (Forge o vanilla)." >&2
  exit 1
fi

grep -q 'eula=true' eula.txt 2>/dev/null || echo 'eula=true' > eula.txt
exec /usr/bin/java -Xms"$XMS" -Xmx"$XMX" -jar "$JAR" nogui
EOF_START
sudo chmod +x "$MC_DIR/start"
sudo chown "$MC_USER:$MC_USER" "$MC_DIR/start"
sudo dos2unix "$MC_DIR/start" >/dev/null 2>&1 || true

# -------------------- server.properties (puerto) ----------------------
log "Ajustando server.properties (puerto $SERVER_PORT)…"
sudo -u "$MC_USER" bash -lc "
  cd '$MC_DIR'
  if [[ -f server.properties ]]; then
    if grep -q '^server-port=' server.properties; then
      sed -i 's/^server-port=.*/server-port=$SERVER_PORT/' server.properties
    else
      echo 'server-port=$SERVER_PORT' >> server.properties
    fi
  else
    echo 'server-port=$SERVER_PORT' > server.properties
  fi
"

# -------------------- Servicio systemd -------------------------------
log "Creando servicio systemd ($SERVICE_NAME)…"
sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<EOF_UNIT
[Unit]
Description=Minecraft Modpack Server
Wants=network-online.target
After=network-online.target

[Service]
User=$MC_USER
WorkingDirectory=$MC_DIR
ExecStart=$MC_DIR/start
Restart=on-failure
RestartSec=10
LimitNOFILE=100000
Environment=java.net.preferIPv4Stack=true
Environment=XMS=$XMS
Environment=XMX=$XMX

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
  log "Reiniciando servicio existente…"
  sudo systemctl restart "$SERVICE_NAME"
else
  log "Habilitando y arrancando servicio…"
  sudo systemctl enable --now "$SERVICE_NAME"
fi

sudo chown -R "$MC_USER:$MC_USER" "$MC_HOME"

log "Listo. Comandos útiles:"
echo "  sudo systemctl status $SERVICE_NAME --no-pager"
echo "  sudo journalctl -u $SERVICE_NAME -fn 100 --no-pager"
echo
warn "Abrí el puerto TCP $SERVER_PORT en el Security Group."
