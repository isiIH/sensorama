import 'package:flutter/foundation.dart';
import 'protocol.dart';

class UDPConn extends Protocol {
  // Singleton Pattern
  static final UDPConn _instance = UDPConn._internal();
  factory UDPConn() => _instance;
  UDPConn._internal() : super('UDP');

  @override
  void handleConnection(dynamic event) {
    try {
      final datagram = server!.receive();
      if (datagram == null) return;

      final Uint8List data = datagram.data;

      // --- PROCESAMIENTO BINARIO ---
      if (data.length < Protocol.headerSize) {
        debugPrint('⚠️ Paquete descartado: Tamaño insuficiente (${data.length} bytes)');
        return;
      }

      try {
        // Procesamos el paquete y notificamos
        decodePacket(data);
        connectionController.add(currentPacket.macAddress);
      } catch (e) {
        debugPrint('❌ Error decodificando binario: $e');
      }

    } catch (e) {
      debugPrint('Error general UDP: $e');
    }
  }
}