import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'sensor_config.dart'; // Asumo que aquí está tu clase SensorPacket

class UDPConn extends ChangeNotifier {
  static final UDPConn _instance = UDPConn._internal();

  factory UDPConn() {
    return _instance;
  }

  UDPConn._internal();

  final int _port = int.parse(dotenv.env['PORT']!);
  RawDatagramSocket? _socket;
  final Map<String, dynamic> _activeClients = {};
  final List<SensorPacket> packets = [];

  // Constantes de decodificación (Deben coincidir con C++)
  static const double _scalar = 100.0;
  static const int _headerSize = 25;

  final _connectionController = StreamController<String>.broadcast();
  Stream<String> get onClientConnected => _connectionController.stream;

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port);
      debugPrint('🚀 Servidor UDP (Binario) iniciado en puerto $_port');
      _socket!.listen(_handleIncomingDatagram);
    } catch (e) {
      debugPrint('❌ Error al iniciar UDP: $e');
    }
  }

  void _handleIncomingDatagram(RawSocketEvent event) {
    if (_socket == null) return;

    try {
      final datagram = _socket!.receive();
      if (datagram == null) return;

      final data = datagram.data; // Esto es Uint8List
      final remoteAddress = datagram.address.address;
      final remotePort = datagram.port;

      _registerClient(remoteAddress, remotePort);

      // --- PROCESAMIENTO BINARIO ---
      if (data.length < _headerSize) {
        debugPrint('⚠️ Paquete descartado: Tamaño insuficiente (${data.length} bytes)');
        return;
      }

      try {
        // 1. Reconstruir el Mapa JSON idéntico al original
        final Map<String, dynamic> reconstructedJson = _reconstructJsonMap(data);

        // 2. Crear el objeto SensorPacket usando el factory existente
        final newPacket = SensorPacket.fromJson(reconstructedJson);
        packets.add(newPacket);
        notifyListeners();

        debugPrint('✅ Packet: ${newPacket.sensorId} [${newPacket.data.length} samples]');
      } catch (e) {
        debugPrint('❌ Error decodificando binario: $e');
      }

    } catch (e) {
      debugPrint('Error general UDP: $e');
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

  void _registerClient(String remoteAddress, int remotePort) {
    if (!_activeClients.containsKey(remoteAddress)) {
      _activeClients[remoteAddress] = {
        'port': remotePort,
        'lastSeen': DateTime.now(),
      };
      _connectionController.add(remoteAddress);
      debugPrint('Sensor conectado desde $remoteAddress:$remotePort');
    } else {
      _activeClients[remoteAddress]?['lastSeen'] = DateTime.now();
    }
  }

  void stop() {
    _socket?.close();
    packets.clear();
    _activeClients.clear();
    notifyListeners();
    _connectionController.close();
    debugPrint('🚪 Servidor UDP cerrado.');
  }
}