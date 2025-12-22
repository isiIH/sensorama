import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'sensor_config.dart'; // Asegúrate de que este archivo exista con tu modelo SensorPacket

Future<String?> getLocalIpAddress() async {
  final info = NetworkInfo();
  return await info.getWifiIP();
}

class _SyncState {
  // Inicializamos con el máximo entero posible (simulando infinito)
  int minOffset = 9223372036854775807; 
  int lastSensorTimestamp = -1;
}

class TCPConn extends ChangeNotifier {
  static final TCPConn _instance = TCPConn._internal();

  factory TCPConn() {
    return _instance;
  }

  TCPConn._internal();

  final int _port = int.parse(dotenv.env['PORT'] ?? '8080');
  ServerSocket? _server;
  final List<Socket> _clients = [];
  final Map<String, _SyncState> _sensorSyncStates = {};
  
  // Lista de paquetes procesados listos para la UI
  final List<SensorPacket> packets = [];

  // Constantes de decodificación
  static const double _scalar = 100.0;
  // Tamaño fijo del encabezado según tu protocolo C++ (Header struct)
  static const int _headerSize = 25; 
  
  // StreamController para notificar conexiones a la UI
  final _connectionController = StreamController<Socket>.broadcast();
  Stream<Socket> get onClientConnected => _connectionController.stream;

  /// 🔌 Inicia el servidor TCP
  Future<void> start() async {
    try {
      String? ipAddress = await getLocalIpAddress();
      print(ipAddress != null ? 'IP Local: $ipAddress' : 'No se detectó IP');

      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      print('🚀 Servidor TCP (Modo Buffer) iniciado en puerto $_port');

      _server!.listen(_handleNewConnection);
    } catch (e) {
      print('❌ Error iniciando servidor TCP: $e');
    }
  }

  /// Maneja una nueva conexión y gestiona el buffer de flujo
  void _handleNewConnection(Socket client) {
    _clients.add(client);
    _connectionController.add(client);
    print('Sensor conectado: ${client.remoteAddress.address}:${client.remotePort}');

    // BUFFER ACUMULATIVO POR CLIENTE
    // Usamos BytesBuilder para ir pegando los fragmentos TCP
    final BytesBuilder _socketBuffer = BytesBuilder();

    client.listen(
      (Uint8List data) {
        // 1. Agregar fragmento recibido al buffer acumulativo
        _socketBuffer.add(data);

        // 2. Intentar procesar todos los paquetes completos que haya en el buffer
        _processBuffer(_socketBuffer);
      },
      onError: (e) {
        print('Error conexión TCP: $e');
        _removeClient(client);
      },
      onDone: () {
        print('Sensor desconectado.');
        _removeClient(client);
      },
    );
  }

  /// Intenta extraer paquetes completos del buffer acumulado
  void _processBuffer(BytesBuilder buffer) {
    // Mientras tengamos al menos el tamaño de un header, intentamos leer
    while (buffer.length >= _headerSize) {
      // Hacemos un "peek" (mirar sin borrar) del header para calcular el tamaño total esperado.
      // Convertimos temporalmente a Uint8List para usar ByteData (costoso pero necesario sin punteros)
      Uint8List currentBytes = buffer.toBytes(); 
      final headerView = ByteData.sublistView(currentBytes, 0, _headerSize);

      // Leemos n_samples (offset 8) y m_dims (offset 10) según tu struct C++
      // Offset Map:
      // MAC: 0-5 (6 bytes)
      // Freq: 6-7 (2 bytes)
      // N Samples: 8-9 (2 bytes) <-- AQUÍ
      // M Dims: 10 (1 byte) <-- AQUÍ
      
      int nSamples = headerView.getInt16(8, Endian.little);
      int mDims = headerView.getInt8(10);

      // Calculamos el tamaño total que DEBERÍA tener el paquete
      // Header (21) + Data (nSamples * mDims * 2) + Labels (mDims * 4) + Units (mDims * 4)
      int dataSize = nSamples * mDims * 2;
      int metaSize = (mDims * 4) + (mDims * 4);
      int totalPacketSize = _headerSize + dataSize + metaSize;

      // VERIFICACIÓN: ¿Tenemos el paquete completo en el buffer?
      if (buffer.length >= totalPacketSize) {
        // SI: Extraemos exactamente esos bytes
        Uint8List packetBytes = currentBytes.sublist(0, totalPacketSize);
        
        // Procesamos el paquete
        _decodePacket(packetBytes, nSamples, mDims);

        // REMOVEMOS el paquete procesado del buffer
        // BytesBuilder no tiene "removeFirst", así que reconstruimos con el sobrante.
        // Esto es un poco costoso en CPU pero seguro en memoria.
        Uint8List remaining = currentBytes.sublist(totalPacketSize);
        buffer.clear();
        buffer.add(remaining);
      } else {
        // NO: No ha llegado el paquete completo (fragmentación TCP).
        // Salimos del while y esperamos al siguiente evento de red.
        break; 
      }
    }
  }

