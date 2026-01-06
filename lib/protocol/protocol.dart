import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/sensor_packet.dart';
import '../models/sensor_metadata.dart';
import '../services/metadata_storage_service.dart';

class _SyncState {
  // Inicializamos con el máximo entero posible (simulando infinito)
  int minOffset = 9223372036854775807;
  int lastSensorTimestamp = -1;
}

abstract class Protocol extends ChangeNotifier {
  static const double scalar = 100.0;
  
  // --- Packet Type Identifiers (must match ESP32 values) ---
  static const int packetTypeMetadata = 0x00;
  static const int packetTypeData     = 0x01;
  static const int packetTypeAck      = 0x02;

  // --- Header Sizes ---
  static const int dataHeaderSize = 15;     // MAC(6) + Type(1) + Timestamp(8)
  static const int metadataHeaderSize = 18; // MAC(6) + Type(1) + Freq(2) + Samples(2) + Dims(1) + Name(6)
  static const int legacyHeaderSize = 25;   // Old format for backwards compatibility

  late String type;

  final int port = int.parse(dotenv.env['PORT']!);
  dynamic server;
  late SensorPacket currentPacket;

  final Map<String, _SyncState> _sensorSyncStates = {};
  
  // Reference to metadata storage
  final MetadataStorageService _metadataStorage = MetadataStorageService();

  final connectionController = StreamController<String>.broadcast();
  Stream<String> get onClientConnected => connectionController.stream;
  
  // Stream for metadata updates
  final metadataController = StreamController<SensorMetadata>.broadcast();
  Stream<SensorMetadata> get onMetadataReceived => metadataController.stream;

  Protocol(this.type);

  /// Maneja la conexión
  void handleConnection(dynamic event);

