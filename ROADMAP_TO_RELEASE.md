# Roadmap a la Versión 1.0 Distribuible

Este documento detalla los pasos necesarios para convertir **WhisperMac** de un prototipo de desarrollo a una aplicación macOS nativa (`.app`) que cualquier usuario pueda descargar y usar.

## Fase 1: Independencia del Entorno (Bundling)
El objetivo es que la app no dependa de tener Homebrew o herramientas instaladas en el sistema del usuario.

- [ ] **Empaquetar `whisper-cli`**: Incluir el binario compilado de `whisper.cpp` dentro de la app.
- [ ] **Empaquetar Sonidos**: Mover los sonidos del sistema a recursos internos para garantizar que siempre estén disponibles.
- [ ] **Actualizar Rutas en Código**: Modificar `main.swift` para buscar el binario y los recursos en `Bundle.main.resourcePath` en lugar de rutas absolutas o de Homebrew.

## Fase 2: Estructura de Aplicación (.app)
Crear la estructura de carpetas estándar que macOS requiere para reconocer un programa como una aplicación.

- [ ] **Crear `Info.plist`**: Definir metadatos críticos:
    - Identificador del paquete (Bundle ID).
    - Permisos de Privacidad (Uso de Micrófono, Accesibilidad).
    - Versión de la app.
- [ ] **Diseñar Icono**: Crear un archivo `.icns` con el logo de la app para reemplazar el icono genérico.
- [ ] **Script de Construcción (Build Script)**: Crear un script (`build_app.sh`) que automatice:
    1. Compilar el código Swift.
    2. Crear la estructura de carpetas `WhisperMac.app`.
    3. Copiar el binario, `Info.plist`, iconos y recursos a sus lugares correctos.
    4. Copiar `whisper-cli` a la carpeta `Resources/bin`.

## Fase 3: Gestión de Modelos
Mejorar la experiencia de primer uso para usuarios sin conocimientos técnicos.

- [ ] **Descarga Automática Robusta**: Asegurar que si el modelo no existe, la app no falle, sino que guíe al usuario al onboarding (ya implementado, pero verificar robustez).
- [ ] **Ruta de Modelos**: Guardar los modelos en `~/Library/Application Support/WhisperMac/models` (estándar de macOS) en lugar de carpetas locales del proyecto.

## Fase 4: Tests de Calidad (QA)
Pasos de verificación antes de liberar la versión 1.0.

- [ ] **Prueba de "Caja Limpia"**: Instalar en un Mac limpio (o usar una VM/Usuario nuevo) para verificar que la app inicia, pide permisos y descarga el modelo sin errores.
- [ ] **Prueba de Permisos**: Verificar que si el usuario deniega el micrófono, la app muestra un aviso claro en lugar de fallar silenciosamente.
- [ ] **Prueba de Accesibilidad**: Asegurar que la simulación de pegado (Cmd+V) funciona en diferentes apps (Notes, Chrome, Word).

## Fase 5: Distribución

- [ ] **Firma de Código (Code Signing)**:
    - *Opción A (Simple)*: Firma Ad-Hoc (requiere que el usuario haga clic derecho -> Abrir la primera vez).
    - *Opción B (Pro)*: Firma con Apple Developer ID (elimina advertencias de seguridad, costo $99/año).
- [ ] **Empaquetado**: Crear un `.dmg` o `.zip` final para subir a GitHub Releases.

---

## Próximos Pasos Técnicos Sugeridos

1. **Crear carpeta `bin/`** en el proyecto y copiar allí una versión compilada y estática de `whisper-cli`.
2. **Modificar `main.swift`** para implementar la lógica de detección de recursos (buscar en Bundle si existe, sino usar rutas relativas para desarrollo).
3. **Crear el `build_app.sh`** básico.
