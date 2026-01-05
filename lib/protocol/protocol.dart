import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/sensor_packet.dart';

class _SyncState {
  // Inicializamos con el máximo entero posible (simulando infinito)
  int minOffset = 9223372036854775807;
  int lastSensorTimestamp = -1;
}

abstract class Protocol extends ChangeNotifier {
  static const double scalar = 100.0;
  static const int headerSize = 25;

  late String type;

  final int port = int.parse(dotenv.env['PORT']!);
  dynamic server;
  late SensorPacket currentPacket;

  final Map<String, _SyncState> _sensorSyncStates = {};

  final connectionController = StreamController<String>.broadcast();
  Stream<String> get onClientConnected => connectionController.stream;

  Protocol(this.type);

  /// Maneja la conexión
  void handleConnection(dynamic event);

  // Inicia el servidor para escuchar conexiones entrantes
  Future<void> start() async {
    // Si ya está corriendo, no hacer nada
    if (server != null) return;

    try {
      server = type == "TCP" ?
          await ServerSocket.bind(InternetAddress.anyIPv4, port)
      :   await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);

      debugPrint('Servidor $type iniciado en puerto $port');
      server!.listen(handleConnection);
    } catch (e) {
      debugPrint('Error al iniciar $type: $e');
    }
  }

  void decodePacket(Uint8List bytes) {
    final buffer = ByteData.sublistView(bytes);
    int offset = 0;

    final int mobileArrivalUs = DateTime.now().microsecondsSinceEpoch;

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
    int tsSensorBaseUs = buffer.getInt64(offset, Endian.little);
    offset += 8;

    // Sensor Name (Char[6])
    String sensorId = String.fromCharCodes(bytes.sublist(offset, offset + 6)).trim();
    offset += 6;

    double intervalUs = 1000000.0 / freq;
    double bufferDurationUs = (nSamples - 1) * intervalUs;
    int tsSensorLastSampleUs = tsSensorBaseUs + bufferDurationUs.round();

    int bestOffset = _calculateBestOffset(macAddress, tsSensorLastSampleUs, mobileArrivalUs);

    List<List<dynamic>> reconstructedData = [];

    for (int i = 0; i < nSamples; i++) {
      List<double> values = [];

      // Leemos las dimensiones (m) de esta muestra
      for (int j = 0; j < mDims; j++) {
        int rawVal = buffer.getInt16(offset, Endian.little);
        offset += 2;
        // Aplicamos el factor inverso (División)
        values.add(rawVal / scalar);
      }

      // Reconstrucción local de tiempos:
      // Usamos la Base para iterar, PERO le sumamos el offset corregido.
      int sensorSampleTs = tsSensorBaseUs + (i * intervalUs).round();

      // Al aplicar el offset calculado con el final del paquete,
      // automáticamente restamos el tiempo de buffering.
      int synchronizedTs = sensorSampleTs + bestOffset;

      // Estructura original: [[val], timestamp]
      // Nota: values es una lista [val], sampleTs es int
      reconstructedData.add([values, synchronizedTs]);
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

    currentPacket = SensorPacket(
      sensorId: sensorId,
      macAddress: macAddress,
      data: reconstructedData.map((data) => MetricData(
        values: data[0],
        timestamp: DateTime.fromMicrosecondsSinceEpoch(data[1]),
      )).toList(),
      bufferSize: nSamples,
      f: freq,
      labels: labels,
      units: units
    );
    notifyListeners();
    debugPrint('✅ [$type] Packet: ${currentPacket.sensorId} [${currentPacket.data.length} samples]');
  }

  int _calculateBestOffset(String mac, int sensorTs, int mobileTs) {
    // Inicializar estado si es la primera vez que vemos este sensor
    _sensorSyncStates.putIfAbsent(mac, () => _SyncState());
    final state = _sensorSyncStates[mac]!;

    // 1. DETECCIÓN DE REINICIO
    // Si el tiempo del sensor viajó al pasado, el ESP32 se reinició.
    if (sensorTs < state.lastSensorTimestamp) {
      debugPrint("⚠️ Reinicio detectado en $mac. Reseteando sincronización.");
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
      debugPrint("🚀 Sincronización mejorada para $mac. Offset: ${state.minOffset}");
    }

    return state.minOffset;
  }

  /// Cierra el servidor
  Future<void> stop() async {
    server?.close();
    connectionController.close();
    debugPrint('Servidor $type detenido');
  }
}