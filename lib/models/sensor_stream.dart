import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../utils/ring_buffer.dart';
import '../utils/constants.dart';

class SensorStream {
  final String id;
  final List<String> labels;
  final List<String> units;
  final int sensorFrequencyHz;
  final List<Color> colors;

  // Lógica de Downsampling
  final int rawToVisualRatio;

  // Acumulador para la interpolación de velocidad (Animation smoothing)
  double drawAccumulator = 0.0;

  // Contenedores de datos
  final List<RingBuffer> linesData = [];
  final List<List<FlSpot>> pendingBuffer = [];

  // Contador interno para el downsampling
  int _counter = 0;

  SensorStream({
    required this.id,
    required this.labels,
    required this.units,
    required this.sensorFrequencyHz,
    required this.colors,
  }) : rawToVisualRatio = (sensorFrequencyHz / AppConstants.visualRateHz * 2.5).ceil() {

    // Capacidad: 10 segundos * Tasa visual * Margen de seguridad
    int capacity = (10 * AppConstants.visualRateHz * 1.5).ceil();

    for (int i = 0; i < labels.length; i++) {
      linesData.add(RingBuffer(capacity));
      pendingBuffer.add([]);
    }
  }

  /// Procesa un paquete de datos crudos y decide si agregarlo al buffer pendiente
  /// basado en el ratio de downsampling.
  void addRawData(double timestampSeconds, List<double> values) {
    _counter++;
    if (_counter % rawToVisualRatio != 0) return;

    // Resetear contador periódicamente para evitar overflow (aunque es un int grande)
    if (_counter >= rawToVisualRatio) _counter = 0;

    for (int i = 0; i < values.length; i++) {
      if (i < pendingBuffer.length) {
        pendingBuffer[i].add(FlSpot(timestampSeconds, values[i]));
      }
    }
  }
}