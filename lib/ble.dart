import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'tcp_conn.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// ---------------------------------------------------------------------------
// CONNECTION SCREEN
// ---------------------------------------------------------------------------

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  String? _localIp;
  final List<BluetoothDevice> _devices = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _permissionsGranted = false;
  final int _port = int.parse(dotenv.env['PORT']!);

  @override
  void initState() {
    super.initState();
    _loadLocalIp();
    _requestPermissions();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _loadLocalIp() async {
    final ip = await getLocalIpAddress();
    setState(() {
      _localIp = ip;
    });
  }

  Future<void> _requestPermissions() async {
    final Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    final allGranted =
    statuses.values.every((status) => status.isGranted || status.isDenied);

    if (mounted) {
      setState(() {
        _permissionsGranted = allGranted;
      });
    }

    if (allGranted) {
      _startScan();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Bluetooth and location permissions are required for scanning devices.')),
        );
      }
    }
  }

  // Definición de UUIDs coincidentes con el ESP32
  final Guid SERVICE_UUID = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  final Guid CHAR_SSID_UUID = Guid("beb5483e-36e1-4688-b7f5-ea07361b26a8");
  final Guid CHAR_PASS_UUID = Guid("82141505-1a35-463d-9d7a-1808d4b005c3");
  final Guid CHAR_CONFIG_UUID = Guid("e4b60b73-0456-4c4f-bc14-22280d507116");
  final Guid CHAR_ACTION_UUID = Guid("69c2794c-8594-4b53-b093-a61574697960");

  Future<void> _provisionDevice(BluetoothDevice device, String ssid,
      String password, String host, int port) async {
    if (!mounted) return;
    bool connected = false;

    try {
      // 1. Mostrar feedback de carga
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connecting to device...')),
      );

      // 2. Conectar (Desactivar autoConnect para forzar conexión inmediata)
      await device.connect(license: License.free, autoConnect: false);
      connected = true;

      // Solicitar MTU más alto para enviar strings largos más rápido (opcional pero recomendado)
      if (Platform.isAndroid) {
        await device.requestMtu(512);
      }

      // 3. Descubrir Servicios
      List<BluetoothService> services = await device.discoverServices();

      // Buscar nuestro servicio custom
      BluetoothService? targetService;
      try {
        targetService = services.firstWhere((s) => s.uuid == SERVICE_UUID);
      } catch (e) {
        throw Exception(
            "Service not found. Is the ESP32 flashing the correct code?");
      }

      // Helper para buscar características dentro del servicio
      BluetoothCharacteristic getChar(Guid uuid) {
        return targetService!.characteristics.firstWhere((c) => c.uuid == uuid);
      }

      // 4. Escribir Datos
      final ssidChar = getChar(CHAR_SSID_UUID);
      final passChar = getChar(CHAR_PASS_UUID);
      final configChar = getChar(CHAR_CONFIG_UUID); // Host:Port
      final actionChar = getChar(CHAR_ACTION_UUID);

      // Escribir SSID
      print("Writing SSID...");
      await ssidChar.write(utf8.encode(ssid), withoutResponse: false);

      // Escribir Password
      print("Writing Password...");
      await passChar.write(utf8.encode(password), withoutResponse: false);

      // Escribir Configuración (Host:Port)
      // Combinamos host y port en un solo string para enviarlo fácil
      String configString = "$host:$port";
      print("Writing Config: $configString");
      await configChar.write(utf8.encode(configString), withoutResponse: false);

      // 5. Enviar comando de acción para guardar y conectar
      print("Sending Save Command...");
      await actionChar.write(utf8.encode("SAVE"), withoutResponse: false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Configuration sent to ${device.name}! Device is rebooting/connecting.')),
        );
      }
    } catch (e) {
      print('Provisioning Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      // 6. Desconectar siempre
      if (connected) {
        await device.disconnect();
      }
    }
  }

  void _startScan() async {
    if (!_permissionsGranted) {
      await _requestPermissions();
      return;
    }

    try {
      await FlutterBluePlus.startScan();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName;
          if (name.toLowerCase().startsWith('sensor-')) {
            if (!_devices.any((d) => d.remoteId == r.device.remoteId)) {
              setState(() {
                _devices.add(r.device);
              });
            }
          }
        }
      });
    } catch (e) {
      // ignore: avoid_print
      print('Bluetooth scan error: $e');
    }
  }

  void _showConfigDialog(BluetoothDevice device) {
    final ssidController = TextEditingController();
    final passController = TextEditingController();
    final hostController = TextEditingController(text: _localIp ?? '');
    final portController = TextEditingController(text: _port.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Configure ${device.platformName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: ssidController,
                decoration: const InputDecoration(labelText: 'SSID')),
            TextField(
                controller: passController,
                decoration: const InputDecoration(labelText: 'Password')),
            TextField(
                controller: hostController,
                decoration: const InputDecoration(labelText: 'Host')),
            TextField(
                controller: portController,
                decoration: const InputDecoration(labelText: 'PORT')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              // For now we only collect values; hooking to actual provisioning/connection
              final ssid = ssidController.text;
              final password = passController.text;
              final host = hostController.text;
              final port = int.tryParse(portController.text) ?? _port;
              // TODO: send provisioning data to device via BLE or other mechanism
              // Debug-print so analyzer doesn't warn about unused vars
              // ignore: avoid_print
              print(
                  'Provisioning -> ssid:$ssid password:${password.isNotEmpty ? '***' : ''} host:$host port:$port');
              Navigator.of(context)
                  .pop(); // Cierra el diálogo antes de la conexión
              await _provisionDevice(device, ssid, password, host, port);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Local IP: ${_localIp ?? '...'}',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 6),
          Text('Port: $_port', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Available Bluetooth devices',
                  style: TextStyle(fontSize: 16)),
              TextButton.icon(
                onPressed: () async {
                  setState(() {
                    _devices.clear();
                  });
                  await FlutterBluePlus.stopScan();
                  _startScan();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan'),
              )
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _devices.isEmpty
                ? const Center(
                child: Text('No devices found',
                    style: TextStyle(color: Colors.white54)))
                : ListView.separated(
              itemCount: _devices.length,
              separatorBuilder: (_, __) =>
              const Divider(color: Colors.white10),
              itemBuilder: (context, index) {
                final device = _devices[index];
                return ListTile(
                  title: Text(device.platformName.isEmpty
                      ? device.remoteId.str
                      : device.platformName),
                  subtitle: Text(device.remoteId.str,
                      style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showConfigDialog(device),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}