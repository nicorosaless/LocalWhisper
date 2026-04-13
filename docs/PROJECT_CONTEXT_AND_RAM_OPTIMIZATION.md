# LocalWhisper: Contexto del proyecto y plan de optimizacion de RAM

## 1) Contexto actual del proyecto

LocalWhisper es una app de macOS (menu bar) para dictado local con hotkey y auto-paste.

### Componentes principales

- `swift/Sources/main.swift`: ciclo principal de la app, captura de audio, hotkeys, estados de UI y orquestacion de transcripcion.
- `swift/Sources/Engines/WhisperCppEngine.swift`: backend `whisper.cpp` por subprocess.
- `swift/Sources/Engines/Qwen3ASREngine.swift`: backend Qwen3 via proceso persistente (actualmente Python) con protocolo JSON por `stdin/stdout`.
- `scripts/transcribe.py`: servidor de inferencia Qwen3-ASR que carga modelo MLX y atiende requests.
- `swift/Sources/Models/EngineConfig.swift`: tipos de engine, metadatos de modelo y rutas de cache.

### Flujo de inferencia (Qwen3 actual)

1. Swift graba WAV mono 16 kHz.
2. Swift envia `{ "wav": "...", "language": "..." }` al proceso Python persistente.
3. Python carga modelo Qwen3-ASR 0.6B una vez y reutiliza para requests.
4. Python responde `{ "text": "..." }`.
5. Swift hace auto-paste en la app destino.

### Donde se guarda el modelo

- Cache Qwen3: `~/Library/Application Support/LocalWhisper/qwen3-cache/`
- Config: `~/Library/Application Support/LocalWhisper/config.json`


## 2) Diagnostico de RAM (~1.3 GB)

Para Qwen3 0.6B, el consumo alto viene de la suma de:

- Runtime Python + libs (base del proceso).
- Runtime MLX + pesos del modelo en memoria unificada.
- Buffers intermedios de audio/features/activaciones.
- KV cache del decoder (crece con tokens generados).

### Observacion critica

En `scripts/transcribe.py`, `transcribe_audio(..., max_tokens=8192)` es muy alto para dictado normal y puede inflar el uso de KV cache/latencia innecesariamente. Para uso real de dictado, normalmente `256-512` es suficiente.


## 3) Objetivo de optimizacion

Mantener **Qwen3-ASR 0.6B** y reducir RAM al minimo practico sin romper UX:

- Meta realista: bajar de ~1.3 GB a ~0.85-1.0 GB.
- Meta agresiva: ~0.7-0.9 GB (requiere mas trabajo en backend y buffers).

### Perfil de UX objetivo (dictado real)

- Hablar **40s** de forma comoda y estable (sin OOM ni timeouts falsos).
- Para audios **<= 30s**, priorizar **latencia minima**.
- Para audios **30-40s**, se acepta hasta **~+1s** de latencia extra para estabilizar RAM.
- Calidad: **sin perdida de calidad de transcripcion** (no recortar contenido ni truncar texto).


## 4) Estrategia priorizada para bajar RAM (de mayor impacto a menor)

### A. Eliminar Python en runtime (alto impacto)

Migrar `scripts/transcribe.py` a un daemon en Rust con backend MLX (Metal), manteniendo el mismo protocolo JSON.

Beneficios:

- Elimina overhead de Python en memoria.
- Menor fragmentacion y menos objetos temporales.
- Mejor control de ciclos de vida de buffers.

Riesgo:

- Medio/alto de implementacion (FFI/packaging), pero manejable con feature flag y fallback.

### B. Reducir `max_tokens` dinamicamente (alto impacto y rapido)

Cambiar la generacion desde un valor fijo grande a un limite adaptativo.

Recomendacion inicial:

- audio <= 30s: `max_tokens = 384` (camino de minima latencia)
- audio > 30s y <= 40s: `max_tokens = 512`
- audio > 40s y <= 60s: `max_tokens = 640`
- hard cap de seguridad: `768`

Guardarrail de calidad (obligatorio):

- Si la generacion toca el limite de `max_tokens` (cap hit), reintentar automaticamente con tope mayor (ej. `+50%`, respetando hard cap).
- Objetivo del reintento: eliminar truncamientos sin penalizar la latencia del caso normal.

Impacto:

- Menos crecimiento de KV cache.
- Menor RAM pico y menor latencia en casos largos.

### C. Evitar copias innecesarias de tensores/audio (alto impacto)

Revisar pipeline para evitar duplicados de:

- WAV -> `numpy` -> MLX array
- `input_embeddings`, `audio_features`, y reemplazo de tokens con arrays temporales grandes

Objetivo:

- Reducir buffers temporales y consolidar transformaciones in-place cuando sea posible.

