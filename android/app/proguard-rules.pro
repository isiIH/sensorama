# ==============================================================================
# REGLAS PREDETERMINADAS DE FLUTTER
# Mantienen el motor de Flutter y las clases nativas esenciales.
# ==============================================================================
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class com.google.firebase.** { *; }

-keep class * extends io.flutter.plugin.common.MethodCall
-keep class * extends io.flutter.plugin.common.MethodChannel$MethodCallHandler

# ==============================================================================
# REGLAS ESPECÍFICAS PARA PAQUETES DE TERCEROS
# ==============================================================================

# 1. FLUTTER_BLUE_PLUS (Bluetooth)
# Es esencial para los paquetes de Bluetooth/LE que utilizan APIs nativas.
# Esto previene que se ofusque o elimine el código usado para la comunicación.
-dontwarn android.support.v7.**
-keep class com.polidea.rxandroidble.** { *; }
-keep class com.polidea.rxandroidble2.** { *; }
-keep class com.polidea.rxandroidble2.internal.RxBleLog {}
-keep class com.polidea.rxandroidble2.internal.connection.** { *; }

# 2. FL_CHART (Gráficos)
# Aunque es un paquete de Dart puro, a veces las clases internas deben protegerse.
# Si encuentras un error "No Such Method" en tiempo de ejecución, esta regla ayuda.
# Esto protege clases internas necesarias para el manejo de touch y dibujo.
-keep class com.github.mikephil.charting.** { *; }

# 3. NETWORK_INFO_PLUS / CONNECTIVITY_PLUS
# Estos paquetes manejan información de red/WiFi que interactúa con las APIs de Android.
# Aseguramos que las clases necesarias no sean ofuscadas.
-keep class dev.fluttercommunity.plus.networkinfo.** { *; }
-keep class dev.fluttercommunity.plus.connectivity.** { *; }
-keep class io.flutter.plugins.connectivity.** { *; }

# 4. FLUTTER_DOTENV (Variables de Entorno)
# Generalmente no requiere reglas, pero si utilizas el método de carga nativa
# o encuentras problemas con el acceso a assets/archivos, esta regla genérica
# es una buena práctica para utilidades.
-keep class com.github.nisrulz.sense.** { *; }

# 5. INTL (Internacionalización)
# Maneja la carga de datos de localización. Asegura que el código de reflexión
# utilizado para cargar datos no sea eliminado.
-dontwarn java.lang.invoke.MethodHandle
-keep class com.ibm.icu.impl.data.** { *; }
-keep class com.ibm.icu.util.** { *; }

# ==============================================================================
# MANTENER ADAPTADORES/MODELOS PARA SERIALIZACIÓN (Si usas JSON/Bases de Datos)
# AGREGAR AQUÍ SI USAS: json_serializable, floor, hive, moor, etc.
# Ej. -keep class com.example.app.modelos.** { *; }
# ==============================================================================

# ==============================================================================
# REGLAS PARA GOOGLE PLAY CORE / SPLITCOMPAT
# Resuelve el error "Missing class com.google.android.play.core..." al usar R8.
# Esto es necesario incluso si NO usas Componentes Diferidos (Deferred Components),
# porque el motor de Flutter los referencia internamente.
# ==============================================================================
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }

# Mantener las clases principales de Flutter relacionadas con Play Store
-keep class io.flutter.embedding.android.FlutterPlayStoreSplitApplication { *; }