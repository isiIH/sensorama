import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// ---------------------------------------------------------------------------
// MODELOS DE DATOS
// ---------------------------------------------------------------------------

class MetricData {
  final List<double> values;
  final DateTime timestamp;

  MetricData({
    required this.values,
    required this.timestamp,
  });
}

class SensorPacket {
  final String sensorId;
  final String macAddress;
  final List<MetricData> data;
  final int bufferSize;
  final int f;
  final List<String> labels;
  final List<String> units;

  SensorPacket({
    required this.sensorId,
    required this.macAddress,
    required this.data,
    required this.bufferSize,
    required this.f,
    required this.labels,
    required this.units
  });
}

abstract class Protocol extends ChangeNotifier {
  static const double scalar = 100.0;
  static const int headerSize = 25;

  late String type;

  final int port = int.parse(dotenv.env['PORT']!);
  dynamic server;
  // final ListQueue<SensorPacket> packets = ListQueue();
  late SensorPacket currentPacket;

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
        values.add(rawVal / scalar);
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

  /// Cierra el servidor
  Future<void> stop() async {
    server?.close();
    connectionController.close();
    debugPrint('Servidor $type detenido');
  }
}