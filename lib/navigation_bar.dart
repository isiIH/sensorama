import 'package:flutter/material.dart';

import 'tcp_conn.dart';
import 'udp_conn.dart';
import 'ble.dart';
import 'dashboard.dart';

class NavigationBarScreen extends StatefulWidget {
  const NavigationBarScreen({super.key});

  @override
  State<NavigationBarScreen> createState() => _NavigationBarScreenState();
}

class _NavigationBarScreenState extends State<NavigationBarScreen> {
  int _selectedIndex = 1; // 0 = BLE Connection, 1 = Graph
  late final TCPConn _tcpServer;
  late final UDPConn _udpServer;

  @override
  void initState() {
    super.initState();
    _tcpServer = TCPConn();
    _udpServer = UDPConn();
    _tcpServer.start();
    _udpServer.start();
  }

  @override
  void dispose() {
    // TODO: implement dispose
    super.dispose();
    _tcpServer.stop();
    _udpServer.stop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Sensorama"),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
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