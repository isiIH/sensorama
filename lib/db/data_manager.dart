import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:isar/isar.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'models.dart';
import 'binary_file_manager.dart';

class DataManager {
  // Singleton para acceder fácil desde cualquier lado
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  late Isar _isar;
  bool _isUploading = false;

  final fileManager = BinaryFileManager();
  int currentSessionId = 0;
  String currentFileName = "";

  // Configuración de envío de datos
  final int batchSize = 500;
  late int fileCounter = 0;
  final Duration syncInterval = Duration(seconds: 60);
  Timer? _syncTimer;

  Future<void> init() async {
    _isar = await _openDB();

    await _findCrashedSessions();

    Connectivity().onConnectivityChanged.listen((result) {
      if (!result.contains(ConnectivityResult.none)) {
        debugPrint("Conexión detectada: Reintentando envíos pendientes...");
        _flush();
      }
    });
  }

  Future<void> _findCrashedSessions() async {

    final crashedSessions = await _isar.sessions
        .filter()
        .isFinishedEqualTo(false)
        .findAll();

    if (crashedSessions.isNotEmpty) {
      debugPrint("Se encontraron ${crashedSessions.length} sesiones sin cerrar. Cerrándolas...");

      await _isar.writeTxn(() async {
        for (var session in crashedSessions) {
          session.isFinished = true; // Forzamos el cierre
          await _isar.sessions.put(session);
        }
      });
    }
  }

  void _resetSyncTimer() {
    // Si ya hay uno corriendo, no creamos otro
    if (_syncTimer?.isActive ?? false) return;

    _syncTimer = Timer(syncInterval, () {
      debugPrint("Inactividad detectada. Forzando limpieza...");
      _flush();
    });
  }

  Future<Isar> _openDB() async {
    final dir = await getApplicationDocumentsDirectory();
    if (Isar.instanceNames.isEmpty) {
      return await Isar.open(
        [SessionSchema, SessionDataSchema],
        directory: dir.path,
      );
    }
    return Future.value(Isar.getInstance());
  }

  /* Sincronización con el servidor, envía los datos pendientes
   */
  Future<void> _flush() async {
    if (_isUploading) return;

    // Chequeo rápido de conexión antes de enviar a la DB
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity[0] == ConnectivityResult.none) {
      debugPrint("No hay conexión a Internet.");
      return;
    }

    _isUploading = true;
    _syncTimer?.cancel();

    try {
      while(true) {
        // Obtener el bloque más antiguo (FIFO)
        final pendingChunks = await _isar.sessionDatas
            .where()
            .sortByFileName()
            .limit(batchSize)
            .findAll();

        if (pendingChunks.isEmpty) {
          debugPrint("La base de datos está vacía");
          return;
        }

        for (final chunk in pendingChunks) {
          if (chunk.fileName == currentFileName) continue;

          bool success = await _sendToServer(chunk);

          if (success) {
            // ÉXITO: Borrar de local
            await _deleteData(chunk);
            debugPrint(
                "Archivo ${chunk.fileName} enviado y borrado.");
          } else {
            // FALLO: Reintentar en otro momento
            debugPrint("Fallo al subir. Reintentando luego...");
            _resetSyncTimer();
            break;
          }
        }
      }
    } catch (e) {
      debugPrint("Error crítico en sync: $e");
      _resetSyncTimer();
    } finally {
      _isUploading = false;
    }
  }

  // Inicializar una sesión y crear el archivo binario
  Future<void> startSession(String patientName) async {
    final session = Session()
      ..patientName = patientName
      ..createdAt = DateTime.now();

    await _isar.writeTxn(() async {
      await _isar.sessions.put(session);
    });

    currentSessionId = session.id;
    fileCounter = 0;
    currentFileName = "";
  }

  // Agregar paquetes de datos al archivo binario
  Future<void> addData(Uint8List rawData) async {
    if(currentSessionId == 0) return;

    if (currentFileName.isEmpty) {
      currentFileName = 'session${currentSessionId}_${DateTime.now().millisecondsSinceEpoch}.bin';

      // Disparamos el guardado en Isar en segundo plano sin usar 'await'
      // Esto libera el hilo principal para que no haya lag.
      _createNewChunk();
    }

    fileManager.writeChunk(currentFileName, rawData);
    fileCounter++;

    // Si alcanza el límite de datos para el archivo actual, se envía
    if(fileCounter >= batchSize) {
      debugPrint("Límite de archivos alcanzado. Enviando...");
      fileCounter = 0;
      currentFileName = "";
      _flush();
    }
  }

  // Crear nueva fila de datos asociado a un archivo .bin
  Future<void> _createNewChunk() async {
    final session = await _isar.sessions.get(currentSessionId);

    final newSessionData = SessionData()
      ..session.value = session
      ..fileName = currentFileName;

    await _isar.writeTxn(() async {
      await _isar.sessionDatas.put(newSessionData);
      await newSessionData.session.save();
    });
  }

  // Finalizar sesión y enviar al backend
  Future<void> stopSession() async {
    final session = await _isar.sessions.get(currentSessionId);
    if(session != null) {
      session.isFinished = true; // Marcamos como terminada

      await _isar.writeTxn(() async {
        await _isar.sessions.put(session);
      });
    }

    currentSessionId = 0;
    currentFileName = "";

    await _flush(); // Enviar lo que quede pendiente
  }

  Future<void> _deleteData(SessionData chunk) async {
    // Eliminar chunk y archivo correspondiente de local
    await fileManager.deleteFile(chunk.fileName);
    await _isar.writeTxn(() async {
      await _isar.sessionDatas.delete(chunk.id);
    });

    // Contamos cuántos datos quedan para esta sesión
    final session = chunk.session.value!;
    final remainingCount = await session.sessionDatas.count();

    if (remainingCount == 0 && session.isFinished == true) {
      debugPrint("Limpieza total: Borrando cabecera de sesión ${session.id}");

      await _isar.writeTxn(() async {
        await _isar.sessions.delete(session.id);
      });
    }
  }

  // Post de datos al backend
  Future<bool> _sendToServer(SessionData chunk) async {
    try {
      final rawBytes = await fileManager.getFile(chunk.fileName);

      if (rawBytes == null) {
        debugPrint('El archivo no existe localmente.');
        return false;
      }

      // Comprimir archivo con gzip
      final compressedBytes = gzip.encode(rawBytes);

      final host = dotenv.env['BACKEND_HOST'];
      final port = dotenv.env['BACKEND_PORT'];
      final request = http.MultipartRequest(
          'POST',
          Uri.parse('http://$host:$port/upload')
      );

      // Metadatos cruciales para ensamblar en el backend
      request.fields['session_id'] = chunk.session.value!.id.toString();
      request.fields['chunk_id'] = chunk.id.toString();
      // Indicamos al servidor que el contenido viene comprimido
      request.fields['compression'] = 'gzip';

      // Adjuntar los bytes comprimidos como un archivo
      request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            compressedBytes,
            filename: '${chunk.fileName}.gz', // Extensión .gz para claridad
          )
      );

      // 6. Ejecutar la subida de forma eficiente
      final response = await request.send();

      return response.statusCode == 200;
    } catch (e) {

      debugPrint("Error de red: $e");
      return false;
    }
  }
}