# aws-mcserver
Como hostear server en AWS

1. **Clonar el proyecto**
```bash
git clone https://github.com/MattiasMR/aws-mcserver-forge.git
cd aws-mcserver-forge/

```
2. **Consigue la URL directa del Server Pack**
En tu PC abre el enlace .../download/<FILE_ID>, deja que descargue y copia la URL final del archivo desde el gestor de descargas; esa es la del CDN (p. ej. https://mediafilez.forgecdn.net/.../serverpack.zip).

3. **Ejecuta el setup con la URL directa**
```bash
chmod +x setup.sh
XMS=6G XMX=6G sudo ./setup.sh \
  --java 8 \
  --url "https://mediafilez.forgecdn.net/.../serverpack.zip" \
  --forge auto
```
> Notas:
> - --java 8 es lo típico para Forge 1.12.2 (RLCraft).
> - Cambia XMS/XMX según la RAM de tu instancia (mínimo recomendado 4–6 GB para packs pesados).

4. **Comprobar servicio y logs**
```bash
sudo systemctl status minecraft --no-pager
sudo journalctl -u minecraft -f
```

5. **Nota de red**
```bash
Abre el puerto 25565/TCP en el Security Group de la instancia.
```

6. **Ejemplos útiles**
- Usar un ZIP ya subido a la instancia:
```bash
XMS=8G XMX=8G sudo ./setup.sh --local /tmp/serverpack.zip --forge auto
```

- Forzar una versión concreta de Forge (si el pack no trae installer/manifest):
```bash
sudo ./setup.sh --forge 1.12.2-14.23.5.2860
```

7. **Troubleshooting rápido**
- 403 al descargar: la URL no es la directa del CDN (vuelve al paso 2).
- “No encuentro el JAR del servidor”: el ZIP podría ser de cliente; usa el Server Pack.
- RAM insuficiente: sube XMS/XMX o usa una instancia con más memoria.
