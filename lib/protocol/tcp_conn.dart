import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'protocol.dart';

class TCPConn extends Protocol {
  // Singleton Pattern
  static final TCPConn _instance = TCPConn._internal();
  factory TCPConn() => _instance;
  TCPConn._internal() : super('TCP');

  @override
  void handleConnection(dynamic event) {
    final Socket client = event;
    final clientAddress = client.remoteAddress.address;
    debugPrint('Nuevo cliente TCP conectado: $clientAddress');

    // Preparamos buffer para este cliente
    final BytesBuilder socketBuffer = BytesBuilder();

    // Escuchar datos
    client.listen(
          (Uint8List data) {
        socketBuffer.add(data);
        _processBuffer(client, socketBuffer);
      },
      onError: (e) {
        debugPrint('Error en socket $clientAddress: $e');
        client.close();
      },
      onDone: () {
        debugPrint('Cliente desconectado: $clientAddress');
        client.close();
      },
      cancelOnError: true,
    );
  }

  void _processBuffer(Socket client, BytesBuilder buffer) {
    // Mientras tengamos al menos el tamaño mínimo de un header, intentamos leer
    while (buffer.length >= Protocol.dataHeaderSize) {
      Uint8List currentBytes = buffer.toBytes();
      
      // Peek at packet type to determine header size
      if (currentBytes.length < 7) break;
      
      final int packetType = currentBytes[6];
      int totalPacketSize;

      if (packetType == Protocol.packetTypeMetadata) {
        // Metadata packet
        if (currentBytes.length < Protocol.metadataHeaderSize) break;
        
        final headerView = ByteData.sublistView(currentBytes, 0, Protocol.metadataHeaderSize);
        int mDims = headerView.getInt8(17); // Dimensions at offset 17
        
        // Metadata size: Header + Labels(dims*4) + Units(dims*4) + MinSignals(dims*4) + MaxSignals(dims*4)
        totalPacketSize = Protocol.metadataHeaderSize + (mDims * 4 * 4);
        
      } else if (packetType == Protocol.packetTypeData) {
        // Data packet - need metadata to know the size
        final macBytes = currentBytes.sublist(0, 6);
        String macAddress = macBytes
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(':');
        
        final metadata = getMetadataForMac(macAddress);
        if (metadata == null) {
          // No metadata yet - can't process data packet
          // Try to find a metadata packet instead or wait
          debugPrint('⚠️ [TCP] No metadata for $macAddress - waiting for metadata packet');
          break;
        }
        
        int dataSize = metadata.samplesPerPacket * metadata.dimensions * 2;
        totalPacketSize = Protocol.dataHeaderSize + dataSize;
        
      } else {
        // Try legacy format
        if (currentBytes.length < Protocol.legacyHeaderSize) break;
        
        final headerView = ByteData.sublistView(currentBytes, 0, Protocol.legacyHeaderSize);
        int nSamples = headerView.getInt16(8, Endian.little);
        int mDims = headerView.getInt8(10);
        
        int dataSize = nSamples * mDims * 2;
        int metaSize = (mDims * 4) + (mDims * 4);
        totalPacketSize = Protocol.legacyHeaderSize + dataSize + metaSize;
      }

      // VERIFICACIÓN: ¿Tenemos el paquete completo en el buffer?
      if (buffer.length >= totalPacketSize) {
        Uint8List packetBytes = currentBytes.sublist(0, totalPacketSize);

        // Process the packet using the new routing method
        processPacket(packetBytes);

        connectionController.add(currentPacket.macAddress);

        // REMOVEMOS el paquete procesado del buffer
        Uint8List remaining = currentBytes.sublist(totalPacketSize);
        buffer.clear();
        buffer.add(remaining);
      } else {
        // Salimos del while y esperamos al siguiente evento de red.
        break;
      }
    }
  }
}