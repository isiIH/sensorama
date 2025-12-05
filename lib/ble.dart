import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'tcp_conn.dart';
import 'udp_conn.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart'; // IMPORTANTE: Agregar este paquete

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> with WidgetsBindingObserver {
  // --- Estado de Red ---
  String? _localIp;
  String? _wifiName;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  final int _port = int.parse(dotenv.env['PORT']!);

  // --- Estado de Bluetooth ---
  final List<BluetoothDevice> _devices = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _isCheckingPermissions = true;
  bool _permissionsGranted = false;
  bool _isScanning = false;

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
  final Guid charProtoUUID = Guid("12345678-1234-1234-1234-1234567890ab");

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // No iniciamos nada hasta verificar permisos explícitamente
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _connectivitySub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // Detectar cuando la app vuelve al primer plano (útil si fueron a Settings)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-verificar permisos silenciosamente al volver
      _checkPermissionsStatusOnly();
    }
  }

  // ---------------------------------------------------------------------------
  // LÓGICA DE INICIALIZACIÓN Y PERMISOS MEJORADA
  // ---------------------------------------------------------------------------

  Future<void> _initializeApp() async {
    bool granted = await _checkAndRequestPermissions();

    if (mounted) {
      setState(() {
        _isCheckingPermissions = false;
      });
    }

    if (granted) {
      _initNetworkListener();
      _startScan();
    }
  }

  /// Verifica permisos sin pedirlos (para actualizar la UI al volver de settings)
  Future<void> _checkPermissionsStatusOnly() async {
    final status = _getRequiredPermissions();
    bool allGranted = true;

    for (var perm in status) {
      if (!await perm.isGranted) {
        allGranted = false;
        break;
      }
    }

    if (mounted && allGranted != _permissionsGranted) {
      setState(() {
        _permissionsGranted = allGranted;
      });
      if (allGranted) {
        _initNetworkListener();
        _startScan();
      }
    }
  }

  List<Permission> _getRequiredPermissions() {
    // Definir permisos según plataforma si es necesario
    if (Platform.isAndroid) {
      return [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, // Requerido para SSID en Android < 12 o hardware legacy
      ];
    } else {
      return [
        Permission.bluetooth,
        Permission.location, // iOS a veces requiere ubicación para ciertos metadatos wifi
      ];
    }
  }

  Future<bool> _checkAndRequestPermissions() async {
    final permissions = _getRequiredPermissions();

    // 1. Solicitamos los permisos
    Map<Permission, PermissionStatus> statuses = await permissions.request();

    bool allGranted = statuses.values.every((status) => status.isGranted);
    bool anyPermanentlyDenied = statuses.values.any((status) => status.isPermanentlyDenied);

    if (mounted) {
      setState(() {
        _permissionsGranted = allGranted;
      });
    }

    if (allGranted) {
      return true;
    }

    // 2. Manejo de denegación permanente
    if (anyPermanentlyDenied && mounted) {
      _showSettingsDialog();
      return false;
    }

    // 3. Manejo de denegación simple (el usuario dijo "No" esta vez)
    if (!allGranted && mounted) {
      _showSnackBar('Permissions are required to scan and connect.', isError: true);
    }

    return false;
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Permissions Required'),
        content: const Text(
            'Bluetooth and Location permissions are permanently denied. '
                'Please enable them in the app settings to use this feature.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings(); // Abre la configuración del sistema
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // GESTIÓN DE RED (IP y WIFI)
  // ---------------------------------------------------------------------------

  void _initNetworkListener() {
    // Guard clause: Si no hay permisos, no escuchar.
    if (!_permissionsGranted) return;

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) async {
      await Future.delayed(const Duration(seconds: 2));
      _updateNetworkInfo();
    });
    _updateNetworkInfo();
  }

  Future<void> _updateNetworkInfo() async {
    if (!_permissionsGranted) return;

    final info = NetworkInfo();
    String? wifiName = await info.getWifiName();
    String? ip = await info.getWifiIP();

    ip ??= await getLocalIpAddress();

    if (wifiName != null) {
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
  // GESTIÓN DE BLUETOOTH
  // ---------------------------------------------------------------------------

  Future<bool> checkBluetoothStatus() async {
    // Verificar el estado actual inmediatamente
    var state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return true;

    // Si está apagado, intentar encenderlo
    try {
      await FlutterBluePlus.turnOn();

      // 3. IMPORTANTE: Esperar a que el estado cambie a 'on'
      // Usamos firstWhere para pausar la ejecución hasta que detectemos el cambio
      state = await FlutterBluePlus.adapterState.firstWhere(
            (s) => s == BluetoothAdapterState.on,
      ).timeout(const Duration(seconds: 5)); // Damos 5 segundos máximo para que prenda

      return state == BluetoothAdapterState.on;

    } catch (e) {
      return false;
    }
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<void> startSafeScan() async {
    // Secuencia de limpieza estricta para evitar "could not find callback wrapper"
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      // El "Respiro" vital para Android
      await Future.delayed(const Duration(seconds: 1));

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      rethrow;
    }
  }

  void _startScan() async {
    if (_isScanning) return;

    if (!_permissionsGranted) {
      // Intenta pedir permisos nuevamente si el usuario intenta escanear
      bool granted = await _checkAndRequestPermissions();
      if (!granted) return;
    }

    bool bleEnabled = await checkBluetoothStatus();
    if (!bleEnabled) {
      if (mounted) _showSnackBar('Bluetooth is disabled', isError: true);
      return;
    }

    setState(() {
      _isScanning = true;
    });

    try {
      await _scanSub?.cancel();
      _scanSub = null;

      // Reiniciar escaneo limpio
      await startSafeScan();

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
      if (mounted) _showSnackBar('Scan failed: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
        // Asegurar parada
        if (FlutterBluePlus.isScanningNow) FlutterBluePlus.stopScan();
      }
    }
  }

  Future<void> sendBLEConfig(BluetoothDevice device, String ssid,
      String password, String host, int port, String protocol) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connecting to BLE device...')),
    );

    try {
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
      await getChar(charProtoUUID).write(utf8.encode(protocol), withoutResponse: false);
      await getChar(charActionUUID).write(utf8.encode("SAVE"), withoutResponse: false);

      await device.disconnect();
    } catch(_) {}
    finally {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Credentials sent to ${device.platformName}. Waiting for $protocol...')),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // LÓGICA DE PROVISIONAMIENTO (ESP32)
  // ---------------------------------------------------------------------------

  Future<void> _provisionDevice(BluetoothDevice device, String ssid,
      String password, String host, int port, String protocol) async {
    if (!mounted) return;

    StreamSubscription? connectionSubscription;
    final connectionCompleter = Completer<bool>();

    try {
      // Espera de conexión
      if (protocol.toUpperCase() == 'TCP') {
        connectionSubscription = TCPConn().onClientConnected.listen((socket) {
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.complete(true);
          }
        });
      } else if (protocol.toUpperCase() == 'UDP') {
        connectionSubscription = UDPConn().onClientConnected.listen((clientId) {
          if (!connectionCompleter.isCompleted) {
            connectionCompleter.complete(true);
          }
        });
      }

      await sendBLEConfig(device, ssid, password, host, port, protocol);

      await connectionCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException("$protocol connection timed out."),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Device connected via $protocol!'), backgroundColor: Colors.green),
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
      connectionSubscription?.cancel();
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
    String selectedProtocol = 'TCP';

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
                DropdownButtonFormField<String>(
                  initialValue: selectedProtocol,
                  items: const [
                    DropdownMenuItem(value: 'TCP', child: Text('TCP')),
                    DropdownMenuItem(value: 'UDP', child: Text('UDP')),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      selectedProtocol = value ?? 'TCP';
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Protocol',
                    border: OutlineInputBorder(),
                  ),
                ),
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
                await _provisionDevice(device, ssid, password, host, port, selectedProtocol);
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
    String selectedProtocol = 'TCP'; // Default to TCP

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
                DropdownButtonFormField<String>(
                  initialValue: selectedProtocol,
                  items: const [
                    DropdownMenuItem(value: 'TCP', child: Text('TCP')),
                    DropdownMenuItem(value: 'UDP', child: Text('UDP')),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      selectedProtocol = value ?? 'TCP';
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Protocol',
                    border: OutlineInputBorder(),
                  ),
                ),
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

                await _provisionMultipleDevices(devicesToProvision, ssid, password, host, port, selectedProtocol);
              },
              child: const Text('Save & Connect'),
            ),
          ],
        ),
      ),
    );
  }

  // Provision multiple devices sequentially
  Future<void> _provisionMultipleDevices(List<BluetoothDevice> devices, String ssid, String password, String host, int port, protocol) async {
    if (devices.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Provisioning ${devices.length} devices in parallel...')),
    );

    // Helper for per-device provisioning with timeout and error capture
    Future<Map<String, dynamic>> provisionOne(BluetoothDevice dev) async {
      try {
        await _provisionDevice(dev, ssid, password, host, port, protocol)
            .timeout(const Duration(seconds: 30));
        return {'id': dev.remoteId.str, 'name': dev.platformName, 'success': true};
      } catch (e) {
        return {'id': dev.remoteId.str, 'name': dev.platformName, 'success': false, 'error': e.toString()};
      }
    }

    // Run all in parallel
    final results = await Future.wait(devices.map(provisionOne));

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
    // Verificar si está cargando permisos
    if (_isCheckingPermissions) {
      return const Center(child: CircularProgressIndicator());
    }
    // SI NO HAY PERMISOS, MOSTRAMOS PANTALLA DE BLOQUEO UI
    if (!_permissionsGranted) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
                'Permissions Required',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'We need Bluetooth and Location access to scan for sensors and WiFi info.',
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _checkAndRequestPermissions,
              child: const Text('Grant Permissions'),
            )
          ],
        ),
      );
    }

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
                onPressed: _isScanning ? null : () => _startScan(),
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
              separatorBuilder: (_, __) => const Divider(color: Colors.white10),
              itemBuilder: (context, index) {
                final device = _devices[index];
                final id = device.remoteId.str;
                final isSelected = _selectedIds.contains(id);

                return ListTile(
                  onLongPress: () {
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
                );
              },
            ),
          ),
          if (_selectionMode)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: Center(
                child: ElevatedButton(
                    onPressed: _selectedIds.isEmpty ? null : _showBulkConfigDialog,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                    child: Text('Setup Selection (${_selectedIds.length})')
                ),
              ),
            ),
        ],
      ),
    );
  }
}