# WhisperMac 🎤

**Herramienta de dictado local para Mac** - Similar a Wispr Flow pero gratis y 100% local.

## Características

- ✅ **100% Local** - Sin conexión a internet, privacidad total
- ✅ **Rápido** - Usa whisper.cpp optimizado para Apple Silicon (Metal GPU)
- ✅ **Hotkey Global** - `Cmd+Shift+Space` para dictar en cualquier app
- ✅ **Auto-Paste** - Pega automáticamente el texto donde esté el cursor


## Instalación

```bash
# 1. Instalar dependencias (si no están)
brew install whisper-cpp portaudio

# 2. Instalar dependencias Python
pip3 install -r requirements.txt

# 3. Descargar el modelo (1.5GB) - ya incluido si clonaste el repo
# curl -L -o models/ggml-large-v3-turbo.bin \
#   "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```


## Uso

```bash
# Ejecutar la app
./run.sh

# O directamente:
python3 main.py
```

1. Aparecerá un icono 🎤 en la barra de menú
2. Presiona **Cmd+Shift+Space** para empezar a grabar
3. Habla...
4. Presiona **Cmd+Shift+Space** de nuevo para parar
5. El texto se transcribe y pega automáticamente


## Permisos Requeridos

La primera vez que ejecutes la app, macOS te pedirá:

1. **Acceso al micrófono** - Para grabar audio
2. **Acceso a Accesibilidad** - Para detectar el hotkey global y pegar texto

Ve a **Preferencias del Sistema → Privacidad y Seguridad** para conceder los permisos.


## Configuración

Edita `config.json` para personalizar:

```json
{
  "model": "large-v3-turbo",
  "language": "auto",
  "hotkey": "cmd+shift+space",
  "auto_paste": true
}
```

### Idiomas

Para mejor precisión en español:
```json
{
  "language": "es"
}
```


## Solución de Problemas

**El hotkey no funciona:**
- Asegúrate de haber concedido permisos de Accesibilidad

**La transcripción es lenta:**
- El modelo `large-v3-turbo` tarda ~1-2 segundos en Apple Silicon
- Para más velocidad, usa el modelo `base` (menos preciso)

**No hay audio:**
- Verifica permisos de micrófono en Preferencias del Sistema