### D. Politica de carga/descarga del engine (impacto medio)

Agregar perfiles de memoria:

- `balanced` (default): engine persistente.
- `low_ram`: unload tras inactividad (ej. 60-120s).

En `low_ram`, primera transcripcion puede tener cold start, pero RAM en reposo baja fuerte.

### E. Control de concurrencia (impacto medio)

Forzar una sola transcripcion activa por engine Qwen3.

- Evita picos de RAM por requests simultaneos.
- Simplifica control de buffers y estabilidad.

Complemento de estabilidad para audios largos:

- En Swift (`Qwen3ASREngine.swift`), usar timeout dinamico por duracion de audio en lugar de timeout fijo.
- Regla orientativa: `timeout = base + factor * duracionSeg` (p. ej. `25 + 1.5 * seg`).
- Para ~40s debe evitar timeouts falsos y mantener UX consistente.

### F. Manejo de memoria bajo presion (impacto medio)

Cuando macOS senala memory pressure:

- purgar caches no esenciales,
- liberar tensors temporales,
- opcionalmente descargar engine si no esta grabando.


## 5) Plan de implementacion PASO POR PASO (prioridad: RAM maxima)

Este plan esta escrito para ejecutar trabajo real en el repo actual, en orden, con criterio de salida por paso.

### PASO 0 - Congelar baseline y criterio de exito (obligatorio)

Objetivo:

- Tener numeros comparables antes de optimizar.

Que hacer:

- Definir dataset fijo de audio (es/en): 5 clips cortos, 5 medios, 5 largos.
- Medir por corrida:
  - RSS idle (app abierta sin transcribir)
  - RSS pico durante transcripcion
  - latencia p50/p95
  - tasa de error
- Guardar resultados en una tabla baseline.

Criterio de salida:

- Baseline repetible (2 corridas con variacion pequena).

---

### PASO 1 - Quick win critico: bajar `max_tokens` adaptativo

Objetivo:

- Recortar crecimiento de KV cache y bajar RAM pico sin degradar latencia.

Que hacer:

- Editar `scripts/transcribe.py`:
  - Reemplazar `max_tokens=8192` por politica adaptativa.
  - Regla inicial recomendada:
    - audio <= 30s -> `max_tokens = 384`
    - audio > 30s y <= 40s -> `max_tokens = 512`
    - audio > 40s y <= 60s -> `max_tokens = 640`
    - hard cap -> `768`
  - Agregar reintento automatico solo si hay cap hit para proteger calidad:
    - Primer pase: politica adaptativa (camino rapido)
    - Reintento condicional: `max_tokens` mayor (ej. `+50%`) sin superar hard cap
- Mantener parametros como constantes al inicio del script para ajuste rapido.

Criterio de salida:

- RAM pico baja de forma medible vs baseline.
- Latencia minima para <=30s.
- Para 30-40s, aumento aceptable de latencia <= ~1s.
- Sin truncamientos visibles en dictado normal y dictado largo.

---

### PASO 2 - Evitar picos por concurrencia y limpiar temporales

Objetivo:

- Eliminar picos evitables de memoria y mantener estabilidad.

Que hacer:

- En `swift/Sources/Engines/Qwen3ASREngine.swift`:
  - Forzar una sola transcripcion activa (single-flight).
  - Si llega una segunda request, encolar o rechazar de forma controlada.
  - Reemplazar timeout fijo de respuesta por timeout dinamico basado en duracion del WAV.
- En `scripts/transcribe.py`:
  - Liberar referencias temporales por request (`audio_features`, `inputs_embeds`, buffers intermedios) al finalizar.
  - Evitar estructuras duplicadas innecesarias en reemplazo de audio tokens.

Criterio de salida:

- Sin crecimiento acumulativo de RSS tras 30-50 transcripciones consecutivas.
- Sin errores nuevos de timeout/cuelgue en audios de 40s.

---

### PASO 3 - Eliminar seleccion de modelo (Qwen 0.6B unico)

Objetivo:

- Simplificar flujo, reducir estados y concentrar optimizacion en un solo backend.

Que hacer (UI + config + runtime):

- `swift/Sources/Models/EngineConfig.swift`:
  - Dejar un unico engine soportado para usuario final (`qwen-0.6b`).
  - Mantener helper de cache y validacion de descarga para ese engine.
- `swift/Sources/SettingsView.swift`:
  - Borrar seccion de seleccion de engine.
  - Mostrar solo estado de descarga de Qwen 0.6B si aplica.
- `swift/Sources/OnboardingView.swift`:
  - Borrar eleccion Whisper vs Qwen.
  - Paso de modelo pasa a ser: descargar/verificar Qwen 0.6B.
