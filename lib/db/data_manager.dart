import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:isar/isar.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

import 'models.dart';

class DataManager {
  // Singleton para acceder fácil desde cualquier lado
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  late Future<Isar> db;
  bool _isUploading = false;

  // Configuración de envío de datos
  final int batchSize = 50;
  final Duration syncInterval = Duration(seconds: 60);
  Timer? _syncTimer;

  Future<void> init() async {
    db = _openDB();

    await _findCrashedSessions();

    Connectivity().onConnectivityChanged.listen((result) {
      if (!result.contains(ConnectivityResult.none)) {
        debugPrint("Conexión detectada: Reintentando envíos pendientes...");
        _flush(sendAll: true);
      }
    });
  }

  Future<void> _findCrashedSessions() async {
    final isar = await db;

    final crashedSessions = await isar.sessions
        .filter()
        .isFinishedEqualTo(false)
        .findAll();

    if (crashedSessions.isNotEmpty) {
      debugPrint("Se encontraron ${crashedSessions.length} sesiones sin cerrar. Cerrándolas...");

      await isar.writeTxn(() async {
        for (var session in crashedSessions) {
          session.isFinished = true; // Forzamos el cierre
          await isar.sessions.put(session);
        }
      });
    }
  }

  void _resetSyncTimer() {
    // Si ya hay uno corriendo, no creamos otro
    if (_syncTimer?.isActive ?? false) return;

    _syncTimer = Timer(syncInterval, () {
      debugPrint("Inactividad detectada. Forzando limpieza...");
      _flush(sendAll: true);
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

  // Sincronización
  Future<void> _flush({bool sendAll = false}) async {
    if (_isUploading) return;

    // Chequeo rápido de conexión antes de enviar a la DB
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity[0] == ConnectivityResult.none) {
      debugPrint("No hay conexión a Internet.");
      return;
    }

    _isUploading = true;
    _syncTimer?.cancel();
    final isar = await db;

    try {
      while(true) {
        // Obtener el bloque más antiguo (FIFO)
        final batch = await isar.sessionDatas
            .where()
            .sortBySessionId()
            .limit(batchSize)
            .findAll();

        if (batch.isEmpty) {
          debugPrint("La base de datos está vacía");
          return;
        }

        bool isPartialBatch = batch.length < batchSize;

        if(!sendAll && isPartialBatch) {
          debugPrint("No hay suficientes datos para enviar");
          return;
        }

        // Agrupar por sesión (Map<SessionId, List<Payload>>)
        final Map<int, List<SessionData>> batches = {};

        for (var item in batch) {
          if (!batches.containsKey(item.sessionId)) {
            batches[item.sessionId] = [];
          }
          batches[item.sessionId]!.add(item);
        }

        // Procesar y enviar cada sesión
        for (final sessionId in batches.keys) {
          // Obtener info del paciente
          final session = await isar.sessions.get(sessionId);

          // Obtener datos (payload)
          List<SessionData> data = batches[sessionId]!;
          final payloadList = batches[sessionId]!.map((e) => e.data).toList();

          // Preparar "Sobre" (Envelope)
          final Map<String, dynamic> packet = {
            'p': session!.patientName,
            't': session.createdAt!.millisecondsSinceEpoch,
            'd': payloadList, // List<List<int>>
          };

          // Serializar y Comprimir
          final packed = msgpack.serialize(packet);
          final compressed = GZipCodec().encode(packed);

          // D. Intentar Enviar
          bool success = await _sendToServer(compressed);

          if (success) {
            // ÉXITO: Borrar de local
            await _deleteData(data, sessionId);
            debugPrint(
                "Lote $sessionId de ${payloadList.length} enviado y borrado.");
          } else {
            // FALLO: Reintentar en otro momento
            debugPrint("Fallo al subir. Reintentando luego...");
            _resetSyncTimer();
            return;
          }
        }

        // Base de datos vacía
        if(sendAll && isPartialBatch) return;
      }
    } catch (e) {
      debugPrint("Error crítico en sync: $e");
      _resetSyncTimer();
    } finally {
      _isUploading = false;
    }
  }

  // Inicializar sesión (Header)
  Future<int> startSession(String patientName) async {
    final isar = await db;
    final session = Session()
      ..patientName = patientName
      ..createdAt = DateTime.now();

    late int sessionId;
    await isar.writeTxn(() async {
      sessionId = await isar.sessions.put(session);
    });

    return sessionId;
  }

  // Agregar paquetes de datos (Body)
  Future<void> addData(int sessionId, List<int> rawData) async {
    if(sessionId == 0) return;

    final isar = await db;

    final packet = SessionData()
      ..sessionId = sessionId
      ..data = rawData;

    await isar.writeTxn(() async {
      await isar.sessionDatas.put(packet);
    });

    if (await isar.sessionDatas.count() >= batchSize) {
      debugPrint("Límite de datos alcanzado. Enviando...");
      _flush();
    }
  }

  // Finalizar sesión y enviar al backend
  Future<void> stopSession(int sessionId) async {
    final isar = await db;

    final session = await isar.sessions.get(sessionId);
    if(session != null) {
      session.isFinished = true; // Marcamos como terminada

      await isar.writeTxn(() async {
        await isar.sessions.put(session);
      });
    }

    await _flush(sendAll: true); // Enviar lo que quede pendiente
  }

  Future<void> _deleteData(List<SessionData> batch, int sessionId) async {
    final isar = await db;

    // eliminar sensorData
    final idsToDelete = batch
        .map((e) => e.id)
        .toList();
    await isar.writeTxn(() async {
      await isar.sessionDatas.deleteAll(idsToDelete);
    });

    // Contamos cuántos datos quedan para esta sesión
    final remainingCount = await isar.sessionDatas
        .filter()
        .sessionIdEqualTo(sessionId)
        .count();

    // Obtenemos la cabecera para ver si ya terminó
    final sessionHeader = await isar.sessions.get(sessionId);

    // CONDICIÓN DE ORO:
    if (remainingCount == 0 && (sessionHeader?.isFinished == true)) {
      debugPrint("Limpieza total: Borrando cabecera de sesión $sessionId");

      await isar.writeTxn(() async {
        await isar.sessions.delete(sessionId);
      });
    }
  }

  // Post de datos al backend
  Future<bool> _sendToServer(List<int> bodyBytes) async {
    try {
      final response = await http.post(
        Uri.parse('http://192.168.4.228:8000/upload'),
        headers: {
          'Content-Type': 'application/x-msgpack',
          'Content-Encoding': 'gzip',
        },
        body: bodyBytes
      ).timeout(Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {

      debugPrint("Error de red: $e");
      return false;
    }
  }
}