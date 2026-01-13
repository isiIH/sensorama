import 'package:flutter/material.dart';
import 'dart:async';

import '../protocol/protocol.dart';
import '../db/data_manager.dart';

class RecordButton extends StatefulWidget {
  final List<Protocol> connections;

  const RecordButton({super.key, required this.connections});

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton> {
  final dataManager = DataManager.instance;
  final List<StreamSubscription> _subscriptions = [];

  final String patientName = "Patient 1";
  int currentSessionId = 0;
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    _setupListeners();
  }

  // Configuración de listeners
  void _setupListeners() {
    for (var conn in widget.connections) {
      // Nos suscribimos a cada conexión disponible
      final sub = conn.onPacketReceived.listen((bytes) {
        // Si no estamos grabando, ignoramos el dato y salimos rápido.
        if (!_isRecording) return;

        // Si estamos grabando, guardamos en la BD
        dataManager.addData(currentSessionId, bytes);
      });

      _subscriptions.add(sub);
    }
  }

  @override
  void dispose() {
    // Cancelamos todas las suscripciones al destruir el botón para evitar fugas
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  // Función para manejar la lógica de grabación
  Future<void> _handleRecord() async {
    setState(() {
      _isRecording = !_isRecording;
    });

    if (_isRecording) {
      debugPrint("🎙️ Inicio de grabación con $patientName...");
      currentSessionId = await dataManager.startSession(patientName);

    } else {
      debugPrint("🛑 Grabación detenida.");
      await dataManager.stopSession();
      currentSessionId = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleRecord,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _isRecording ? Colors.redAccent : Colors.blueAccent,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: _isRecording
                  ? Colors.red.withValues(alpha: 0.4)
                  : Colors.blue.withValues(alpha: 0.4),
              blurRadius: 10,
              spreadRadius: 2,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // El ícono cambia según el estado
            Icon(
              _isRecording ? Icons.stop_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            // El texto cambia según el estado
            Text(
              _isRecording ? "Stop" : "Record",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}