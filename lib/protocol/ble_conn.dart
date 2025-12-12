import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/constants.dart';
import 'protocol.dart';

class BLEConn extends Protocol {
  static final BLEConn _instance = BLEConn._internal();

  factory BLEConn() {
    return _instance;
  }

  BLEConn._internal()  : super('BLE');

  late BluetoothDevice _targetDevice;
  BluetoothCharacteristic? _dataCharacteristic;
  StreamSubscription? _valueChangedSubscription;
  StreamSubscription? _connectionStateSubscription;

  // Control de estado
  bool _intentionalDisconnect = false;
  bool _isNegotiating = false;

  /// 🚀 Punto de entrada: Comienza el ciclo de conexión persistente hacia una MAC específica.
  /// No importa si el dispositivo se está reiniciando, este método lo buscará hasta encontrarlo.
  @override
  void handleConnection(dynamic event) {
    _intentionalDisconnect = false;
    _targetDevice = event;
    
    // Limpiamos subscripciones previas por seguridad
    _cleanupSubscriptions();

    debugPrint("🏁 Iniciando monitoreo BLE para: ${_targetDevice.remoteId} (${_targetDevice.platformName})");

    // Escuchamos el estado de la conexión globalmente para este dispositivo
    _connectionStateSubscription = _targetDevice.connectionState.listen((BluetoothConnectionState state) {
      if (state == BluetoothConnectionState.connected) {
        if (!_isNegotiating) {
          debugPrint("✅ Dispositivo conectado a nivel físico. Iniciando negociación lógica...");
           _negotiateConnection(_targetDevice);
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        if (!_intentionalDisconnect) {
          debugPrint("⚠️ Desconexión detectada (¿Reinicio de ESP32?). Iniciando reconexión...");
          _reconnectLoop(_targetDevice);
        } else {
          debugPrint("ℹ️ Desconexión intencional completada.");
        }
      }
    });

    // Intentamos conectar inmediatamente (o entrar en el loop de reconexión si se está reiniciando)
    _reconnectLoop(_targetDevice);
  }

  /// Bucle recursivo que intenta conectar con el dispositivo específico
  void _reconnectLoop(BluetoothDevice device) async {
    if (_intentionalDisconnect || device.isConnected) return;

    try {
      debugPrint("🔄 Buscando dispositivo ${device.remoteId}...");
      // Intentamos conectar.
      // timeout: le da tiempo al ESP32 de arrancar.
      // autoConnect: false para que falle (timeout) si no está y podamos reintentar la lógica manualmente.
      await device.connect(
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
        Future.delayed(Duration(seconds: 1), () => _reconnectLoop(device));
      }
    }
  } 

  /// Lógica crítica: MTU, Servicios y Suscripciones
  Future<void> _negotiateConnection(BluetoothDevice device) async {
    _isNegotiating = true;
    try {
      // 1. Negociación MTU (Crítico para velocidad)
      if (Platform.isAndroid) {
        try {
          // Solicitamos 512, Android negociará lo máximo posible (ej. 512 o 247)
          await Future.delayed(Duration(milliseconds: 3000)); // Pequeña pausa para estabilizar
          await device.requestMtu(512);
          debugPrint("⚡ MTU solicitado. Actual: ${await device.mtu.first}");
        } catch (e) {
          debugPrint("⚠️ Advertencia MTU: $e");
        }
      }

      // 2. Descubrir Servicios
      debugPrint("🔍 Descubriendo servicios...");
      List<BluetoothService> services = await device.discoverServices();
      BluetoothService? targetService;
      
      // Buscamos el servicio específico
      for (final s in services) {
        if (s.uuid == AppConstants.dataServiceUUID) {
          targetService = s;
          break;
        }
      }

      if (targetService == null) {
        // Si conectamos, pero no tiene el servicio de datos, es porque
        // la placa reinició en modo Aprovisionamiento.
        debugPrint("⛔ Dispositivo en modo incorrecto (¿Aprovisionamiento?). Abortando persistencia.");
        
        // Marcamos desconexión intencional para que el listener NO reinicie el loop
        _intentionalDisconnect = true; 
        
        // Limpiamos todo
        stop(); 
        
        // Opcional: Lanzar error específico si necesitas notificar a la UI
        throw Exception("ABORT_PERSISTENCE: Modo incorrecto");
      }

      // 3. Obtener Característica
      _dataCharacteristic = null;
      for (final c in targetService.characteristics) {
        if (c.uuid == AppConstants.charDataUUID) {
          _dataCharacteristic = c;
          break;
        }
      }

      if (_dataCharacteristic == null) {
        throw Exception("Característica de datos no encontrada.");
      }

      // 4. Suscribirse a notificaciones
      if (_dataCharacteristic!.properties.notify) {
        if(!_dataCharacteristic!.isNotifying) {
             await _dataCharacteristic!.setNotifyValue(true);
        }
        
        // Reiniciamos la suscripción al stream de datos
        _valueChangedSubscription?.cancel();
        _valueChangedSubscription = _dataCharacteristic!.onValueReceived.listen((value) {
           if (value.isNotEmpty) {
             Uint8List data = Uint8List.fromList(value);
             if (data.length >= Protocol.headerSize) {
               decodePacket(Uint8List.fromList(value));
               connectionController.add(currentPacket.macAddress);
             }
           }
        });

        debugPrint('✅ Notificaciones activas. Recibiendo datos...');
      }

    } catch (e) {
      debugPrint("❌ Error durante negociación ($e). Reintentando conexión completa...");
      // Si falla la negociación, desconectamos para forzar el ciclo de reconexión limpio
      device.disconnect(); 
    } finally {
      _isNegotiating = false;
    }
  }

  /// 🛑 Detiene todo y desconecta
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    debugPrint('🛑 Solicitud de desconexión manual.');
    
    _cleanupSubscriptions();
    
    await _targetDevice.disconnect();
  }
  
  void _cleanupSubscriptions() {
    _valueChangedSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    if (_dataCharacteristic != null) {
       // Opcional: intentar deshabilitar notificaciones antes de cerrar
    }
  }

  @override
  Future<void> stop() async {
    super.stop();
    disconnect();
  }
}