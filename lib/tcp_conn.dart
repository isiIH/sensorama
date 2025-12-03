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
  final Map<String, Socket> _activeClients = {};
  final List<SensorPacket> packets = [];

  // StreamController para avisar a la UI
  final _connectionController = StreamController<Socket>.broadcast();
  // Exponemos el stream público
  Stream<Socket> get onClientConnected => _connectionController.stream;

  /// 🔌 Inicia el servidor para escuchar conexiones entrantes.
  Future<void> start() async {
    await stop(closeController: false);

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

  void _registerClient(String sensorId, Socket newClient) {
    // Si ya existe, destruye el socket anterior
    if (_activeClients.containsKey(sensorId)) {
      print('⚠️ Reemplazando conexión para Sensor ID: $sensorId. Destruyendo socket antiguo.');
      _activeClients[sensorId]?.destroy();
    }

    // Asigna el nuevo socket
    _activeClients[sensorId] = newClient;

    // 3. Notifica a la UI si es necesario
    _connectionController.add(newClient);
    print('Sensor conectado desde ${newClient.remoteAddress.address}:${newClient
        .remotePort}');
  }

  /// Maneja una nueva conexión de sensor.
  void _handleNewConnection(Socket client) {
    if (!_connectionController.isClosed) {
      String messageBuffer = "";

      // 3. Escuchar los datos enviados por este sensor específico.
      client.listen((data) {
        try {
          messageBuffer += utf8.decode(data, allowMalformed: true);

          while (messageBuffer.contains('\n')) {
            int newlineIndex = messageBuffer.indexOf('\n');
            String completeMessage = messageBuffer
                .substring(0, newlineIndex)
                .trim();
            messageBuffer = messageBuffer.substring(newlineIndex + 1);

            if (completeMessage.isNotEmpty) {
              _processMessage(completeMessage, client);
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
        cancelOnError: true,
      );
    } else {
      _removeClient(client);
    }
  }

  void _processMessage(String jsonString, Socket client) {
    if (jsonString.startsWith('{') && jsonString.endsWith('}')) {
      try {
        final Map<String, dynamic> jsonData = jsonDecode(jsonString);
        final newPacket = SensorPacket.fromJson(jsonData);

        if (!_activeClients.containsValue(client)) {
          _registerClient(newPacket.sensorId, client);
        }

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
    _activeClients.removeWhere((key, value) => value == client);
    try {
      client.destroy();
    } catch (_) {}
  }

  /// Cierra el servidor y todas las conexiones activas.
  Future<void> stop({bool closeController = true}) async {
    packets.clear();
    notifyListeners();

    // 1. Cerrar todos los clientes
    for (var client in _activeClients.values) {
      client.destroy();
    }
    _activeClients.clear();

    // 2. Cierre del Servidor (IMPORTANTE: Esto detiene la emisión de _handleNewConnection)
    try {
      await _server?.close();
      _server = null;
    } catch (e) {
      print("Error cerrando servidor: $e");
    }

    // 3. Cierre del StreamController (Solo si se requiere y no está cerrado)
    if (closeController && !_connectionController.isClosed) {
      await _connectionController.close();
    }

    print('🚪 Servidor cerrado.');
  }
}