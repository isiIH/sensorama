import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
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
  final List<Socket> _clients = []; // Lista para manejar múltiples sensores
  final List<SensorPacket> packets = [];

  // StreamController para avisar a la UI
  final _connectionController = StreamController<Socket>.broadcast();
  // Exponemos el stream público
  Stream<Socket> get onClientConnected => _connectionController.stream;

  /// 🔌 Inicia el servidor para escuchar conexiones entrantes.
  Future<void> start() async {
    try {
      String? ipAddress = await getLocalIpAddress();
      if (ipAddress != null) {
        print('Local IP Address: $ipAddress');
      } else {
        print('Could not get local IP address.');
      }
      // 1. Iniciar el servidor en el puerto especificado.
      // IP.any significa escuchar en todas las interfaces de red disponibles.
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      print('Servidor iniciado en el puerto $_port. Esperando sensores...');

      // 2. Escuchar nuevas conexiones de sensores.
      _server!.listen(_handleNewConnection);
    } catch (e) {
      print('Error al iniciar el servidor: $e');
    }
  }

  /// Maneja una nueva conexión de sensor.
  void _handleNewConnection(Socket client) {
    _clients.add(client);
    _connectionController.add(client);
    print('Sensor conectado desde ${client.remoteAddress.address}:${client.remotePort}');

    String messageBuffer = "";

    // 3. Escuchar los datos enviados por este sensor específico.
    client.listen((data) {
      try {
        messageBuffer += utf8.decode(data, allowMalformed: true);

        while (messageBuffer.contains('\n')) {
          int newlineIndex = messageBuffer.indexOf('\n');
          String completeMessage = messageBuffer.substring(0, newlineIndex).trim();
          messageBuffer = messageBuffer.substring(newlineIndex + 1);

          if (completeMessage.isNotEmpty) {
            _processMessage(completeMessage);
          }
        }

      } catch (e) {
        print("Error procesando buffer: $e");
      }
    },
      onError: (e) {
        print('Error en conexión: $e');
        _removeClient(client);
      },
      onDone: () {
        print('Sensor desconectado.');
        _removeClient(client);
      },
    );
  }

  void _processMessage(String jsonString) {
    if (jsonString.startsWith('{') && jsonString.endsWith('}')) {
      try {
        final Map<String, dynamic> jsonData = jsonDecode(jsonString);
        final newPacket = SensorPacket.fromJson(jsonData);

        packets.add(newPacket);

        notifyListeners();
        print('✅ Recibido: ${newPacket.sensorId} (${newPacket.data.length} bloques)');
      } catch (e) {
        print('⚠️ JSON malformado a pesar de tener llaves: $e');
      }
    } else {
      print('🗑️ Descartado (Incompleto o basura): $jsonString');
    }
  }

  void _removeClient(Socket client) {
    _clients.remove(client);
    client.destroy();
  }

  /// Cierra el servidor y todas las conexiones activas.
  void stop() {
    _server?.close();
    packets.clear();
    notifyListeners();
    for (var client in _clients) {
      client.destroy();
    }
    _clients.clear();
    _connectionController.close();
    print('🚪 Servidor cerrado.');
  }
}