import 'dart:io';
import 'package:flutter/foundation.dart';
import 'protocol.dart';

class UDPConn extends Protocol {
  // Singleton Pattern
  static final UDPConn _instance = UDPConn._internal();
  factory UDPConn() => _instance;
  UDPConn._internal() : super('UDP');

  @override
  void handleConnection(dynamic event) {
    // For RawDatagramSocket, event is a RawSocketEvent
    if (event != RawSocketEvent.read) return;
    
    try {
      final datagram = (server as RawDatagramSocket).receive();
      if (datagram == null) return;

      final Uint8List data = datagram.data;

      // --- PROCESAMIENTO BINARIO ---
      if (data.length < Protocol.dataHeaderSize) {
        debugPrint('⚠️ Paquete UDP descartado: Tamaño insuficiente (${data.length} bytes)');
        return;
      }

      try {
        // Process packet with sender info for ACK handling
        processPacket(
          data,
          senderAddress: datagram.address,
          senderPort: datagram.port,
        );
      } catch (e) {
        debugPrint('❌ Error decodificando binario UDP: $e');
      }

    } catch (e) {
      debugPrint('Error general UDP: $e');
    }
  }
}