- `swift/Sources/main.swift`:
  - Quitar ramas de cambio de engine para UX normal.
  - Cargar Qwen por defecto.
  - Mantener fallback tecnico solo temporal si se decide para rollout seguro.
- Migracion de config:
  - Si existe `engine_type` viejo, mapear automaticamente a `qwen-0.6b`.
  - Ignorar `model_path` de Whisper legacy en flujo nuevo.

Criterio de salida:

- No existe selector de modelo en onboarding/settings/menu.
- La app inicia y transcribe con Qwen 0.6B sin pasos manuales extra.

---

### PASO 4 - Implementar perfil `low_ram` con unload por inactividad

Objetivo:

- Reducir RAM idle sin sacrificar latencia percibida en uso normal.

Que hacer:

- Agregar en config un perfil de memoria (`balanced` y `low_ram`).
- En `Qwen3ASREngine.swift`:
  - Timer de inactividad (60-120s) para unload en `low_ram`.
  - Cancelar unload si vuelve actividad.
- Manejo de memory pressure:
  - Purga de caches no esenciales.
  - Si no hay grabacion activa, permitir unload preventivo.

Criterio de salida:

- RAM idle reduce >= 30% en `low_ram`.
- Primer uso tras idle puede tener cold start, pero sin errores ni bloqueos.

---

### PASO 5 - Instrumentacion minima de memoria/latencia

Objetivo:

- Tener visibilidad continua para validar que cada cambio mejora.

Que hacer:

- Loggear por request:
  - duracion audio
  - max_tokens aplicado
  - latencia total
  - resultado ok/error
- Registrar muestras de RSS en puntos fijos (antes/despues de transcribir, idle).
- Guardar CSV/JSON local para comparar fases.

Criterio de salida:

- Reporte por fase con comparativa contra baseline.

---

### PASO 6 - Refactor de alto impacto: sacar Python del runtime

Objetivo:

- Reducir memoria base y overhead del proceso de inferencia.

Que hacer:

- Implementar daemon nativo (Rust o Swift) con protocolo JSON compatible (`stdin/stdout`).
- Integrar bajo feature flag en `Qwen3ASREngine.swift`.
- Mantener fallback temporal a ruta Python mientras madura.

Criterio de salida:

- Reduccion adicional de RAM baseline.
- Latencia p95 igual o mejor.
- Estabilidad sostenida en prueba de 1 hora.

---

### PASO 7 - Cierre tecnico de la fase RAM

Objetivo:

- Congelar una version optimizada antes de pasar a instalacion/distribucion.

Que hacer:

- Ejecutar suite final de pruebas sobre mismo dataset baseline.
- Validar criterios de aceptacion (seccion 6).
- Documentar decision final de arquitectura (Qwen-only + politica de memoria elegida).

Criterio de salida:

- Se cumplen objetivos de RAM y latencia.
- Queda lista la siguiente fase: instalacion y empaquetado.


## 6) Criterios de aceptacion

- RAM pico: reduccion >= 25% respecto baseline.
- RAM idle: reduccion >= 30% en modo `low_ram`.
- Latencia p95: no peor que +15%.
- Calidad de texto: sin regresion relevante para dictado real.
- Estabilidad: cero crashes en prueba de 1 hora de uso continuo.
- UX objetivo cumplida:
  - <=30s mantiene latencia minima.
  - 30-40s tolera hasta ~+1s de latencia.
  - Sin perdida de contenido por truncamiento (cap hit cubierto por reintento).


## 7) Checklist tecnico concreto (orden de ejecucion)

- [ ] PASO 0 completado: baseline con metricas reproducibles.
- [ ] PASO 1 completado: `max_tokens` adaptativo activo en `scripts/transcribe.py`.
- [ ] PASO 2 completado: single-flight + limpieza de temporales.
- [ ] PASO 3 completado: eliminada seleccion de modelo (Qwen 0.6B unico).
- [ ] PASO 4 completado: modo `low_ram` funcional.
- [ ] PASO 5 completado: metricas persistidas por request/fase.
- [ ] PASO 6 completado: daemon nativo integrado con feature flag.
- [ ] PASO 7 completado: validacion final y congelamiento de fase RAM.


## 8) Recomendacion final

Si la prioridad es **bajar RAM al maximo sin perder latencia**, ejecutar exactamente este orden:

1. PASO 0 (baseline),
2. PASO 1 y PASO 2 (quick wins de RAM),
3. PASO 3 (Qwen-only, sin seleccion de modelo),
4. PASO 4 y PASO 5 (low_ram + instrumentacion),
5. PASO 6 (daemon nativo),
6. PASO 7 (cierre y congelamiento).

Con este orden se consigue impacto temprano, control de riesgo, y una ruta clara para luego pasar a instalacion y distribucion.
