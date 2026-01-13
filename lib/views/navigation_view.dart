import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../protocol/tcp_conn.dart';
import '../protocol/udp_conn.dart';
import '../protocol/ble_conn.dart';
import 'real_time_chart.dart';
import 'connection_view.dart';
import 'record_button.dart';
import '../db/data_manager.dart';

class NavigationBarScreen extends StatefulWidget {
  const NavigationBarScreen({super.key});

  @override
  State<NavigationBarScreen> createState() => _NavigationBarScreenState();
}

class _NavigationBarScreenState extends State<NavigationBarScreen> {
  int _selectedIndex = 1; // 0 = BLE Connection, 1 = Graph
  final List<Protocol> connections = [
    TCPConn(),
    UDPConn(),
    BLEConn(),
  ];
  final dataManager = DataManager.instance;

  @override
  void initState() {
    super.initState();
    dataManager.init(); // Inicializar DB
    for(Protocol conn in connections) {
      conn.start();
    }
  }

  @override
  void dispose() {
    // TODO: implement dispose
    super.dispose();
    for(Protocol conn in connections) {
      conn.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Sensorama"),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      floatingActionButton: RecordButton(connections: connections),
      floatingActionButtonLocation: FloatingActionButtonLocation.endTop,
      body: _selectedIndex == 0 ? ConnectionScreen() : RealTimeChart(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int idx) {
          setState(() {
            _selectedIndex = idx;
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.wifi), label: 'Connection'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Chart'),
        ],
      ),
    );
  }
}