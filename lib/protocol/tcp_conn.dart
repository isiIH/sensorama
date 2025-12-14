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
    // Mientras tengamos al menos el tamaño de un header, intentamos leer
    while (buffer.length >= Protocol.headerSize) {
      Uint8List currentBytes = buffer.toBytes();
      final headerView = ByteData.sublistView(currentBytes, 0, Protocol.headerSize);

      int nSamples = headerView.getInt16(8, Endian.little);
      int mDims = headerView.getInt8(10);

      // Calculamos el tamaño total que DEBERÍA tener el paquete
      // Header (21) + Data (nSamples * mDims * 2) + Labels (mDims * 4) + Units (mDims * 4)
      int dataSize = nSamples * mDims * 2;
      int metaSize = (mDims * 4) + (mDims * 4);
      int totalPacketSize = Protocol.headerSize + dataSize + metaSize;

      // VERIFICACIÓN: ¿Tenemos el paquete completo en el buffer?
      if (buffer.length >= totalPacketSize) {
        Uint8List packetBytes = currentBytes.sublist(0, totalPacketSize);

        // Procesamos el paquete y notificamos
        decodePacket(packetBytes);

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