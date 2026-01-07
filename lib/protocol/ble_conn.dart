import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import 'protocol.dart';

/// Holds per-device connection state for multi-device BLE support
class _BLEDeviceState {
  final BluetoothDevice device;
  StreamSubscription? valueChangedSubscription;
  StreamSubscription? connectionStateSubscription;
  bool intentionalDisconnect = false;
  bool isNegotiating = false;

  _BLEDeviceState(this.device);

  String get deviceId => device.remoteId.str;

  void cleanup() {
    valueChangedSubscription?.cancel();
    connectionStateSubscription?.cancel();
  }
}

class BLEConn extends Protocol {
  // Singleton Pattern (still singleton manager, but manages multiple devices)
  static final BLEConn _instance = BLEConn._internal();
  factory BLEConn() => _instance;
  BLEConn._internal() : super('BLE');

  // Track multiple connected devices by their remote ID
  final Map<String, _BLEDeviceState> _connectedDevices = {};

  static const String _prefConnectedDeviceIds = 'ble_connected_device_ids';

  /// Get list of currently connected device IDs
  List<String> get connectedDeviceIds => _connectedDevices.keys.toList();

  /// Check if a device is connected
  bool isDeviceConnected(String deviceId) => _connectedDevices.containsKey(deviceId);

  /// Llamar al iniciar la app para reconectar automáticamente a todos los dispositivos guardados
  Future<void> restoreLastConnection() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedIds = prefs.getString(_prefConnectedDeviceIds);

    if (savedIds != null && savedIds.isNotEmpty) {
      final List<String> deviceIds = (jsonDecode(savedIds) as List).cast<String>();
      debugPrint("💾 ${deviceIds.length} dispositivo(s) guardado(s). Intentando reconectar...");
      
      for (final deviceId in deviceIds) {
        final device = BluetoothDevice.fromId(deviceId);
        handleConnection(device);
      }
    }
  }

  /// Comienza el ciclo de conexión persistente hacia una MAC específica.
  /// Soporta múltiples dispositivos simultáneos.
  @override
  void handleConnection(dynamic event) {
    final BluetoothDevice device = event;
    final String deviceId = device.remoteId.str;

    // Si ya está siendo gestionado, no duplicar
    if (_connectedDevices.containsKey(deviceId)) {
      debugPrint("⚠️ Dispositivo $deviceId ya está siendo gestionado.");
      return;
    }

    // Crear estado para este dispositivo
    final deviceState = _BLEDeviceState(device);
    _connectedDevices[deviceId] = deviceState;

    _persistDevices(); // Guardar lista actualizada

    debugPrint("🏁 Iniciando monitoreo BLE para: $deviceId (${device.platformName})");

    // Escuchamos el estado de la conexión para este dispositivo
    deviceState.connectionStateSubscription = device.connectionState.listen((BluetoothConnectionState state) {
      if (state == BluetoothConnectionState.connected) {
        if (!deviceState.isNegotiating) {
          debugPrint("✅ [$deviceId] Dispositivo conectado a nivel físico. Iniciando negociación lógica...");
          _negotiateConnection(deviceState);
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        if (!deviceState.intentionalDisconnect) {
          debugPrint("⚠️ [$deviceId] Desconexión detectada (¿Reinicio de ESP32?). Iniciando reconexión...");
          _reconnectLoop(deviceState);
        } else {
          debugPrint("ℹ️ [$deviceId] Desconexión intencional completada.");
        }
      }
    });

    // Intentamos conectar inmediatamente
    _reconnectLoop(deviceState);
  }

  /// Bucle recursivo que intenta conectar con el dispositivo específico
  void _reconnectLoop(_BLEDeviceState deviceState) async {
    if (deviceState.intentionalDisconnect || deviceState.device.isConnected) return;

    // Verificar si aún existe en nuestra lista (pudo haber sido removido)
    if (!_connectedDevices.containsKey(deviceState.deviceId)) return;

    try {
      debugPrint("🔄 [${deviceState.deviceId}] Buscando dispositivo...");
      await deviceState.device.connect(
        license: License.free,
        autoConnect: false,
        timeout: const Duration(seconds: 4),
      );
    } catch (e) {
      if (!deviceState.intentionalDisconnect && _connectedDevices.containsKey(deviceState.deviceId)) {
        debugPrint("⏳ [${deviceState.deviceId}] Dispositivo no encontrado o reiniciando... reintentando en 1s.");
        Future.delayed(Duration(seconds: 1), () => _reconnectLoop(deviceState));
      }
    }
  }

  /// Lógica de Servicios y Suscripciones (MTU, Notify)
  Future<void> _negotiateConnection(_BLEDeviceState deviceState) async {
    deviceState.isNegotiating = true;
    final device = deviceState.device;
    final deviceId = deviceState.deviceId;

    try {
      List<BluetoothService> services = await device.discoverServices();

      BluetoothCharacteristic? dataChar;

      try {
        final service = services.firstWhere((s) => s.uuid == AppConstants.dataServiceUUID);
        dataChar = service.characteristics.firstWhere((c) => c.uuid == AppConstants.charDataUUID);
      } catch (e) {
        debugPrint("⛔ [$deviceId] Servicio/Característica no encontrados. Abortando persistencia.");
        disconnectDevice(deviceId);
        return;
      }

      if (dataChar.properties.notify) {
        if (!dataChar.isNotifying) {
          await dataChar.setNotifyValue(true);
        }

        deviceState.valueChangedSubscription?.cancel();
        deviceState.valueChangedSubscription = dataChar.onValueReceived.listen((value) {
          if (value.length >= Protocol.dataHeaderSize) {
            // Use new processPacket method that handles packet routing
            processPacket(Uint8List.fromList(value));
          }
        });
        debugPrint('✅ [$deviceId] Flujo de datos activo.');
      }

    } catch (e) {
      debugPrint("❌ [$deviceId] Error negociación: $e. Reiniciando conexión...");
      device.disconnect();
    } finally {
      deviceState.isNegotiating = false;
    }
  }

  /// 🛑 Desconecta un dispositivo específico por su ID
  Future<void> disconnectDevice(String deviceId) async {
    final deviceState = _connectedDevices[deviceId];
    if (deviceState == null) {
      debugPrint("⚠️ Dispositivo $deviceId no encontrado en la lista de conexiones.");
      return;
    }

    deviceState.intentionalDisconnect = true;
    debugPrint('🛑 [$deviceId] Solicitud de desconexión manual.');
    
    deviceState.cleanup();
    _connectedDevices.remove(deviceId);
    
    await _persistDevices();
    
    await deviceState.device.disconnect();
  }

  /// 🛑 Desconecta todos los dispositivos
  Future<void> disconnectAll() async {
    debugPrint('🛑 Desconectando todos los dispositivos BLE...');
    
    final deviceIds = _connectedDevices.keys.toList();
    for (final deviceId in deviceIds) {
      await disconnectDevice(deviceId);
    }
  }

  /// Alias for backwards compatibility - disconnects all devices
  Future<void> disconnect() async {
    await disconnectAll();
  }

  Future<void> _persistDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = _connectedDevices.keys.toList();
    await prefs.setString(_prefConnectedDeviceIds, jsonEncode(ids));
  }

  @override
  Future<void> stop() async {
    for (final deviceState in _connectedDevices.values) {
      deviceState.cleanup();
    }
    _connectedDevices.clear();
    super.stop();
  }
}