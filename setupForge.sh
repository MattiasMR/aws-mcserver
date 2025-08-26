#!/bin/bash
# =====================================================================
#  Script todo-en-uno para servidor de Minecraft con modpack (Forge)
#  Probado en Amazon Linux 2023 (ARM)
# =====================================================================
set -euo pipefail

# ======================== CONFIGURACIÓN ===============================

# Versión de Java a instalar (elige: 8, 17 o 21).
# Forge 1.12.2 (RLCraft) requiere Java 8.
JAVA_VERSION="8"

# URL del ZIP del *Server Pack* (NO el cliente). Si CurseForge te da 403,
# deja esto vacío y sube el archivo manualmente a /tmp/serverpack.zip.
MODPACK_URL=""

# Ruta local opcional (si ya subiste el ZIP a la instancia).
MODPACK_LOCAL="/tmp/serverpack.zip"

# Si tu modpack usa Forge, deja la versión del installer; si no usa Forge,
# pon FORGE_VERSION="" para saltar la instalación de Forge.
# Ejemplo (RLCraft 1.12.2):
FORGE_VERSION="1.12.2-14.23.5.2860"

# Memoria para la JVM (ajusta según tu instancia)
XMS="8G"
XMX="8G"

# Puerto del servidor (asegúrate de abrirlo en el Security Group)
SERVER_PORT="25565"

# Usuario y ruta del servidor
MC_USER="minecraft"
MC_HOME="/opt/minecraft"
MC_DIR="$MC_HOME/server"

# Nombre del servicio systemd
SERVICE_NAME="minecraft"

# ====================== FIN CONFIGURACIÓN =============================

log() { echo -e "\e[1;32m[*]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[!]\e[0m $*"; }
err() { echo -e "\e[1;31m[✗]\e[0m $*" >&2; }

# Mapear paquete de Java
case "$JAVA_VERSION" in
  8)  JAVA_PKG="java-1.8.0-amazon-corretto" ;;
  17) JAVA_PKG="java-17-amazon-corretto" ;;
  21) JAVA_PKG="java-21-amazon-corretto" ;;
  *)  err "JAVA_VERSION inválida: $JAVA_VERSION (usa 8, 17 o 21)"; exit 1 ;;
esac

# Paquetes base (sin curl para evitar conflictos con curl-minimal)
log "Instalando paquetes base y Java $JAVA_VERSION..."
sudo dnf -y install unzip wget dos2unix $JAVA_PKG >/dev/null

# Usuario y carpetas
log "Creando usuario y carpetas..."
sudo useradd -r -m -d "$MC_HOME" "$MC_USER" 2>/dev/null || true
sudo mkdir -p "$MC_DIR"
sudo chown -R "$MC_USER:$MC_USER" "$MC_HOME"

# Descargar o usar ZIP local
TMP_ZIP="/tmp/serverpack.zip"
if [[ -n "${MODPACK_URL:-}" ]]; then
  log "Descargando Server Pack desde URL..."
  if ! wget -q --content-disposition --trust-server-names -O "$TMP_ZIP" "$MODPACK_URL"; then
    warn "Fallo al descargar (¿403?). Se intentará usar $MODPACK_LOCAL si existe."
  fi
fi

if [[ ! -f "$TMP_ZIP" && -f "$MODPACK_LOCAL" ]]; then
  log "Usando ZIP local: $MODPACK_LOCAL"
  sudo cp -f "$MODPACK_LOCAL" "$TMP_ZIP"
fi

if [[ ! -f "$TMP_ZIP" ]]; then
  err "No tengo el ZIP del Server Pack. Sube el archivo a $TMP_ZIP o fija MODPACK_URL."
  exit 1
fi

