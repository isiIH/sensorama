import 'dart:io';
import 'dart:convert';
import 'package:network_info_plus/network_info_plus.dart';

Future<String?> getLocalIpAddress() async {
  final info = NetworkInfo();
  final wifiIP = await info.getWifiIP();
  return wifiIP;
}

class TCPConn {
  final int port;
  ServerSocket? _server;
  final List<Socket> _clients = []; // Lista para manejar múltiples sensores

  TCPConn({required this.port});

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
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      print('Servidor iniciado en el puerto $port. Esperando sensores...');

      // 2. Escuchar nuevas conexiones de sensores.
      _server!.listen(_handleNewConnection);
    } catch (e) {
      print('Error al iniciar el servidor: $e');
    }
  }

  /// Maneja una nueva conexión de sensor.
  void _handleNewConnection(Socket client) {
    _clients.add(client);
    print('Sensor conectado desde ${client.remoteAddress.address}:${client.remotePort}');

    // 3. Escuchar los datos enviados por este sensor específico.
    client.listen(
          (data) {
        final String sensorData = utf8.decode(data).trim();
        print('Datos recibidos del sensor: $sensorData');
        // A. Aquí procesas los datos, los identificas y los guardas en la memoria.
        // B. (Opcional) Puedes responder al sensor: client.write('ACK\n');
      },
      onError: (e) {
        print('Error en conexión con sensor: $e');
        _removeClient(client);
      },
      onDone: () {
        print('Sensor desconectado.');
        _removeClient(client);
      },
    );
  }

  void _removeClient(Socket client) {
    _clients.remove(client);
    client.destroy();
  }

  /// Cierra el servidor y todas las conexiones activas.
  void stop() {
    _server?.close();
    for (var client in _clients) {
      client.destroy();
    }
    _clients.clear();
    print('🚪 Servidor cerrado.');
  }
}