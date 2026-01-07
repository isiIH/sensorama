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
    // Process packets while we have enough data
    while (buffer.length >= Protocol.dataHeaderSize) {
      Uint8List currentBytes = buffer.toBytes();
      
      // Need at least 7 bytes to read MAC + packet type
      if (currentBytes.length < 7) break;
      
      // Read packet type at offset 6 (after MAC address)
      final int packetType = currentBytes[6];
      int? totalPacketSize;

      try {
        if (packetType == Protocol.packetTypeMetadata) {
          // Metadata packet (type 0x00)
          if (currentBytes.length < Protocol.metadataHeaderSize) break;
          
          final headerView = ByteData.sublistView(currentBytes, 0, Protocol.metadataHeaderSize);
          // Dimensions offset: MAC(6) + Type(1) + Freq(2) + Samples(2) = 11
          int mDims = headerView.getInt8(11);
          
          // Validate dimensions
          if (mDims <= 0 || mDims > 20) {
            debugPrint('⚠️ [TCP] Invalid dimensions in metadata: $mDims, skipping byte');
            _skipOneByte(buffer, currentBytes);
            continue;
          }
          
          // Metadata size: Header(18) + Labels(dims*4) + Units(dims*4) + MinSignals(dims*4) + MaxSignals(dims*4)
          totalPacketSize = Protocol.metadataHeaderSize + (mDims * 4 * 4);
          debugPrint('📦 [TCP] Metadata packet detected: dims=$mDims, totalSize=$totalPacketSize');
          
        } else if (packetType == Protocol.packetTypeData) {
          // Data packet (type 0x01)
          final macBytes = currentBytes.sublist(0, 6);
          String macAddress = macBytes
              .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
              .join(':');
          
          final metadata = getMetadataForMac(macAddress);
          if (metadata == null) {
            // No metadata yet - can't process data packet, wait
            debugPrint('⚠️ [TCP] No metadata for $macAddress - waiting');
            break;
          }
          
          int dataSize = metadata.samplesPerPacket * metadata.dimensions * 2;
          totalPacketSize = Protocol.dataHeaderSize + dataSize;
          
        } else {
          // Unknown packet type - this could mean:
          // 1. We're misaligned in the stream
          // 2. Legacy packet format
          // 3. Corrupted data
          
          // Try to detect if this might be a valid data packet by checking MAC
          final macBytes = currentBytes.sublist(0, 6);
          String macAddress = macBytes
              .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
              .join(':');
          
          final metadata = getMetadataForMac(macAddress);
          
          if (metadata != null) {
            // We have metadata for this MAC but unknown packet type
            // This is likely a misalignment issue - skip one byte and retry
            debugPrint('⚠️ [TCP] Unknown packet type ($packetType) for known MAC $macAddress - realigning');
            _skipOneByte(buffer, currentBytes);
            continue;
          }
          
          // Try legacy format as fallback
          if (currentBytes.length < Protocol.legacyHeaderSize) break;
          
          final headerView = ByteData.sublistView(currentBytes, 0, Protocol.legacyHeaderSize);
          int nSamples = headerView.getInt16(8, Endian.little);
          int mDims = headerView.getInt8(10);
          
          // Validate legacy header values
          if (nSamples <= 0 || nSamples > 10000 || mDims <= 0 || mDims > 20) {
            debugPrint('⚠️ [TCP] Invalid legacy header (samples=$nSamples, dims=$mDims) - skipping byte');
            _skipOneByte(buffer, currentBytes);
            continue;
          }
          
          int dataSize = nSamples * mDims * 2;
          int metaSize = (mDims * 4) + (mDims * 4);
          totalPacketSize = Protocol.legacyHeaderSize + dataSize + metaSize;
        }

        // Validate packet size
        if (totalPacketSize == null || totalPacketSize <= 0 || totalPacketSize > 100000) {
          debugPrint('⚠️ [TCP] Invalid packet size: $totalPacketSize - skipping byte');
          _skipOneByte(buffer, currentBytes);
          continue;
        }

        // Check if we have the complete packet
        if (buffer.length >= totalPacketSize) {
          Uint8List packetBytes = currentBytes.sublist(0, totalPacketSize);

          // Process the packet
          try {
            processPacket(packetBytes);
            // Note: connectionController is updated inside processPacket for both
            // metadata and data packets, so we don't need to add it here
          } catch (e) {
            debugPrint('❌ [TCP] Error processing packet: $e');
          }

          // Remove processed packet from buffer
          Uint8List remaining = currentBytes.sublist(totalPacketSize);
          buffer.clear();
          buffer.add(remaining);
        } else {
          // Wait for more data
          break;
        }
      } catch (e) {
        debugPrint('❌ [TCP] Error in buffer processing: $e - skipping byte');
        _skipOneByte(buffer, currentBytes);
      }
    }
  }

  /// Skip one byte to try to realign with packet boundaries
  void _skipOneByte(BytesBuilder buffer, Uint8List currentBytes) {
    if (currentBytes.length > 1) {
      Uint8List remaining = currentBytes.sublist(1);
      buffer.clear();
      buffer.add(remaining);
    } else {
      buffer.clear();
    }
  }
}
