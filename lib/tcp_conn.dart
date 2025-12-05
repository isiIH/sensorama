import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:network_info_plus/network_info_plus.dart';
import 'sensor_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<String?> getLocalIpAddress() async {
  final info = NetworkInfo();
  final wifiIP = await info.getWifiIP();
  return wifiIP;
}

class TCPConn extends ChangeNotifier {
  static final TCPConn _instance = TCPConn._internal();

  factory TCPConn() {
    return _instance;
  }

  TCPConn._internal(); // Constructor privado

  final int _port = int.parse(dotenv.env['PORT']!);
  ServerSocket? _server;
  final Map<String, Socket> _activeClients = {};
  final List<SensorPacket> packets = [];

  // Constantes de decodificación
  static const double _scalar = 100.0;
  // Tamaño fijo del encabezado según tu protocolo C++ (Header struct)
  static const int _headerSize = 25;

  // StreamController para avisar a la UI
  final _connectionController = StreamController<Socket>.broadcast();
  // Exponemos el stream público
  Stream<Socket> get onClientConnected => _connectionController.stream;

  /// 🔌 Inicia el servidor para escuchar conexiones entrantes.
  Future<void> start() async {
    // Si ya está corriendo, no hacer nada
    if (_server != null) return;

    try {
      String? ipAddress = await getLocalIpAddress();
      debugPrint(ipAddress != null ? 'IP Local: $ipAddress' : 'No se detectó IP');
      // 1. Iniciar el servidor en el puerto especificado.
      // IP.any significa escuchar en todas las interfaces de red disponibles.
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      debugPrint('Servidor iniciado en el puerto $_port. Esperando sensores...');

      // 2. Escuchar nuevas conexiones de sensores.
      _server!.listen(_handleNewConnection);
    } catch (e) {
      debugPrint('Error al iniciar el servidor: $e');
    }
  }

  /// Maneja la conexión física (TCP Handshake completo)
  void _handleNewConnection(Socket client) {
    final clientAddress = client.remoteAddress.address;
    debugPrint('🔌 Nuevo cliente TCP conectado: $clientAddress');

    // 1. Registramos cliente y NOTIFICAMOS INMEDIATAMENTE
    _activeClients[clientAddress] = client;
    _connectionController.add(client);

    // 2. Preparamos buffer para este cliente
    final BytesBuilder socketBuffer = BytesBuilder();

    // 3. Escuchar datos
    client.listen(
          (Uint8List data) {
        socketBuffer.add(data);
        _processBuffer(client, socketBuffer);
      },
      onError: (e) {
        debugPrint('⚠️ Error en socket $clientAddress: $e');
        _removeClient(clientAddress, client);
      },
      onDone: () {
        debugPrint('👋 Cliente desconectado: $clientAddress');
        _removeClient(clientAddress, client);
      },
      cancelOnError: true,
    );
  }

  void _processBuffer(Socket client, BytesBuilder buffer) {
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
        _decodePacket(client, packetBytes, nSamples, mDims);

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
  void _decodePacket(Socket client, Uint8List bytes, int nSamples, int mDims) {
    try {
      final buffer = ByteData.sublistView(bytes);
      int readPtr = 0;

      // --- 1. HEADER ---
      // MAC (6)
      readPtr += 6;
      // Freq (2)
      int freq = buffer.getInt16(readPtr, Endian.little);
      readPtr += 2;
      // N Samples (2) - Ya lo leímos fuera, pero avanzamos el puntero
      readPtr += 2;
      // M Dims (1)
      readPtr += 1;
      // Timestamp Base (4)
      int tsBaseMs = buffer.getInt64(readPtr, Endian.little);
      readPtr += 8;
      // Sensor Name (6)
      String sensorId = String.fromCharCodes(bytes.sublist(readPtr, readPtr + 6)).trim();
      readPtr += 6;

      // --- 2. DATA ---
      double intervalUs = 1000000.0 / freq;
      List<List<dynamic>> reconstructedData = [];

      for (int i = 0; i < nSamples; i++) {
        List<double> values = [];
        for (int j = 0; j < mDims; j++) {
          int rawVal = buffer.getInt16(readPtr, Endian.little);
          readPtr += 2;
          values.add(rawVal / _scalar);
        }
        int sampleTs = tsBaseMs + (i * intervalUs).round();
        reconstructedData.add([values, sampleTs]);
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

      debugPrint('✅ Recibido: ${packet.sensorId} (${packet.data.length} datos)');

    } catch (e) {
      debugPrint('❌ Error lógico decodificando paquete: $e');
    }
  }

  void _removeClient(String address, Socket client) {
    _activeClients.remove(address);
    try {
      client.destroy();
    } catch (_) {}
    notifyListeners();
  }

  /// Cierra el servidor y todas las conexiones activas.
  Future<void> stop() async {
    // Cerrar clientes
    for (var client in _activeClients.values) {
      client.destroy();
    }
    _activeClients.clear();
    packets.clear();

    await _server?.close();
    _server = null;
    debugPrint('🛑 Servidor TCP detenido');
  }
}