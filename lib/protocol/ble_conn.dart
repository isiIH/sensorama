import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import 'protocol.dart';

class BLEConn extends Protocol {
  // Singleton Pattern
  static final BLEConn _instance = BLEConn._internal();
  factory BLEConn() => _instance;
  BLEConn._internal() : super('BLE');

  late BluetoothDevice _targetDevice;
  StreamSubscription? _valueChangedSubscription;
  StreamSubscription? _connectionStateSubscription;

  // Control de estado
  bool _intentionalDisconnect = false;
  bool _isNegotiating = false;

  static const String _prefLastDeviceId = 'last_ble_device_id';

  /// Llamar al iniciar la app para reconectar automáticamente
  Future<void> restoreLastConnection() async {
    final prefs = await SharedPreferences.getInstance();
    final String? lastId = prefs.getString(_prefLastDeviceId);

    if (lastId != null && lastId.isNotEmpty) {
      debugPrint("💾 Dispositivo guardado encontrado: $lastId. Intentando reconectar...");
      // En FBP podemos instanciar un dispositivo directamente desde su ID sin escanear
      final device = BluetoothDevice.fromId(lastId);
      handleConnection(device);
    }
  }

  /// Comienza el ciclo de conexión persistente hacia una MAC específica.
  /// No importa si el dispositivo se está reiniciando, este método lo buscará hasta encontrarlo.
  @override
  void handleConnection(dynamic event) {
    _intentionalDisconnect = false;
    _targetDevice = event;
    _persistDevice(_targetDevice.remoteId.str); // guardamos el mac en prefs
    
    // Limpiamos subscripciones previas por seguridad
    _cleanupSubscriptions();

    debugPrint("🏁 Iniciando monitoreo BLE para: ${_targetDevice.remoteId} (${_targetDevice.platformName})");

    // Escuchamos el estado de la conexión globalmente para este dispositivo
    _connectionStateSubscription = _targetDevice.connectionState.listen((BluetoothConnectionState state) {
      if (state == BluetoothConnectionState.connected) {
        if (!_isNegotiating) {
          debugPrint("✅ Dispositivo conectado a nivel físico. Iniciando negociación lógica...");
           _negotiateConnection();
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        if (!_intentionalDisconnect) {
          debugPrint("⚠️ Desconexión detectada (¿Reinicio de ESP32?). Iniciando reconexión...");
          _reconnectLoop();
        } else {
          debugPrint("ℹ️ Desconexión intencional completada.");
        }
      }
    });

    // Intentamos conectar inmediatamente (o entrar en el loop de reconexión si se está reiniciando)
    _reconnectLoop();
  }

  /// Bucle recursivo que intenta conectar con el dispositivo específico
  void _reconnectLoop() async {
    if (_intentionalDisconnect || _targetDevice.isConnected) return;

    try {
      debugPrint("🔄 Buscando dispositivo ${_targetDevice.remoteId}...");
      // Intentamos conectar.
      // timeout: le da tiempo al ESP32 de arrancar.
      // autoConnect: false para que falle (timeout) si no está y podamos reintentar la lógica manualmente.
      await _targetDevice.connect(
        license: License.free,
        autoConnect: false,
        timeout: Duration(seconds: 4) // Ventana de búsqueda
      );
    // Si llegamos aquí, connect() tuvo éxito, el listener de connectionState llamará a _negotiateConnection
    } catch (e) {
      // Si falla (timeout o error porque el ESP32 sigue reiniciando)
      if (!_intentionalDisconnect) {
        debugPrint("⏳ Dispositivo no encontrado o reiniciando... reintentando en 1s.");
        // Espera no bloqueante antes de reintentar
        Future.delayed(Duration(seconds: 1), () => _reconnectLoop());
      }
    }
  }

  /// Lógica de Servicios y Suscripciones (MTU, Notify)
  Future<void> _negotiateConnection() async {
    _isNegotiating = true;

    try {
      // Descubrir servicios
      List<BluetoothService> services = await _targetDevice.discoverServices();

      // Buscar servicio y característica en una pasada eficiente
      BluetoothCharacteristic? dataChar;

      try {
        final service = services.firstWhere((s) => s.uuid == AppConstants.dataServiceUUID);
        dataChar = service.characteristics.firstWhere((c) => c.uuid == AppConstants.charDataUUID);
      } catch (e) {
        // Si no encuentra el servicio o la característica (ej. modo Aprovisionamiento)
        debugPrint("⛔ Servicio/Característica no encontrados. Abortando persistencia.");
        disconnect();
        return;
      }

      // Suscribirse
      if (dataChar.properties.notify) {
        if (!dataChar.isNotifying) {
          await dataChar.setNotifyValue(true);
        }

        _valueChangedSubscription?.cancel();
        _valueChangedSubscription = dataChar.onValueReceived.listen((value) {
          if (value.length >= Protocol.headerSize) {
            // Asumiendo que decodePacket y currentPacket son parte de Protocol o globales
            decodePacket(Uint8List.fromList(value));
            // Asumiendo que connectionController existe en la clase padre o global
            connectionController.add(currentPacket.macAddress);
          }
        });
        debugPrint('✅ Flujo de datos activo.');
      }

    } catch (e) {
      debugPrint("❌ Error negociación: $e. Reiniciando conexión...");
      _targetDevice.disconnect();
    } finally {
      _isNegotiating = false;
    }
  }

  /// 🛑 Detiene todo y desconecta
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    debugPrint('🛑 Solicitud de desconexión manual.');
    
    _cleanupSubscriptions();

    // Borramos el ID del dispositivo
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefLastDeviceId);
    
    await _targetDevice.disconnect();
  }
  
  void _cleanupSubscriptions() {
    _valueChangedSubscription?.cancel();
    _connectionStateSubscription?.cancel();
  }

  Future<void> _persistDevice(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLastDeviceId, id);
  }

  @override
  Future<void> stop() async {
    _cleanupSubscriptions();
    super.stop();
  }
}