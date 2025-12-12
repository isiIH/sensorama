import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/constants.dart';
import '../protocol/tcp_conn.dart';
import '../protocol/udp_conn.dart';
import '../protocol/ble_conn.dart';

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
      // 1. Conectar y Escribir por BLE
      await _writeCredentials(device, ssid, password, host, port, protocol);

      // 2. Configurar listener del Socket (TCP/UDP)
      if (protocol == 'TCP') {
        connectionSubscription = TCPConn().onClientConnected.listen((mac) {
          if (!connectionCompleter.isCompleted && device.remoteId.toString() == mac) connectionCompleter.complete(true);
        });
      } else if(protocol == 'UDP') {
        connectionSubscription = UDPConn().onClientConnected.listen((mac) {
          if (!connectionCompleter.isCompleted && device.remoteId.toString() == mac) connectionCompleter.complete(true);
        });
      } else if (protocol == 'BLE') {
        final bleConn = BLEConn();
        bleConn.handleConnection(device);

        // Escuchamos el stream de "conexión exitosa" que bleConn emitirá
        // UNA VEZ que haya reconectado y renegociado el MTU.
        connectionSubscription = bleConn.onClientConnected.listen((mac) {
          if (!connectionCompleter.isCompleted && device.remoteId.toString() == mac) connectionCompleter.complete(true);
        });

        // (Opcional) Timeout de seguridad: Si en 40s no vuelve, lanzamos error
        Timer(Duration(seconds: 40), () {
          if (!connectionCompleter.isCompleted) {
            bleConn.disconnect();
            connectionCompleter.completeError("Timeout: El dispositivo BLE no regresó tras el reinicio.");
          }
        });
      }

      // 3. Esperar confirmación del socket (Timeout 15s)
      await connectionCompleter.future.timeout(
        const Duration(seconds: 15),
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
          (s) => s.uuid == AppConstants.provServiceUUID,
      orElse: () => throw Exception("Service not found"),
    );

    BluetoothCharacteristic getChar(Guid uuid) =>
        service.characteristics.firstWhere((c) => c.uuid == uuid);

    // Especial para BLE: no enviar credenciales WiFi
    if (proto.toUpperCase() != 'BLE') {
      await getChar(AppConstants.charSSIDUUID).write(
          utf8.encode(ssid), withoutResponse: false);
      await getChar(AppConstants.charPassUUID).write(
          utf8.encode(pass), withoutResponse: false);
      await getChar(AppConstants.charConfigUUID).write(
          utf8.encode("$host:$port"), withoutResponse: false);
    }

    await getChar(AppConstants.charProtoUUID).write(utf8.encode(proto), withoutResponse: false);
    await getChar(AppConstants.charActionUUID).write(utf8.encode("SAVE"), withoutResponse: false);

    // 1. BARRERA DE ESPERA: Bloqueamos hasta detectar la desconexión física.
    // Esto garantiza que no empezamos a buscar algo que todavía "creemos" tener conectado.
    // Ponemos un timeout por si acaso la placa se congela y no se reinicia.
    await device.connectionState
        .firstWhere((state) => state == BluetoothConnectionState.disconnected)
        .timeout(Duration(seconds: 10));

    debugPrint("📉 Desconexión detectada. El ESP32 se está reiniciando.");
  }
}