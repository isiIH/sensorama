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
  final _bleService = BleService();

  // State
  String? _localIp;
  String? _wifiName;
  final int _port = int.parse(dotenv.env['PORT']!);
  bool _permissionsGranted = false;

  // Data
  final Set<String> _selectedIds = {};
  bool get _selectionMode => _selectedIds.isNotEmpty;
  bool _isScanning = true;
  late bool _isCheckingPermissions = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    FlutterBluePlus.isScanning.listen((state) {
      if (mounted) {
        setState(() => _isScanning = state);
      }
    });

    _initSequence();
  }

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_permissionsGranted) {
        _checkPermissionsSilent();
      }
    }
  }

// --- Lógica de Inicio (Reestructurada) ---

  Future<void> _initSequence() async {
    // 1. Chequeo inicial
    bool granted = await _permissionService.checkPermissionsStatus();

    if (granted) {
      if (mounted) {
        setState(() {
          _isCheckingPermissions = false;
          _permissionsGranted = granted;
        });
      }
      // Si están concedidos, procedemos con la lógica principal
      _initializeServices();
    } else {
      // 2. Si no están concedidos, pedirlos
      final requestResult = await _permissionService.requestPermissions();

      if (mounted) {
        setState(() {
          _isCheckingPermissions = false;
          _permissionsGranted = requestResult;
        });
      }

      if (requestResult) {
        // Si se conceden después de la solicitud, inicializar servicios
        _initializeServices();
      }
      // Si no se conceden, la UI mostrará el mensaje de 'Permissions Required'
    }
  }

  Future<void> _checkPermissionsSilent() async {
    // Lógica para re-chequear permisos al volver de Settings
    final granted = await _permissionService.checkPermissionsStatus();

    // Solo hacemos algo si el resultado es diferente al estado actual
    if (granted != _permissionsGranted && mounted) {
      setState(() => _permissionsGranted = granted);

      if (granted) {
        // Si los permisos fueron concedidos, iniciamos los servicios
        _initializeServices();
      }
    }
  }

  void _initializeServices() {
    _updateNetworkInfo(); // Llamada renombrada a _updateNetworkInfo
    _startScan(); // Esto llama al servicio BLE para comenzar
  }

  // --- Red ---

  void _updateNetworkInfo() {
    _networkService.onConnectivityChanged.listen((_) async {
      await Future.delayed(const Duration(seconds: 2)); // Wait for IP assignment
      if(mounted) _fetchNetworkData();
    });
    _fetchNetworkData();
  }

  Future<void> _fetchNetworkData() async {
    final info = await _networkService.getCurrentNetworkInfo();
    if (mounted) {
      setState(() {
        _localIp = info.ip;
        _wifiName = info.wifiName;
      });
    }
  }

  // --- Provisioning Handlers ---

  Future<void> _startScan() async {
    try {
      setState(() => _selectedIds.clear());
      await _bleService.startScan();
    } catch (e) {
      if(mounted) _showSnack('Error scanning devices: $e', isError: true);
    }
  }

  Future<void> _handleProvisioning(List<BluetoothDevice> targets, String ssid, String pass, String host, int port, String protocol) async {
    // UI Feedback
    Navigator.of(context).pop(); // Cerrar diálogo
    _showProcessingDialog(targets.length); // Loading

    final successCount = await _bleService.provisionBatch(
        devices: targets,
        ssid: ssid,
        password: pass,
        host: host,
        port: port,
        protocol: protocol
    );

    if (!mounted) return;
    Navigator.pop(context); // Cerrar loading dialog

    if (successCount == targets.length) {
      _showSnack('Connected successfully!');
      setState(() => _selectedIds.clear());
      _startScan(); // Rescanear para ver si desaparecen o cambian estado
    } else {
      _showSnack('Finished: $successCount/${targets.length} connected.', isError: successCount == 0);
    }
  }

  // --- UI Helpers ---

  void _showProcessingDialog(int numDevices) {
    showDialog(
      context: context,
      barrierDismissible: false, // Bloquea la interacción hasta que termine el proceso
      builder: (BuildContext context) {
        return Dialog(
          // 1. Color de Fondo Oscuro: Usamos un color oscuro para el diálogo
          backgroundColor: Colors.grey[850], // Fondo oscuro casi negro (similar a Dark Mode)
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          elevation: 16,
          child: Padding(
            padding: const EdgeInsets.all(28.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 2. Color del Indicador: Debe destacar en un fondo oscuro
                const CircularProgressIndicator(
                  strokeWidth: 4.0,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.cyan), // Color brillante (ej. cian) para contraste
                ),
                const SizedBox(height: 30),
                // 3. Texto Principal: Blanco o gris muy claro
                Text(
                  "Provisioning $numDevices device${numDevices > 1 ? 's' : ''}",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white, // Texto blanco para el modo oscuro
                  ),
                ),
                const SizedBox(height: 8),
                // 4. Texto Secundario: Un gris más claro que el fondo
                const Text(
                  "Configuration in progress, please wait.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey, // Gris medio para contraste suave
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red : Colors.green,
    ));
  }

  void _showConfigDialog({required List<BluetoothDevice> targets}) {
    final ssidCtrl = TextEditingController(text: _wifiName ?? '');
    final passCtrl = TextEditingController();
    String proto = 'TCP';
    bool passVisible = false;

    bool isSsidEmpty = ssidCtrl.text.isEmpty;
    bool ssidEnabled = isSsidEmpty;
    bool isPassEmpty = passCtrl.text.isEmpty;

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
                    DropdownMenuItem(value: 'BLE', child: Text('BLE')),
                  ],
                  onChanged: (v) => setDialogState(() => proto = v!),
                  decoration: const InputDecoration(labelText: 'Protocol'),
                ),
                const SizedBox(height: 10),
                if(proto != 'BLE') ...[
                  //TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: 'Host IP'), enabled: false),
                  //const SizedBox(height: 10),
                  //TextField(controller: portCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'), enabled: false),
                  //const SizedBox(height: 10),
                  TextField(controller: ssidCtrl,
                    decoration: InputDecoration(labelText: 'Wifi SSID', errorText: isSsidEmpty ? "SSID can't be empty" : null),
                    onChanged: (val) => setDialogState(() => isSsidEmpty = val.isEmpty),
                    enabled: ssidEnabled,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passCtrl,
                    obscureText: !passVisible,
                    onChanged: (val) => setDialogState(() => isPassEmpty = val.isEmpty),
                    decoration: InputDecoration(
                        labelText: 'Wifi Password',
                        errorText: isPassEmpty ? "Password can't be empty" : null,
                        suffixIcon: IconButton(
                          icon: Icon(passVisible ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setDialogState(() => passVisible = !passVisible),
                        )
                    ),
                  ),
                ] else ...[
                  // Para BLE, mostrar información de estado
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'BLE Direct Connection',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Data will be streamed directly via Bluetooth. No WiFi credentials needed.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () {
                setState(() {
                _selectedIds.clear();
                });
                Navigator.pop(ctx);
              }, child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if(proto != 'BLE' && (isSsidEmpty || isPassEmpty)) return;
                _handleProvisioning(
                    targets,
                    ssidCtrl.text,
                    passCtrl.text,
                    _localIp != null ? _localIp! : '',
                    _port,
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
    if (_isCheckingPermissions) return const Center(child: CircularProgressIndicator());
    if (!_permissionsGranted) return _buildPermissionRequest();

    return Scaffold(
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
          Expanded(
            child: StreamBuilder<List<BluetoothDevice>>(
            stream: _bleService.scanResults,
            initialData: _bleService.currentDevices,
                builder: (context, snapshot) {
                  final devices = snapshot.data ?? [];
                  return Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (_selectionMode)
                            Checkbox(value: _selectedIds.length == devices.length,
                                onChanged: (_) => setState(() {
                                  if (_selectedIds.length == devices.length) {
                                    _selectedIds.clear();
                                  } else {
                                    _selectedIds.clear();
                                    for (var d in devices) {
                                      _selectedIds.add(d.remoteId.str);
                                    }
                                  }
                              })),
                          Text('Available Devices',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          IconButton(
                            onPressed: _isScanning ? null : () => _startScan(),
                            icon: const Icon(Icons.refresh),
                            tooltip: 'Rescan',
                          )
                        ],
                      ),
                      const Divider(),
                      Expanded(child: _buildDeviceList(devices)),

                      // Botón Bulk Action
                      if (_selectionMode)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.settings_input_antenna),
                            label: Text('Setup (${_selectedIds.length})'),
                            onPressed: _selectedIds.isEmpty ? null : () {
                              final targets = devices.where((d) => _selectedIds.contains(d.remoteId.str)).toList();
                              _showConfigDialog(targets: targets);
                            },
                          ),
                        )
                    ]);
            }),
          ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionRequest() {
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

  Widget _buildDeviceList(List<BluetoothDevice> devices) {
    if (_isScanning && devices.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (devices.isEmpty) {
      return const Center(child: Text("No devices found.\nEnsure they are in pairing mode.", textAlign: TextAlign.center));
    }

    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final dev = devices[index];
        final isSelected = _selectedIds.contains(dev.remoteId.str);

        return ListTile(
          title: Text(dev.platformName.isNotEmpty ? dev.platformName : "Unknown Device"),
          subtitle: Text(dev.remoteId.str),
          leading: _selectionMode
              ? Checkbox(
              value: isSelected,
              onChanged: (_) => _toggleSelection(dev.remoteId.str))
              : const Icon(Icons.bluetooth),
          onLongPress: () => _toggleSelection(dev.remoteId.str),
          onTap: () {
            if (_selectionMode) {
              _toggleSelection(dev.remoteId.str);
            } else {
              _showConfigDialog(targets: [dev]);
            }
          },
        );
      },
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Widget _infoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [Icon(icon, size: 16), const SizedBox(width: 8), Text(text)]),
    );
  }
}