  /// Decodifica un paquete binario VALIDADO y COMPLETO
  /// Decodifica un paquete binario VALIDADO y COMPLETO
  void _decodePacket(Uint8List bytes, int nSamples, int mDims) {
    try {
      final int mobileArrivalUs = DateTime.now().microsecondsSinceEpoch;

      final buffer = ByteData.sublistView(bytes);
      int readPtr = 0;

      // --- 1. HEADER ---
      // MAC (6)
      final macBytes = bytes.sublist(readPtr, readPtr + 6);
      String macAddress = macBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(':');
      readPtr += 6; 
      
      // Freq (2)
      int freq = buffer.getInt16(readPtr, Endian.little);
      readPtr += 2;
      
      // N Samples (2)
      readPtr += 2;
      
      // M Dims (1)
      readPtr += 1;
      
      // Timestamp Base (8) -> TIEMPO DE LA PRIMERA MUESTRA
      int tsSensorBaseUs = buffer.getInt64(readPtr, Endian.little);
      readPtr += 8;
      
      // Sensor Name (6)
      String sensorId = String.fromCharCodes(bytes.sublist(readPtr, readPtr + 6)).trim();
      readPtr += 6;

      // ---------------------------------------------------------
      // CORRECCIÓN CRÍTICA DE SINCRONIZACIÓN TCP
      // ---------------------------------------------------------
      double intervalUs = 1000000.0 / freq;
      
      // Calculamos cuándo ocurrió la ÚLTIMA muestra del paquete
      // (asumiendo que nSamples > 0)
      double bufferDurationUs = (nSamples - 1) * intervalUs;
      int tsSensorLastSampleUs = tsSensorBaseUs + bufferDurationUs.round();

      // Calculamos el offset comparando:
      // AHORA (Móvil) vs MOMENTO QUE SE COMPLETÓ EL BUFFER (Sensor)
      int bestOffset = _calculateBestOffset(macAddress, tsSensorLastSampleUs, mobileArrivalUs);
      // ---------------------------------------------------------

      // --- 2. DATA ---
      List<List<dynamic>> reconstructedData = [];

      for (int i = 0; i < nSamples; i++) {
        List<double> values = [];
        for (int j = 0; j < mDims; j++) {
          int rawVal = buffer.getInt16(readPtr, Endian.little);
          readPtr += 2;
          values.add(rawVal / _scalar);
        }
        
        // Reconstrucción local de tiempos:
        // Usamos la Base para iterar, PERO le sumamos el offset corregido.
        int sensorSampleTs = tsSensorBaseUs + (i * intervalUs).round();
        
        // Al aplicar el offset calculado con el final del paquete, 
        // automáticamente restamos el tiempo de buffering.
        int synchronizedTs = sensorSampleTs + bestOffset;
        
        reconstructedData.add([values, synchronizedTs]);
      }

      // --- 3. METADATA ---
      List<String> labels = [];
      for (int j = 0; j < mDims; j++) {
        labels.add(String.fromCharCodes(bytes.sublist(readPtr, readPtr + 4)).trim());
        readPtr += 4;
      }

      List<String> units = [];
      for (int j = 0; j < mDims; j++) {
        units.add(String.fromCharCodes(bytes.sublist(readPtr, readPtr + 4)).trim());
        readPtr += 4;
      }

      // Crear objeto y notificar
      Map<String, dynamic> jsonMap = {
        "sensor_id": sensorId,
        "bufferSize": nSamples,
        "data": reconstructedData,
        "metadata": {
          "f": freq,
          "labels": labels,
          "units": units
        }
      };

      SensorPacket packet = SensorPacket.fromJson(jsonMap);
      packets.add(packet);
      notifyListeners();

    } catch (e) {
      print('❌ Error lógico decodificando paquete TCP: $e');
    }
  }
  
  int _calculateBestOffset(String mac, int sensorTs, int mobileTs) {
    // Inicializar estado si es la primera vez que vemos este sensor
    _sensorSyncStates.putIfAbsent(mac, () => _SyncState());
    final state = _sensorSyncStates[mac]!;

    // 1. DETECCIÓN DE REINICIO
    // Si el tiempo del sensor viajó al pasado, el ESP32 se reinició.
    if (sensorTs < state.lastSensorTimestamp) {
      print("⚠️ Reinicio detectado en $mac. Reseteando sincronización.");
      state.minOffset = 9223372036854775807; // Reset a infinito
    }
    state.lastSensorTimestamp = sensorTs;

    // 2. CÁLCULO DE OFFSET CANDIDATO
    // Offset = TiempoMóvil - TiempoSensor
    // Representa: "Qué diferencia hay entre relojes + latencia actual"
    int candidateOffset = mobileTs - sensorTs;

    // 3. ACTUALIZACIÓN DEL MEJOR OFFSET (Convex Hull)
    // Solo actualizamos si encontramos un offset MENOR al actual.
    // Un offset menor significa que el paquete llegó más rápido (menos latencia de red).
    if (candidateOffset < state.minOffset) {
      state.minOffset = candidateOffset;
      // Opcional: Debug para ver convergencia
      // print("🚀 Sincronización mejorada para $mac. Offset: ${state.minOffset}");
    }

    return state.minOffset;
  }

  void _removeClient(Socket client) {
    _clients.remove(client);
    client.destroy();
  }

  void stop() {
    _server?.close();
    packets.clear();
    notifyListeners();
    for (var client in _clients) {
      client.destroy();
    }
    _clients.clear();
    _connectionController.close();
    print('🚪 Servidor TCP cerrado.');
  }
}