  // Inicia el servidor para escuchar conexiones entrantes
  Future<void> start() async {
    // Initialize metadata storage
    await _metadataStorage.initialize();
    
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

  /// Determines packet type and routes to appropriate decoder
  void processPacket(Uint8List bytes, {InternetAddress? senderAddress, int? senderPort}) {
    if (bytes.length < 7) {
      debugPrint('⚠️ Paquete descartado: Tamaño insuficiente (${bytes.length} bytes)');
      return;
    }

    // Read packet type at offset 6 (after MAC address)
    final int packetType = bytes[6];

    switch (packetType) {
      case packetTypeMetadata:
        _decodeMetadataPacket(bytes, senderAddress: senderAddress, senderPort: senderPort);
        break;
      case packetTypeData:
        _decodeDataPacket(bytes);
        break;
      default:
        // Try legacy format (for backwards compatibility)
        debugPrint('⚠️ Tipo de paquete desconocido ($packetType), intentando formato legacy...');
        decodePacket(bytes);
    }
  }

  /// Decodes a metadata packet and stores/updates the sensor metadata
  void _decodeMetadataPacket(Uint8List bytes, {InternetAddress? senderAddress, int? senderPort}) {
    if (bytes.length < metadataHeaderSize) {
      debugPrint('⚠️ Metadata packet too small: ${bytes.length} bytes');
      return;
    }

    final buffer = ByteData.sublistView(bytes);
    int offset = 0;

    // MAC Address (6 bytes)
    final macBytes = bytes.sublist(offset, offset + 6);
    String macAddress = macBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
    offset += 6;

    // Packet Type (1 byte) - already verified
    offset += 1;

    // Frequency (Int16)
    int freq = buffer.getInt16(offset, Endian.little);
    offset += 2;

    // Samples per packet (Int16)
    int samplesPerPacket = buffer.getInt16(offset, Endian.little);
    offset += 2;

    // Dimensions (Int8)
    int dimensions = buffer.getInt8(offset);
    offset += 1;

    // Sensor Name (6 chars)
    String sensorId = String.fromCharCodes(bytes.sublist(offset, offset + 6)).trim();
    offset += 6;

    // Calculate expected remaining size
    // Labels(dims*4) + Units(dims*4) + MinSignals(dims*4) + MaxSignals(dims*4)
    int expectedRemainingSize = dimensions * 4 * 4;
    if (bytes.length < metadataHeaderSize + expectedRemainingSize) {
      debugPrint('⚠️ Metadata packet incomplete: expected ${metadataHeaderSize + expectedRemainingSize}, got ${bytes.length}');
      return;
    }

    // Labels (4 chars per dimension)
    List<String> labels = [];
    for (int d = 0; d < dimensions; d++) {
      labels.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)).trim());
      offset += 4;
    }

    // Units (4 chars per dimension)
    List<String> units = [];
    for (int d = 0; d < dimensions; d++) {
      units.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)).trim());
      offset += 4;
    }

    // Min Signals (float32 per dimension)
    List<double> minSignals = [];
    for (int d = 0; d < dimensions; d++) {
      minSignals.add(buffer.getFloat32(offset, Endian.little));
      offset += 4;
    }

    // Max Signals (float32 per dimension)
    List<double> maxSignals = [];
    for (int d = 0; d < dimensions; d++) {
      maxSignals.add(buffer.getFloat32(offset, Endian.little));
      offset += 4;
    }

    // Create metadata object
    final metadata = SensorMetadata(
      macAddress: macAddress,
      sensorId: sensorId,
      frequency: freq,
      samplesPerPacket: samplesPerPacket,
      dimensions: dimensions,
      labels: labels,
      units: units,
      minSignals: minSignals,
      maxSignals: maxSignals,
    );

    // Store/update metadata
    _metadataStorage.storeMetadata(metadata);

    // Notify listeners
    metadataController.add(metadata);
    connectionController.add(macAddress);

    debugPrint('📦 [$type] Metadata received: $metadata');

    // Send ACK for UDP
    if (type == "UDP" && senderAddress != null && senderPort != null) {
      _sendAck(macAddress, senderAddress, senderPort);
    }
  }

  /// Sends an ACK packet back to the sender (UDP only)
  void _sendAck(String macAddress, InternetAddress address, int port) {
    // Build ACK packet: MAC(6) + Type(1)
    final ackBuffer = Uint8List(7);
    
    // Copy MAC address
    final macParts = macAddress.split(':');
    for (int i = 0; i < 6; i++) {
      ackBuffer[i] = int.parse(macParts[i], radix: 16);
    }
    
    // Set packet type
    ackBuffer[6] = packetTypeAck;

    // Send ACK
    if (server is RawDatagramSocket) {
      (server as RawDatagramSocket).send(ackBuffer, address, port);
      debugPrint('✅ [$type] ACK sent to $address:$port for $macAddress');
    }
  }

  /// Decodes a data-only packet (requires metadata to be already stored)
  void _decodeDataPacket(Uint8List bytes) {
    if (bytes.length < dataHeaderSize) {
      debugPrint('⚠️ Data packet too small: ${bytes.length} bytes');
      return;
    }

    final buffer = ByteData.sublistView(bytes);
    int offset = 0;

    final int mobileArrivalUs = DateTime.now().microsecondsSinceEpoch;

    // MAC Address (6 bytes)
    final macBytes = bytes.sublist(offset, offset + 6);
    String macAddress = macBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
    offset += 6;

    // Packet Type (1 byte) - already verified
    offset += 1;

    // Timestamp Base (Int64)
    int tsSensorBaseUs = buffer.getInt64(offset, Endian.little);
    offset += 8;

    // Get metadata for this sensor
    final metadata = _metadataStorage.getMetadata(macAddress);
    if (metadata == null) {
      debugPrint('⚠️ [$type] No metadata for $macAddress - dropping data packet');
      return;
    }

    final int nSamples = metadata.samplesPerPacket;
    final int mDims = metadata.dimensions;
    final int freq = metadata.frequency;

    // Verify packet has enough data
    int expectedDataSize = nSamples * mDims * 2;
    if (bytes.length < dataHeaderSize + expectedDataSize) {
      debugPrint('⚠️ Data packet incomplete: expected ${dataHeaderSize + expectedDataSize}, got ${bytes.length}');
      return;
    }

    double intervalUs = 1000000.0 / freq;
    double bufferDurationUs = (nSamples - 1) * intervalUs;
    int tsSensorLastSampleUs = tsSensorBaseUs + bufferDurationUs.round();

    int bestOffset = _calculateBestOffset(macAddress, tsSensorLastSampleUs, mobileArrivalUs);

    List<List<dynamic>> reconstructedData = [];

    for (int i = 0; i < nSamples; i++) {
      List<double> values = [];

      for (int j = 0; j < mDims; j++) {
        int rawVal = buffer.getInt16(offset, Endian.little);
        offset += 2;
        values.add(rawVal / scalar);
      }

      int sensorSampleTs = tsSensorBaseUs + (i * intervalUs).round();
      int synchronizedTs = sensorSampleTs + bestOffset;

      reconstructedData.add([values, synchronizedTs]);
    }

    currentPacket = SensorPacket(
      sensorId: metadata.sensorId,
      macAddress: macAddress,
      data: reconstructedData.map((data) => MetricData(
        values: data[0],
        timestamp: DateTime.fromMicrosecondsSinceEpoch(data[1]),
      )).toList(),
      bufferSize: nSamples,
      f: freq,
      labels: metadata.labels,
      units: metadata.units,
    );
    
    notifyListeners();
    debugPrint('✅ [$type] Data Packet: ${currentPacket.macAddress} [${currentPacket.data.length} samples]');
  }

  /// Legacy decoder for backwards compatibility
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
    debugPrint('✅ [$type] Legacy Packet: ${currentPacket.sensorId} [${currentPacket.data.length} samples]');
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

  /// Retrieve stored metadata for a MAC address
  SensorMetadata? getMetadataForMac(String macAddress) {
    return _metadataStorage.getMetadata(macAddress);
  }

  /// Check if we have metadata for a sensor
  bool hasMetadataForMac(String macAddress) {
    return _metadataStorage.hasMetadata(macAddress);
  }

  /// Cierra el servidor
  Future<void> stop() async {
    server?.close();
    connectionController.close();
    metadataController.close();
    debugPrint('Servidor $type detenido');
  }
}