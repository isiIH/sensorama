import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/constants.dart';
import '../protocol/tcp_conn.dart';
import '../protocol/udp_conn.dart';
import '../protocol/ble_conn.dart';

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  // Stream controller para exponer solo la lista filtrada a la UI
  final _scanResultsController = StreamController<List<BluetoothDevice>>.broadcast();
  Stream<List<BluetoothDevice>> get scanResults => _scanResultsController.stream;
  StreamSubscription? _scanSubscription;

  // Añadimos una caché para guardar el último estado válido
  List<BluetoothDevice> _deviceCache = [];
  List<BluetoothDevice> get currentDevices => List.unmodifiable(_deviceCache);

  /// Inicia el escaneo y filtra automáticamente por el prefijo deseado
  Future<void> startScan({String filterPrefix = 'sensor-', timeout = 20}) async {
    if (!await checkBT()) return;

    await _scanSubscription?.cancel();

    // Si tenemos caché vieja, la emitimos para respuesta inmediata visual
    if (_deviceCache.isNotEmpty) {
      _scanResultsController.add(_deviceCache);
    }

    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      final filteredDevices = results
          .map((r) => r.device) // O tu lógica con nombres
          .where((device) => device.platformName.startsWith(filterPrefix))
          .toSet()
          .toList();

      _deviceCache = filteredDevices;
      _scanResultsController.add(filteredDevices);
    });

    // Solo enviamos la orden startScan si NO está rodando ya.
    if (FlutterBluePlus.isScanningNow) {
      debugPrint("⚡ El escáner ya estaba activo. Nos hemos conectado al flujo existente.");
    } else {
      // Si estaba apagado, lo encendemos
      try {
        await FlutterBluePlus.startScan(
            timeout: Duration(seconds: timeout),
            withServices: [AppConstants.provServiceUUID]
        );

      } catch (e) {
        debugPrint("Error starting scan: $e");
        _scanSubscription?.cancel();
        rethrow;
      }
    }
  }

  Future<bool> checkBT() async {
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.unknown) {
      await FlutterBluePlus.adapterState
          .firstWhere((state) => state != BluetoothAdapterState.unknown);
    }

    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        debugPrint("Bluetooth is off and could not be turned on.");
        return false;
      }
    }

    return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
  }

  /// Procesa una lista de dispositivos en paralelo o serie
  Future<int> provisionBatch({
    required List<BluetoothDevice> devices,
    required String ssid,
    required String password,
    required String host,
    required int port,
    required String protocol,
  }) async {
    int successCount = 0;

    // Ejecutamos en paralelo para mayor velocidad
    final futures = devices.map((device) async {
      try {
        await _provisionDevice(
          device: device,
          ssid: ssid,
          password: password,
          host: host,
          port: port,
          protocol: protocol,
        );
        return true;
      } catch (e) {
        debugPrint("❌ Error provisioning ${device.platformName} with $protocol: $e");
        return false;
      }
    });

    final results = await Future.wait(futures);
    successCount = results.where((success) => success).length;

    return successCount;
  }

  /// Lógica core de aprovisionamiento (Privada, solo expuesta vía batch)
  Future<void> _provisionDevice({
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
      debugPrint("1️⃣ Connecting to ${device.platformName} via BLE...");
      await _writeCredentials(device, ssid, password, host, port, protocol);

      debugPrint("2️⃣ Waiting for $protocol handshake...");
      // Setup listener based on protocol
      if (protocol == 'TCP') {
        connectionSubscription = TCPConn().onClientConnected.listen((mac) {
          _checkCompletion(connectionCompleter, device.remoteId.toString(), mac);
        });
      } else if(protocol == 'UDP') {
        connectionSubscription = UDPConn().onClientConnected.listen((mac) {
          _checkCompletion(connectionCompleter, device.remoteId.toString(), mac);
        });
      } else if (protocol == 'BLE') {
        final bleConn = BLEConn();
        bleConn.handleConnection(device);
        connectionSubscription = bleConn.onClientConnected.listen((mac) {
          _checkCompletion(connectionCompleter, device.remoteId.toString(), mac);
        });

        // Timeout específico para BLE re-connect
        Future.delayed(const Duration(seconds: 40), () {
          if (!connectionCompleter.isCompleted) {
            bleConn.disconnect();
            if(!connectionCompleter.isCompleted) connectionCompleter.completeError("BLE Reconnection Timeout");
          }
        });
      }

      await connectionCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException("$protocol handshake timed out"),
      );

    } finally {
      await connectionSubscription?.cancel();
    }
  }

  void _checkCompletion(Completer completer, String targetId, String incomingId) {
    // Normalizamos IDs para evitar errores de Case Sensitivity o formato
    if (!completer.isCompleted && targetId.toUpperCase() == incomingId.toUpperCase()) {
      completer.complete(true);
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