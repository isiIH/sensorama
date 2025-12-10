import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/constants.dart';
import '../protocol/tcp_conn.dart';
import '../protocol/udp_conn.dart';

class BleProvisioner {

  /// Configura un solo dispositivo y espera la conexión de vuelta (Socket)
  Future<void> provisionDevice({
    required BluetoothDevice device,
    required String ssid,
    required String password,
    required String host,
    required int port,
    required String protocol,
  }) async {
    StreamSubscription? connectionSubscription;
    final connectionCompleter = Completer<bool>();

    try {
      // 1. Configurar listener del Socket (TCP/UDP) ANTES de enviar credenciales
      if (protocol.toUpperCase() == 'TCP') {
        connectionSubscription = TCPConn().onClientConnected.listen((_) {
          if (!connectionCompleter.isCompleted) connectionCompleter.complete(true);
        });
      } else {
        connectionSubscription = UDPConn().onClientConnected.listen((_) {
          if (!connectionCompleter.isCompleted) connectionCompleter.complete(true);
        });
      }

      // 2. Conectar y Escribir por BLE
      await _writeCredentials(device, ssid, password, host, port, protocol);

      // 3. Esperar confirmación del socket (Timeout 30s)
      await connectionCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException("$protocol connection timed out."),
      );

    } finally {
      connectionSubscription?.cancel();
    }
  }

  Future<void> _writeCredentials(BluetoothDevice device, String ssid, String pass, String host, int port, String proto) async {
    // Conexión
    await device.connect(license: License.free, autoConnect: false);
    await device.requestMtu(512);

    // Descubrimiento
    List<BluetoothService> services = await device.discoverServices();
    BluetoothService service = services.firstWhere(
          (s) => s.uuid == EspUuidConstants.serviceUUID,
      orElse: () => throw Exception("Service not found"),
    );

    BluetoothCharacteristic getChar(Guid uuid) =>
        service.characteristics.firstWhere((c) => c.uuid == uuid);

    // Escritura
    await getChar(EspUuidConstants.charSSIDUUID).write(utf8.encode(ssid), withoutResponse: false);
    await getChar(EspUuidConstants.charPassUUID).write(utf8.encode(pass), withoutResponse: false);
    await getChar(EspUuidConstants.charConfigUUID).write(utf8.encode("$host:$port"), withoutResponse: false);
    await getChar(EspUuidConstants.charProtoUUID).write(utf8.encode(proto), withoutResponse: false);
    await getChar(EspUuidConstants.charActionUUID).write(utf8.encode("SAVE"), withoutResponse: false);

    // Siempre desconectar el BLE al terminar para liberar recursos
    if(device.isConnected) {
      await device.disconnect();
    }
  }
}