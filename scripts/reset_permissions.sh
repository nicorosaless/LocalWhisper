#!/bin/bash
# Script para reiniciar todos los permisos de LocalWhisper
# Esto permite volver a configurar los permisos desde cero

echo "🧹 Reiniciando permisos de LocalWhisper..."

BUNDLE_ID="com.nicorosaless.LocalWhisper"
APP_NAME="LocalWhisper"

# 1. Cerrar la app si está corriendo
echo "🛑 Cerrando LocalWhisper..."
pkill -9 -f "LocalWhisper" 2>/dev/null || true
sleep 1

# 2. Eliminar preferencias del usuario
echo "🗑️  Eliminando preferencias..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -rf ~/Library/Preferences/${BUNDLE_ID}* 2>/dev/null || true

# 3. Eliminar caché
echo "🗑️  Eliminando caché..."
rm -rf ~/Library/Caches/${BUNDLE_ID}* 2>/dev/null || true
rm -rf ~/Library/Caches/LocalWhisper 2>/dev/null || true

# 4. Eliminar datos de la app
echo "🗑️  Eliminando datos de la app..."
rm -rf ~/Library/Application\ Support/LocalWhisper 2>/dev/null || true

# 5. Resetear permisos TCC (Microphone, Camera, Accessibility, etc.)
echo "🔐 Eliminando permisos del sistema..."

# TCC database path
TCC_DB="~/Library/Application Support/com.apple.TCC/TCC.db"

# Eliminar entradas de TCC para el Bundle ID (requiere deshabilitar SIP para funcionar completamente,
# pero intentamos eliminar lo que podamos)
sqlite3 "$TCC_DB" "DELETE FROM access WHERE client LIKE '%${BUNDLE_ID}%';" 2>/dev/null || echo "  ⚠️  No se pudieron modificar permisos TCC (requiere permisos especiales)"

# Alternativa: Resetear permisos usando tccutil (solo funciona para algunos servicios)
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || echo "  ℹ️  Microphone permissions reset skipped"
tccutil reset Camera "$BUNDLE_ID" 2>/dev/null || echo "  ℹ️  Camera permissions reset skipped"
tccutil reset All "$BUNDLE_ID" 2>/dev/null || echo "  ℹ️  All permissions reset attempted"

# 6. Eliminar de Accesibilidad (hay que hacerlo manualmente o vía sqlite)
echo "📝 Nota: Los permisos de Accesibilidad deben eliminarse manualmente en:"
echo "   System Settings > Privacy & Security > Accessibility"
echo "   Busca 'LocalWhisper' y elimínalo con el botón '-'"

# 7. Limpiar atributos extendidos (quarantine, etc.)
echo "🧹 Limpiando atributos extendidos..."
xattr -cr ~/Applications/LocalWhisper.app 2>/dev/null || true
xattr -cr /Applications/LocalWhisper.app 2>/dev/null || true
xattr -cr ./build/LocalWhisper.app 2>/dev/null || true

echo ""
echo "✅ Permisos reiniciados correctamente"
echo ""
echo "📋 Próximos pasos:"
echo "   1. Abre LocalWhisper.app nuevamente"
echo "   2. Cuando solicite permisos, acepta todos"
echo "   3. Para Accesibilidad, ve a:"
echo "      System Settings > Privacy & Security > Accessibility"
echo "      Haz clic en '+' y agrega LocalWhisper.app"
echo ""
echo "   ⚠️  IMPORTANTE: Si la app está en ~/Documents/GitHub/whipermac/build/"
echo "      agrégala desde esa ubicación, NO desde /Applications"
