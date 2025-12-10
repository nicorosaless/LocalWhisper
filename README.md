# WhisperMac 🎤

> ⚠️ **PROYECTO EN DESARROLLO** - Este proyecto está en fase experimental.

Speech-to-text local para macOS usando whisper.cpp. Similar a Wispr Flow pero completamente local y gratuito.

## Estado actual

- ✅ Push-to-talk con Cmd+Shift+Space
- ✅ Transcripción con whisper.cpp
- ✅ Auto-paste al cursor
- ✅ Versión Swift (estable, recomendada)
- ⚠️ Versión Python (inestable, segfaults con Metal)

## Requisitos

- macOS 13+
- whisper-cli: `brew install whisper-cpp`
- Modelo Whisper (se descarga automáticamente)

## Uso

```bash
# Versión Swift (recomendada)
./run-swift.sh

# Versión Python (experimental)
./run.sh
```

Mantén **Cmd+Shift+Space** mientras hablas, suelta para transcribir.

## Modelos

Los modelos se descargan en `models/`. Por defecto usa `small` (465MB).

| Modelo | Tamaño | Velocidad | Precisión |
|--------|--------|-----------|-----------|
| tiny | 74MB | ⚡️⚡️⚡️ | ⭐️ |
| base | 142MB | ⚡️⚡️ | ⭐️⭐️ |
| small | 465MB | ⚡️ | ⭐️⭐️⭐️ |
| medium | 1.5GB | 🐌 | ⭐️⭐️⭐️⭐️ |

## Licencia

MIT
