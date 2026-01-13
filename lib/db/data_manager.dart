import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';

import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

import 'models.dart';

class DataManager {
  // Singleton para acceder fácil desde cualquier lado
  static final DataManager instance = DataManager._internal();
  DataManager._internal();

  late Future<Isar> db;

  // Variables de control
  /*Timer? _flushTimer;
  int _pendingCount = 0; // Contador de bloques en memoria/espera
  final int _batchLimit = 50;
  final Duration _timeLimit = const Duration(minutes: 1);*/

  // 1. INICIALIZACIÓN
  Future<void> init() async {
    db = _openDB();
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

  // 2. INICIAR UNA SESIÓN (Header)
  Future<int> startSession(String patientName) async {
    final isar = await db;
    final session = Session()
      ..patientName = patientName
      ..createdAt = DateTime.now();

    late int sessionId;
    await isar.writeTxn(() async {
      sessionId = await isar.sessions.put(session);
    });

    // Iniciamos (o reiniciamos) el timer de seguridad de 1 minuto
    //_resetTimer();

    return sessionId;
  }

  // 3. AGREGAR DATOS (El corazón de la lógica)
  Future<void> addData(int sessionId, List<int> rawData) async {
    final isar = await db;

    final packet = SessionData()
      ..sessionId = sessionId
      ..data = rawData;

    await isar.writeTxn(() async {
      await isar.sessionDatas.put(packet);
    });

    /*_pendingCount++;

    // --- TRIGGER 1: Por Cantidad ---
    if (_pendingCount >= _batchLimit) {
      debugPrint("Trigger: Límite de 50 alcanzado. Enviando...");
      await _flush();
    }*/
  }

  // 4. FINALIZAR (Forzar envío al detener grabación)
  Future<void> stopSession() async {
    //_flushTimer?.cancel();
    await _flush(); // Enviar lo que quede pendiente
    debugPrint("Sesión finalizada y buffer vaciado.");
  }

  // 5. LÓGICA DE ENVÍO (FLUSH)
  Future<void> _flush() async {
    // Reseteamos el timer para que no se dispare de nuevo innecesariamente
    //_resetTimer();

    //if (_pendingCount == 0) return; // Nada que enviar

    final isar = await db;

    // A. Buscar todos los datos pendientes ordenados
    // Nota: Podrías filtrar por sessionId si quisieras, aquí enviamos TODO lo pendiente
    final dataItems = await isar.sessionDatas.where().sortBySessionId().findAll();

    /*if (dataItems.isEmpty) {
      _pendingCount = 0;
      return;
    }*/

    // B. Agrupar por Sesión (Por si hay datos de sesiones viejas mezclados)
    // Map<SessionId, List<Payload>>
    final Map<int, List<List<int>>> batches = {};

    for (var item in dataItems) {
      if (!batches.containsKey(item.sessionId)) {
        batches[item.sessionId] = [];
      }
      batches[item.sessionId]!.add(item.data);
    }

    // C. Procesar y Enviar cada grupo
    for (final sessionId in batches.keys) {
      final payloadList = batches[sessionId]!;

      // Obtener info del paciente
      final session = await isar.sessions.get(sessionId);
      if (session == null) continue; // Caso raro: sesión borrada

      // Preparar "Sobre" (Envelope)
      final Map<String, dynamic> packet = {
        'p': session.patientName,
        't': session.createdAt?.millisecondsSinceEpoch ?? 0,
        'd': payloadList, // Lista de Uint8List
      };

      // Serializar y Comprimir
      final packed = msgpack.serialize(packet);
      final compressed = GZipCodec().encode(packed);

      // Enviar
      bool sent = await _sendToServer(compressed);

      if (sent) {
        // Borrar SOLO los datos que acabamos de enviar de esta sesión
        // Filtramos los IDs que pertenecen a esta sesión y estaban en la lista original
        final idsToDelete = dataItems
            .where((e) => e.sessionId == sessionId)
            .map((e) => e.id)
            .toList();

        await isar.writeTxn(() async {
          await isar.sessionDatas.deleteAll(idsToDelete);
        });
        debugPrint("Enviados ${idsToDelete.length} paquetes de sesión $sessionId");
      }
    }

    // Resetear contador local
    // (Nota: _pendingCount es una estimación en memoria, lo ponemos a 0 tras intentar enviar)
    //_pendingCount = 0;
  }

  // 6. HELPER DE RED
  Future<bool> _sendToServer(List<int> bodyBytes) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.tu-servidor.com/upload'),
        headers: {
          'Content-Type': 'application/x-msgpack',
          'Content-Encoding': 'gzip',
        },
        body: bodyBytes
      );
      //return response.statusCode == 200;
      return false;
    } catch (e) {
      debugPrint("Error de red: $e");
      return false;
    }
  }

  // 7. GESTIÓN DEL TIMER
  /*void _resetTimer() {
    _flushTimer?.cancel();
    // --- TRIGGER 2: Por Tiempo ---
    _flushTimer = Timer(_timeLimit, () {
      debugPrint("Trigger: Tiempo límite (1 min) alcanzado. Enviando...");
      _flush();
    });
  }*/
}