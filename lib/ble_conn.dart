import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'sensor_config.dart'; // Asegúrate de que esto apunta a tu modelo de datos

class BLEConn extends ChangeNotifier {
  static final BLEConn _instance = BLEConn._internal();

  factory BLEConn() {
    return _instance;
  }

  BLEConn._internal();

  BluetoothDevice? _targetDevice;
  BluetoothCharacteristic? _dataCharacteristic;
  StreamSubscription? _valueChangedSubscription;
  StreamSubscription? _connectionStateSubscription;

  // UUIDs - Deben coincidir con la config del ESP32
  final Guid serviceUUID = Guid("e0277977-85ca-4ea2-8b83-82a1789c1048");
  final Guid charDataUUID = Guid("beb5483f-36e1-4688-b7f5-ea07361b26a9");

  // Lista de paquetes procesados listos para la UI
  final List<SensorPacket> packets = [];

  // Constantes de decodificación
  static const double _scalar = 100.0;
  static const int _headerSize = 25;

  // StreamController para notificar conexiones a la UI
  final _connectionController = StreamController<BluetoothDevice>.broadcast();
  Stream<BluetoothDevice> get onClientConnected => _connectionController.stream;

  // Control de estado
  bool _intentionalDisconnect = false;
  bool _isNegotiating = false;

  /// 🚀 Punto de entrada: Comienza el ciclo de conexión persistente hacia una MAC específica.
  /// No importa si el dispositivo se está reiniciando, este método lo buscará hasta encontrarlo.
  Future<void> startMonitoring(BluetoothDevice device) async {
    _intentionalDisconnect = false;
    _targetDevice = device;
    
    // Limpiamos subscripciones previas por seguridad
    _cleanupSubscriptions();

    print("🏁 Iniciando monitoreo BLE para: ${device.remoteId} (${device.platformName})");

    // Escuchamos el estado de la conexión globalmente para este dispositivo
    _connectionStateSubscription = device.connectionState.listen((BluetoothConnectionState state) {
      if (state == BluetoothConnectionState.connected) {
        if (!_isNegotiating) {
           print("✅ Dispositivo conectado a nivel físico. Iniciando negociación lógica...");
           _negotiateConnection(device);
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        if (!_intentionalDisconnect) {
          print("⚠️ Desconexión detectada (¿Reinicio de ESP32?). Iniciando reconexión...");
          _reconnectLoop(device);
        } else {
          print("ℹ️ Desconexión intencional completada.");
        }
      }
    });

    // Intentamos conectar inmediatamente (o entrar en el loop de reconexión si se está reiniciando)
    _reconnectLoop(device);
  }

  /// Bucle recursivo que intenta conectar con el dispositivo específico
  void _reconnectLoop(BluetoothDevice device) async {
    if (_intentionalDisconnect || device.isConnected) return;

    try {
      print("🔄 Buscando dispositivo ${device.remoteId}...");
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
        print("⏳ Dispositivo no encontrado o reiniciando... reintentando en 1s.");
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
          print("⚡ MTU solicitado. Actual: ${await device.mtu.first}");
        } catch (e) {
          print("⚠️ Advertencia MTU: $e");
        }
      }

      // 2. Descubrir Servicios
      print("🔍 Descubriendo servicios...");
      List<BluetoothService> services = await device.discoverServices();
      BluetoothService? targetService;
      
      // Buscamos el servicio específico
      for (final s in services) {
        if (s.uuid == serviceUUID) {
          targetService = s;
          break;
        }
      }

      if (targetService == null) {
        // Si conectamos, pero no tiene el servicio de datos, es porque
        // la placa reinició en modo Aprovisionamiento.
        print("⛔ Dispositivo en modo incorrecto (¿Aprovisionamiento?). Abortando persistencia.");
        
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
        if (c.uuid == charDataUUID) {
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
           if (value.isNotEmpty) _handleBLEData(Uint8List.fromList(value));
        });
        
        print('✅ Notificaciones activas. Recibiendo datos...');
      }

