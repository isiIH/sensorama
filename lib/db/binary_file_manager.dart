import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';

class BinaryFileManager {

  // Obtener la ruta local del dispositivo
  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  // Agregar bytes al final del archivo
  Future<void> writeChunk(String fileName, Uint8List data) async {
    final path = await _localPath;
    final file = File('$path/$fileName');

    await file.writeAsBytes(data, mode: FileMode.append);
    debugPrint('Bloque escrito en $fileName. Tamaño actual: ${await file.length()} bytes');
  }

  // Obtener los datos para enviarlos al servidor
  Future<Uint8List?> getFile(String fileName) async {
    try {
      final path = await _localPath;
      final file = File('$path/$fileName');

      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e) {
      debugPrint("Error al leer: $e");
    }
    return null;
  }

  // Borrar tras recibir confirmación del servidor
  Future<void> deleteFile(String fileName) async {
    final path = await _localPath;
    final file = File('$path/$fileName');

    if (await file.exists()) {
      await file.delete();
      debugPrint('Archivo $fileName eliminado exitosamente.');
    }
  }
}