# Descomprimir Server Pack
log "Descomprimiendo Server Pack en $MC_DIR..."
sudo -u "$MC_USER" bash -lc "
  set -e
  cd '$MC_DIR'
  unzip -o '$TMP_ZIP' >/dev/null

  # Aplanar si el ZIP trae una carpeta raíz única
  dirs=( \$(find . -mindepth 1 -maxdepth 1 -type d) )
  if (( \${#dirs[@]} == 1 )) && [[ ! -e mods && ! -e config && ! -e scripts ]]; then
    top=\"\${dirs[0]}\"
    shopt -s dotglob nullglob
    mv \"\$top\"/* .
    shopt -u dotglob nullglob
    rmdir \"\$top\" || true
  fi
"

# Instalar Forge si se solicitó
if [[ -n "$FORGE_VERSION" ]]; then
  log "Instalando Forge ($FORGE_VERSION) en modo servidor..."
  sudo -u "$MC_USER" bash -lc "
    set -e
    cd '$MC_DIR'
    # Si el installer no está en el pack, bájalo del maven oficial
    if ! ls -1 forge-$FORGE_VERSION-installer.jar >/dev/null 2>&1; then
      wget -q -O forge-$FORGE_VERSION-installer.jar \
        'https://maven.minecraftforge.net/net/minecraftforge/forge/$FORGE_VERSION/forge-$FORGE_VERSION-installer.jar'
    fi

    # (Opcional) server vanilla 1.12.2 para Forge 1.12.2; ignora errores si no aplica
    if [[ '$FORGE_VERSION' == 1.12.2-* && ! -f minecraft_server.1.12.2.jar ]]; then
      wget -q -O minecraft_server.1.12.2.jar \
        'https://launcher.mojang.com/v1/objects/886945bfb2b978778c3a0288fd7fab09d315b25f/server.jar' || true
    fi

    # Instalar headless
    java -jar forge-$FORGE_VERSION-installer.jar --installServer --debug >/dev/null
  "
else
  warn "FORGE_VERSION vacío: se omitirá la instalación de Forge (útil si el server pack ya trae el jar del server)."
fi

# Script de arranque
log "Creando script de arranque..."
sudo tee "$MC_DIR/start" >/dev/null <<'EOF_START'
#!/bin/bash
set -euo pipefail
cd /opt/minecraft/server

# Memoria por variables de entorno (con defaults)
XMS="${XMS:-4G}"
XMX="${XMX:-4G}"

# Elegir jar de servidor, priorizando Forge (excluye installer)
pick_jar() {
  # 1) Forge del mismo directorio (sin installer)
  ls -1 forge-*.jar 2>/dev/null | grep -v installer | head -n1 && return 0
  # 2) Otros jars Forge "universal"
  ls -1 *forge*universal*.jar 2>/dev/null | head -n1 && return 0
  # 3) server.jar o vanilla
  ls -1 server.jar minecraft_server*.jar 2>/dev/null | head -n1 && return 0
  return 1
}

JAR="$(pick_jar || true)"
if [[ -z "${JAR:-}" ]]; then
  echo "No encuentro el JAR del servidor (Forge o vanilla). Revisa la instalación." >&2
  exit 1
fi

# Aceptar EULA si hace falta
grep -q 'eula=true' eula.txt 2>/dev/null || echo 'eula=true' > eula.txt

exec /usr/bin/java -Xms"$XMS" -Xmx"$XMX" -jar "$JAR" nogui
EOF_START

sudo chmod +x "$MC_DIR/start"
sudo chown "$MC_USER:$MC_USER" "$MC_DIR/start"
sudo dos2unix "$MC_DIR/start" >/dev/null 2>&1 || true

# Ajustar server.properties (puerto)
log "Ajustando server.properties (puerto $SERVER_PORT)..."
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

# Unit de systemd
log "Creando servicio systemd ($SERVICE_NAME)..."
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

# Reiniciar si ya existe; si no, habilitar y arrancar
if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
  log "Reiniciando servicio existente..."
  sudo systemctl restart "$SERVICE_NAME"
else
  log "Habilitando y arrancando servicio..."
  sudo systemctl enable --now "$SERVICE_NAME"
fi

# Permisos finales
sudo chown -R "$MC_USER:$MC_USER" "$MC_HOME"

log "Listo. Revisa estado y logs:"
echo "  sudo systemctl status $SERVICE_NAME --no-pager"
echo "  sudo journalctl -u $SERVICE_NAME -fn 100 --no-pager"
echo
warn "Asegúrate de abrir el puerto TCP $SERVER_PORT en el Security Group de la instancia."
