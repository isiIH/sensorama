import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'tcp_conn.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart'; // IMPORTANTE: Agregar este paquete

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  // --- Estado de Red ---
  String? _localIp;
  String? _wifiName;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  final int _port = int.parse(dotenv.env['PORT']!);

  // --- Estado de Bluetooth ---
  final List<BluetoothDevice> _devices = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _permissionsGranted = false;
  bool _isScanning = false;

  // --- UI ---
  bool _passwordVisible = false;

  // --- UUIDs ESP32 ---
  final Guid serviceUUID = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  final Guid charSSIDUUID = Guid("beb5483e-36e1-4688-b7f5-ea07361b26a8");
  final Guid charPassUUID = Guid("82141505-1a35-463d-9d7a-1808d4b005c3");
  final Guid charConfigUUID = Guid("e4b60b73-0456-4c4f-bc14-22280d507116");
  final Guid charActionUUID = Guid("69c2794c-8594-4b53-b093-a61574697960");

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initNetworkListener(); // Iniciar escucha de red
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connectivitySub?.cancel(); // Cancelar escucha de red
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // GESTIÓN DE RED (IP y WIFI)
  // ---------------------------------------------------------------------------

  void _initNetworkListener() {
    // Escucha cambios en la conectividad (WiFi <-> Datos <-> Nada)
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((results) async {
          await Future.delayed(const Duration(seconds: 2));
          _updateNetworkInfo();
        });

    // Carga inicial
    _updateNetworkInfo();
  }

  Future<void> _updateNetworkInfo() async {
    final info = NetworkInfo();
    String? wifiName = await info.getWifiName();
    String? ip = await info
        .getWifiIP(); // Usamos network_info_plus para la IP WiFi específicamente

    // Si network_info falla o estamos en datos, intentamos el método genérico
    ip ??= await getLocalIpAddress();

    if (wifiName != null) {
      // Limpieza de comillas que devuelve iOS/Android a veces
      if (wifiName.startsWith('"') && wifiName.endsWith('"')) {
        wifiName = wifiName.substring(1, wifiName.length - 1);
      }
    }

    if (mounted) {
      setState(() {
        _localIp = ip;
        _wifiName = wifiName;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // GESTIÓN DE PERMISOS Y BLUETOOTH
  // ---------------------------------------------------------------------------

  Future<void> _requestPermissions() async {
    final Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location, // Necesario para obtener SSID en Android
    ].request();

    final allGranted = statuses.values.every((status) =>
    status.isGranted || status.isDenied); // Lógica permisiva

    if (mounted) {
      setState(() {
        _permissionsGranted = allGranted;
      });

      // Si tenemos permisos, actualizamos la info de red (el SSID requiere Location)
      if (allGranted) _updateNetworkInfo();
    }

    if (!allGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
            'Permissions are required for scanning and Wifi info.')),
      );
    }
  }

  Future<bool> checkBluetoothStatus() async {
    // Verificar el estado actual inmediatamente
    var state = await FlutterBluePlus.adapterState.first;

    if (state == BluetoothAdapterState.on) {
      return true;
    }

    // 2. Si está apagado y estamos en Android, intentar encenderlo
    try {
      await FlutterBluePlus.turnOn();

      // 3. IMPORTANTE: Esperar a que el estado cambie a 'on'
      // Usamos firstWhere para pausar la ejecución hasta que detectemos el cambio
      state = await FlutterBluePlus.adapterState.firstWhere(
            (s) => s == BluetoothAdapterState.on,
      ).timeout(const Duration(seconds: 5)); // Damos 5 segundos máximo para que prenda

      return state == BluetoothAdapterState.on;

    } catch (e) {
      print("Error al intentar encender Bluetooth o tiempo de espera agotado: $e");
      return false;
    }
  }

  void _startScan() async {
    if (_isScanning) return;

    if (!_permissionsGranted) {
      // Intentamos pedir de nuevo si no los tiene
      await _requestPermissions();
      if (!_permissionsGranted) return;
    }

    bool bleEnabled = await checkBluetoothStatus();

    if (!bleEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth is not enabled.')),
      );
      return;
    }

    setState(() {
      _isScanning = true;
    });

    try {
      await _scanSub?.cancel();
      _scanSub = null;

      // Reiniciar escaneo limpio
      while (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      await Future.delayed(const Duration(seconds: 1));
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

      if (mounted) {
        setState(() {
          _devices.clear();
        });
      }

      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;

        List<BluetoothDevice> foundDevices = [];
        for (final r in results) {
          if (r.device.platformName.toLowerCase().startsWith('sensor-')) {
            foundDevices.add(r.device);
          }
        }

        setState(() {
          for (var d in foundDevices) {
            if (!_devices.any((existing) => existing.remoteId == d.remoteId)) {
              _devices.add(d);
            }
          }
        });
      });

      await Future.delayed(const Duration(seconds: 15));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });

        // Opcional: Si terminó y no encontró nada, forzamos un stop por si acaso
        if (FlutterBluePlus.isScanningNow) {
          await FlutterBluePlus.stopScan();
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // LÓGICA DE PROVISIONAMIENTO (ESP32)
  // ---------------------------------------------------------------------------

  Future<void> _provisionDevice(BluetoothDevice device, String ssid,
      String password, String host, int port) async {
    if (!mounted) return;

    StreamSubscription? tcpSubscription;

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connecting to BLE device...')),
      );

      // Conexión BLE
      await device.connect(license: License.free, autoConnect: false);
      if (Platform.isAndroid) await device.requestMtu(512);

      List<BluetoothService> services = await device.discoverServices();
      BluetoothService targetService = services.firstWhere(
            (s) => s.uuid == serviceUUID,
        orElse: () => throw Exception("Service UUID not found on device."),
      );

      BluetoothCharacteristic getChar(Guid uuid) =>
          targetService.characteristics.firstWhere((c) => c.uuid == uuid);

      // Escritura de credenciales
      await getChar(charSSIDUUID).write(utf8.encode(ssid), withoutResponse: false);
      await getChar(charPassUUID).write(utf8.encode(password), withoutResponse: false);
      await getChar(charConfigUUID).write(utf8.encode("$host:$port"), withoutResponse: false);
      await getChar(charActionUUID).write(utf8.encode("SAVE"), withoutResponse: false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Credentials sent to ${device.platformName}. Waiting for TCP...')),
        );
      }

      await device.disconnect();

      if (!mounted) return;

      // Espera de conexión TCP
      final tcpCompleter = Completer<bool>();
      tcpSubscription = TCPConn().onClientConnected.listen((socket) {
        if (!tcpCompleter.isCompleted) {
          tcpCompleter.complete(true);
        }
      });

      await tcpCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException("TCP connection timed out."),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Device connected via TCP!'), backgroundColor: Colors.green),
        );
        // Aquí podrías agregar el dispositivo a _connectedDevices
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      tcpSubscription?.cancel();
      // Reiniciar escaneo para buscar otros sensores
      _startScan();
    }
  }

  // ---------------------------------------------------------------------------
  // UI DIALOGS & BUILD
  // ---------------------------------------------------------------------------

  void _showConfigDialog(BluetoothDevice device) {
    // Usamos el estado actual de la red para pre-llenar
    final ssidController = TextEditingController(text: _wifiName ?? '');
    final passController = TextEditingController();
    final hostController = TextEditingController(text: _localIp ?? '');
    final portController = TextEditingController(text: _port.toString());

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Configure ${device.platformName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                TextField(
                  controller: hostController,
                  decoration: const InputDecoration(
                      labelText: 'Host IP', border: OutlineInputBorder()),
                ),
                TextField(
                  controller: portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Port', border: OutlineInputBorder()),
                ),
                TextField(
                  controller: ssidController,
                  decoration: const InputDecoration(
                      labelText: 'SSID (WiFi Name)', border: OutlineInputBorder()),
                ),
                TextField(
                  controller: passController,
                  obscureText: !_passwordVisible,
                  decoration: InputDecoration(
                    labelText: 'WiFi Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_passwordVisible
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () {
                        setDialogState(() {
                          _passwordVisible = !_passwordVisible;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final ssid = ssidController.text;
                final password = passController.text;
                final host = hostController.text;
                final port = int.tryParse(portController.text) ?? _port;

                Navigator.of(context).pop();
                await _provisionDevice(device, ssid, password, host, port);
              },
              child: const Text('Save & Connect'),
            ),
          ],
        ),
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
          // Info Panel
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.wifi, size: 20, color: Colors.white70),
                    const SizedBox(width: 8),
                    Text('WiFi: ${_wifiName ?? 'Not Connected'}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.computer, size: 20, color: Colors.white70),
                    const SizedBox(width: 8),
                    Text('Host IP: ${_localIp ?? 'Fetching...'}'),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.numbers, size: 20, color: Colors.white70),
                    const SizedBox(width: 8),
                    Text('Port: $_port'),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Lista de escaneo
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Available Sensors',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                onPressed: _isScanning ? null :() async {
                  _startScan();
                },
                icon: const Icon(Icons.refresh),
                tooltip: 'Rescan',

              )
            ],
          ),

          const Divider(),

          Expanded(
            child: _devices.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: _isScanning ?
                const [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Scanning for devices...',
                      style: TextStyle(color: Colors.white54)),
                ] : const [ Text("No devices found") ]
              ),
            )
                : ListView.separated(
              itemCount: _devices.length,
              separatorBuilder: (_, __) =>
              const Divider(color: Colors.white10),
              itemBuilder: (context, index) {
                final device = _devices[index];
                return ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(device.platformName.isNotEmpty
                      ? device.platformName
                      : 'Unknown Device'),
                  subtitle: Text(device.remoteId.str),
                  trailing: ElevatedButton(
                    child: const Text("Setup"),
                    onPressed: () => _showConfigDialog(device),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}