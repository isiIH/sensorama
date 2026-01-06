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
    try {
      final datagram = server!.receive();
      if (datagram == null) return;

      final Uint8List data = datagram.data;

      // --- PROCESAMIENTO BINARIO ---
      if (data.length < Protocol.dataHeaderSize) {
        debugPrint('⚠️ Paquete descartado: Tamaño insuficiente (${data.length} bytes)');
        return;
      }

      try {
        // Process packet with sender info for ACK handling
        processPacket(
          data,
          senderAddress: datagram.address,
          senderPort: datagram.port,
        );
        
        // Only add to connection controller if we have a valid packet
        // (metadata packets also trigger this)
        if (hasMetadataForMac(currentPacket.macAddress)) {
          connectionController.add(currentPacket.macAddress);
        }
      } catch (e) {
        debugPrint('❌ Error decodificando binario: $e');
      }

    } catch (e) {
      debugPrint('Error general UDP: $e');
    }
  }
}