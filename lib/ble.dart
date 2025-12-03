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
  final List<String> _connectedDevices = []; // Lista visual (mock o futura implementación)
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _permissionsGranted = false;

  // --- UI ---
  bool _passwordVisible = false;
  // --- Selection ---
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

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
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      _updateNetworkInfo();
    });

    // Carga inicial
    _updateNetworkInfo();
  }

  Future<void> _updateNetworkInfo() async {
    final info = NetworkInfo();
    String? wifiName = await info.getWifiName();
    String? ip = await info.getWifiIP(); // Usamos network_info_plus para la IP WiFi específicamente

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

    final allGranted = statuses.values.every((status) => status.isGranted || status.isDenied); // Lógica permisiva

    if (mounted) {
      setState(() {
        _permissionsGranted = allGranted;
      });

      // Si tenemos permisos, actualizamos la info de red (el SSID requiere Location)
      if (allGranted) _updateNetworkInfo();
    }

    if (!allGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permissions are required for scanning and Wifi info.')),
      );
    }
  }

  void _startScan() async {
    if (!_permissionsGranted) {
      // Intentamos pedir de nuevo si no los tiene
      await _requestPermissions();
      if (!_permissionsGranted) return;
    }

    try {
      // Reiniciar escaneo limpio
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;

        List<BluetoothDevice> foundDevices = [];
        for (final r in results) {
          if (r.device.platformName.toLowerCase().startsWith('sensor-')) {
            foundDevices.add(r.device);
          }
        }

        setState(() {
          _devices.clear();
          for (var d in foundDevices) {
            if (!_devices.any((existing) => existing.remoteId == d.remoteId)) {
              _devices.add(d);
            }
          }
        });
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan error: $e')),
        );
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

  // Show bulk configuration dialog for selected devices
  void _showBulkConfigDialog() {
    final ssidController = TextEditingController(text: _wifiName ?? '');
    final passController = TextEditingController();
    final hostController = TextEditingController(text: _localIp ?? '');
    final portController = TextEditingController(text: _port.toString());

    final selectedCount = _selectedIds.length;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Configure $selectedCount sensors'),
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
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final ssid = ssidController.text;
                final password = passController.text;
                final host = hostController.text;
                final port = int.tryParse(portController.text) ?? _port;

                Navigator.of(context).pop();

                // Build list of BluetoothDevice from selected ids
                final devicesToProvision = _devices.where((d) => _selectedIds.contains(d.remoteId.str)).toList();

                await _provisionMultipleDevices(devicesToProvision, ssid, password, host, port);
              },
              child: const Text('Save & Connect'),
            ),
          ],
        ),
      ),
    );
  }

  // Provision multiple devices sequentially
  Future<void> _provisionMultipleDevices(List<BluetoothDevice> devices, String ssid, String password, String host, int port) async {
    if (devices.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Provisioning ${devices.length} devices in parallel...')),
    );

    // Helper for per-device provisioning with timeout and error capture
    Future<Map<String, dynamic>> _provisionOne(BluetoothDevice dev) async {
      try {
        await _provisionDevice(dev, ssid, password, host, port)
            .timeout(const Duration(seconds: 30));
        return {'id': dev.remoteId.str, 'name': dev.platformName, 'success': true};
      } catch (e) {
        return {'id': dev.remoteId.str, 'name': dev.platformName, 'success': false, 'error': e.toString()};
      }
    }

    // Run all in parallel
    final results = await Future.wait(devices.map(_provisionOne));

    // Aggregate results
    final failed = results.where((r) => r['success'] == false).toList();
    final succeeded = results.where((r) => r['success'] == true).toList();

    if (mounted) {
      if (succeeded.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Provisioned ${succeeded.length} devices successfully.'), backgroundColor: Colors.green),
        );
      }
      if (failed.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to provision ${failed.length} devices.'), backgroundColor: Colors.red),
        );
        // Optionally, show details for each failed device
        for (var r in failed) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Device ${r['name']} error: ${r['error']}'), backgroundColor: Colors.red),
          );
        }
      }
      // Clear selection and exit selection mode
      setState(() {
        _selectedIds.clear();
        _selectionMode = false;
      });
    }
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
              Row(
                children: [
                  // Master select square: shown only when in selection mode
                  if (_selectionMode)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (_selectedIds.length == _devices.length) {
                            _selectedIds.clear();
                            _selectionMode = false;
                          } else {
                            _selectedIds.clear();
                            for (var d in _devices) {
                              _selectedIds.add(d.remoteId.str);
                            }
                          }
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: _selectedIds.length == _devices.length ? Colors.blue : Colors.transparent,
                          border: Border.all(color: Colors.white54),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: _selectedIds.length == _devices.length
                            ? const Icon(Icons.check, size: 18, color: Colors.white)
                            : null,
                      ),
                    ),
                  const Text('Available Sensors',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              IconButton(
                onPressed: () async {
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
                children: const [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Scanning for devices...',
                      style: TextStyle(color: Colors.white54)),
                ],
              ),
            )
                : ListView.separated(
                    itemCount: _devices.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      final id = device.remoteId.str;
                      final isSelected = _selectedIds.contains(id);

                      return ListTile(
                        onLongPress: () {
                          // Enter selection mode and select this item
                          setState(() {
                            _selectionMode = true;
                            _selectedIds.add(id);
                          });
                        },
                        onTap: () {
                          if (_selectionMode) {
                            setState(() {
                              if (isSelected) {
                                _selectedIds.remove(id);
                                if (_selectedIds.isEmpty) _selectionMode = false;
                              } else {
                                _selectedIds.add(id);
                              }
                            });
                          } else {
                            _showConfigDialog(device);
                          }
                        },
                        leading: _selectionMode
                            ? GestureDetector(
                                onTap: () {
                                  setState(() {
                                    if (isSelected) {
                                      _selectedIds.remove(id);
                                      if (_selectedIds.isEmpty) _selectionMode = false;
                                    } else {
                                      _selectedIds.add(id);
                                    }
                                  });
                                },
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: isSelected ? Colors.blue : Colors.transparent,
                                    border: Border.all(color: Colors.white54),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: isSelected
                                      ? const Icon(Icons.check, size: 18, color: Colors.white)
                                      : null,
                                ),
                              )
                            : const Icon(Icons.bluetooth),
                        title: Text(device.platformName.isNotEmpty
                            ? device.platformName
                            : 'Unknown Device'),
                        subtitle: Text(id),
                        trailing: _selectionMode
                            ? null
                            : ElevatedButton(
                                child: const Text("Setup"),
                                onPressed: () => _showConfigDialog(device),
                              ),
                      );
                    },
                  ),
          ),
          // Bulk action button shown when selection mode is active
          if (_selectionMode)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _selectedIds.isEmpty ? null : _showBulkConfigDialog,
                  child: Text('Setup Selection (${_selectedIds.length})'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}