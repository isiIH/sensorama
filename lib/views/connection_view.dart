import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../services/permission_service.dart';
import '../services/network_service.dart';
import '../services/ble_service.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> with WidgetsBindingObserver {
  // Services
  final _permissionService = PermissionService();
  final _networkService = NetworkService();
  final _provisioner = BleProvisioner();

  // State
  String? _localIp;
  String? _wifiName;
  final int _port = int.parse(dotenv.env['PORT']!);
  bool _permissionsGranted = false;
  bool _isScanning = false;

  // Data
  final List<BluetoothDevice> _devices = [];
  final Set<String> _selectedIds = {};
  bool _selectionMode = false;
  bool _isCheckingPermissions = true;

  // Streams
  StreamSubscription? _scanSub;
  StreamSubscription? _netSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSequence();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _netSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissionsSilent(); // Re-chequear al volver de Settings
    }
  }

  // --- Lógica de Inicio ---

  Future<void> _initSequence() async {
    bool granted = await _permissionService.checkPermissionsStatus();
    if (!granted) {
      granted = await _permissionService.requestPermissions();
    }

    if (mounted) {
      setState(() {
        _isCheckingPermissions = false;
        _permissionsGranted = granted;
      });
      if (granted) {
        _startNetworkListener();
        _startScan();
      }
    }
  }

  Future<void> _checkPermissionsSilent() async {
    bool granted = await _permissionService.checkPermissionsStatus();
    if (granted != _permissionsGranted && mounted) {
      setState(() => _permissionsGranted = granted);
      if (granted) {
        _startNetworkListener();
        _startScan();
      }
    }
  }

  // --- Red ---

  void _startNetworkListener() {
    _netSub = _networkService.onConnectivityChanged.listen((_) async {
      await Future.delayed(const Duration(seconds: 2)); // Wait for IP assignment
      if(mounted) _refreshNetworkInfo();
    });
    _refreshNetworkInfo();
  }

  Future<void> _refreshNetworkInfo() async {
    final info = await _networkService.getCurrentNetworkInfo();
    if (mounted) {
      setState(() {
        _localIp = info.ip;
        _wifiName = info.wifiName;
      });
    }
  }

  // --- Bluetooth Scanning ---

  Future<void> _startScan() async {
    if (_isScanning) return;

    // Verificar estado del adaptador
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        if(mounted) _showSnack('Bluetooth is off', isError: true);
        return;
      }
    }

    if (mounted) {
      setState(() {
        _isScanning = true;
        _devices.clear();
      });
    }

    try {
      await _scanSub?.cancel();

      // Escucha de resultados
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        for (final r in results) {
          // Filtrado optimizado
          if (r.device.platformName.toLowerCase().startsWith('sensor-')) {
            _addDevice(r.device);
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

      // Wait for scan to complete naturally via library or timeout
      await Future.delayed(const Duration(seconds: 15));

    } catch (e) {
      if(mounted) _showSnack('Scan Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  void _addDevice(BluetoothDevice device) {
    if (!_devices.any((d) => d.remoteId == device.remoteId)) {
      setState(() {
        _devices.add(device);
      });
    }
  }

  // --- Provisioning Handlers ---

  Future<void> _handleProvisioning(List<BluetoothDevice> targets, String ssid, String pass, String host, int port, String protocol) async {
    // UI Feedback
    Navigator.of(context).pop(); // Cerrar diálogo
    _showSnack('Provisioning ${targets.length} devices...');

    // Lógica paralela optimizada
    final futures = targets.map((d) => _provisioner.provisionDevice(
        device: d, ssid: ssid, password: pass, host: host, port: port, protocol: protocol
    ).then((_) => true).catchError((e) {
      debugPrint("Error on ${d.platformName}: $e");
      return false;
    }));

    final results = await Future.wait(futures);
    final successCount = results.where((r) => r).length;

    if (!mounted) return;

    if (successCount == targets.length) {
      _showSnack('All devices connected successfully!', isError: false);
      setState(() {
        _selectionMode = false;
        _selectedIds.clear();
      });
      _startScan(); // Rescanear
    } else {
      _showSnack('Finished with errors. Success: $successCount/${targets.length}', isError: true);
    }
  }

  // --- UI Helpers ---

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : Colors.green,
    ));
  }

  void _showConfigDialog({required List<BluetoothDevice> targets}) {
    final ssidCtrl = TextEditingController(text: _wifiName ?? '');
    final passCtrl = TextEditingController();
    final hostCtrl = TextEditingController(text: _localIp ?? '');
    final portCtrl = TextEditingController(text: _port.toString());
    String proto = 'TCP';
    bool passVisible = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Setup ${targets.length} device${targets.length > 1 ? 's' : ''}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: proto,
                  items: const [
                    DropdownMenuItem(value: 'TCP', child: Text('TCP')),
                    DropdownMenuItem(value: 'UDP', child: Text('UDP')),
                  ],
                  onChanged: (v) => setDialogState(() => proto = v!),
                  decoration: const InputDecoration(labelText: 'Protocol'),
                ),
                const SizedBox(height: 10),
                TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: 'Host IP')),
                const SizedBox(height: 10),
                TextField(controller: portCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port')),
                const SizedBox(height: 10),
                TextField(controller: ssidCtrl, decoration: const InputDecoration(labelText: 'Wifi SSID')),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: !passVisible,
                  decoration: InputDecoration(
                      labelText: 'Wifi Password',
                      suffixIcon: IconButton(
                        icon: Icon(passVisible ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setDialogState(() => passVisible = !passVisible),
                      )
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () {
                setState(() {
                _selectionMode = false;
                _selectedIds.clear();
                });
                Navigator.pop(ctx);
              }, child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                _handleProvisioning(
                    targets,
                    ssidCtrl.text,
                    passCtrl.text,
                    hostCtrl.text,
                    int.tryParse(portCtrl.text) ?? _port,
                    proto
                );
              },
              child: const Text('Connect'),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Verificar si está cargando permisos
    if (_isCheckingPermissions) {
      return const Center(child: CircularProgressIndicator());
    }
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
              onPressed: _permissionService.openSettings,
              child: const Text('Grant Permissions'),
            )
          ],
        ),
      );
    }

    return Scaffold( // He envuelto en Scaffold para que funcione el SnackBar correctamente si este es el root
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Info Card
            Card(
              color: Colors.white10,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    _infoRow(Icons.wifi, "WiFi: ${_wifiName ?? '---'}"),
                    _infoRow(Icons.computer, "Host: ${_localIp ?? '---'}"),
                    _infoRow(Icons.numbers, "Port: $_port"),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Header Lista
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_selectionMode)
                  Checkbox(value: _selectedIds.length == _devices.length,
                      onChanged: (_) => setState(() {
                        if (_selectedIds.length == _devices.length) {
                          _selectedIds.clear();
                          _selectionMode = false;
                        } else {
                          _selectedIds.clear();
                          for (var d in _devices) {
                            _selectedIds.add(d.remoteId.str);
                          }
                        }
                    })),
                Text('Available Sensors',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                  onPressed: _isScanning ? null : () => _startScan(),
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Rescan',
                )
              ],
            ),

            // Lista
            Expanded(
              child: ListView.separated(
                itemCount: _devices.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (_, i) {
                  final dev = _devices[i];
                  final selected = _selectedIds.contains(dev.remoteId.str);
                  return ListTile(
                    title: Text(dev.platformName),
                    subtitle: Text(dev.remoteId.str),
                    leading: _selectionMode
                        ? Checkbox(value: selected, onChanged: (_) => _toggleSelection(dev.remoteId.str))
                        : const Icon(Icons.bluetooth),
                    onLongPress: () => _toggleSelection(dev.remoteId.str),
                    onTap: () {
                      if(_selectionMode) {
                        _toggleSelection(dev.remoteId.str);
                      } else {
                        _showConfigDialog(targets: [dev]);
                      }
                    },
                  );
                },
              ),
            ),

            // Botón Bulk Action
            if (_selectionMode)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.settings_input_antenna),
                  label: Text('Setup (${_selectedIds.length})'),
                  onPressed: _selectedIds.isEmpty ? null : () {
                    final targets = _devices.where((d) => _selectedIds.contains(d.remoteId.str)).toList();
                    _showConfigDialog(targets: targets);
                  },
                ),
              )
          ],
        ),
      ),
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      _selectionMode = _selectedIds.isNotEmpty;
    });
  }

  Widget _infoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [Icon(icon, size: 16), const SizedBox(width: 8), Text(text)]),
    );
  }
}