      // Notificar a la UI que estamos listos
      _connectionController.add(device);

    } catch (e) {
      print("❌ Error durante negociación ($e). Reintentando conexión completa...");
      // Si falla la negociación, desconectamos para forzar el ciclo de reconexión limpio
      device.disconnect(); 
    } finally {
      _isNegotiating = false;
    }
  }

  /// 📥 Procesa datos recibidos (Lógica de negocio original)
  void _handleBLEData(Uint8List data) {
    try {
      if (data.length < _headerSize) return;
      _decodePacket(data);
    } catch (e) {
      print('❌ Error decodificando: $e');
    }
  }

  void _decodePacket(Uint8List bytes) {
    try {
        // 1. Reconstruir el Mapa JSON idéntico al original
        final Map<String, dynamic> reconstructedJson = _reconstructJsonMap(bytes);
        
        // 2. Crear el objeto SensorPacket usando el factory existente
        final newPacket = SensorPacket.fromJson(reconstructedJson);
        packets.add(newPacket);

        notifyListeners();
        
        // Log ligero para no saturar consola
        // print('✅ Packet: ${newPacket.sensorId} [${newPacket.data.length} samples]');
      } catch (e) {
        print('❌ Error decodificando binario: $e');
      }
  }

  Map<String, dynamic> _reconstructJsonMap(Uint8List bytes) {
    final buffer = ByteData.sublistView(bytes);
    int offset = 0;

    // --- 1. HEADER ---
    // MAC (6 bytes) - Convertimos a String "XX:XX:XX:XX:XX:XX"
    final macBytes = bytes.sublist(offset, offset + 6);
    String macAddress = macBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
    offset += 6;

    // Freq (Int16)
    int freq = buffer.getInt16(offset, Endian.little);
    offset += 2;

    // N Samples (Int16)
    int nSamples = buffer.getInt16(offset, Endian.little);
    offset += 2;

    // M Dims (Int8)
    int mDims = buffer.getInt8(offset);
    offset += 1;

    // Timestamp Base (Int32) - Viene en ms desde el C++
    int tsBaseUs = buffer.getInt64(offset, Endian.little);
    offset += 8;

    // Sensor Name (Char[6])
    String sensorId = String.fromCharCodes(bytes.sublist(offset, offset + 6)).trim();
    offset += 6;

    // --- 2. DATA ---
    // Reconstruimos la lista: [ [[val], ts], ... ]
    // Calculamos el intervalo en microsegundos para interpolar el tiempo
    // Intervalo = 1,000,000 us / Freq
    double intervalUs = 1000000.0 / freq;

    List<List<dynamic>> reconstructedData = [];

    for (int i = 0; i < nSamples; i++) {
      List<double> values = [];
      
      // Leemos las dimensiones (m) de esta muestra
      for (int j = 0; j < mDims; j++) {
        int rawVal = buffer.getInt16(offset, Endian.little);
        offset += 2;
        // Aplicamos el factor inverso (División)
        values.add(rawVal / _scalar);
      }

      // Calculamos el timestamp interpolado para esta muestra
      // TS = Base + (i * intervalo)
      int sampleTs = tsBaseUs + (i * intervalUs).round();

      // Estructura original: [[val], timestamp]
      // Nota: values es una lista [val], sampleTs es int
      reconstructedData.add([values, sampleTs]);
    }

    // --- 3. METADATA ---
    List<String> labels = [];
    for (int j = 0; j < mDims; j++) {
      labels.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)).trim());
      offset += 4;
    }

    List<String> units = [];
    for (int j = 0; j < mDims; j++) {
      units.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)).trim());
      offset += 4;
    }

    // --- 4. CONSTRUCCIÓN DEL MAPA FINAL ---
    return {
      "mac_address": macAddress,
      "sensor_id": sensorId,
      "bufferSize": nSamples, // Originalmente bufferSize
      "data": reconstructedData,
      "metadata": {
        "f": freq,
        "labels": labels,
        "units": units
      }
    };
  }

  /// 🛑 Detiene todo y desconecta
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    print('🛑 Solicitud de desconexión manual.');
    
    _cleanupSubscriptions();
    
    if (_targetDevice != null) {
      await _targetDevice!.disconnect();
    }
  }
  
  void _cleanupSubscriptions() {
    _valueChangedSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    if (_dataCharacteristic != null) {
       // Opcional: intentar deshabilitar notificaciones antes de cerrar
    }
  }

  void stop() {
    disconnect();
    packets.clear();
    notifyListeners();
    // No cerramos _connectionController aquí si queremos reusar el singleton, 
    // pero si la app muere, sí.
  }

  bool isConnected() => _targetDevice?.isConnected ?? false;
  String? getConnectedDeviceName() => _targetDevice?.platformName;
}