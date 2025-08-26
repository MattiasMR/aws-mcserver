# aws-mcserver
Como hostear server en AWS

1. **Clonar el proyecto**
```bash
git clone https://github.com/MattiasMR/aws-mcserver-forge.git
cd aws-mcserver-forge/

```
2. **Descarga el modpack (serverpack) de curseforge, utiliza la URL directa**
```bash
curl -fL -C - -o serverpack.zip "URL_DEL_CDN_MEDIAFILEZ_DE_TU_SERVERPACK.zip"
unzip -l serverpack.zip | grep -Ei 'Server(Start| Files)|forge-1\.12\.2|minecraft_server\.1\.12\.2|start\.sh'
```
> URL Directa: en tu PC abre el enlace .../download/<FILE_ID>, deja que descargue, y copia la URL final del archivo desde el gestor de descargas; esa es la del CDN.

3. **Editar el archivo de setup**
Todas las configs están arriba. (Java, ram, etc.)
```bash
nano setup.sh   
```

4. **Guarda y ejecuta**
```bash
chmod +x setup.sh
sudo ./setup.sh
```

5. **Comprobar servicio y logs**
```bash
sudo systemctl status minecraft --no-pager
sudo journalctl -u minecraft -f
```

6. **Nota de red**
```bash
Abre el puerto 25565/TCP en el Security Group de la instancia.
```
