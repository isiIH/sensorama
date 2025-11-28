import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// MODELOS DE DATOS
// ---------------------------------------------------------------------------

class MetricData {
  final List<double> values;
  final DateTime timestamp;

  MetricData({
    required this.values,
    required this.timestamp,
  });
}

class SensorPacket {
  final String sensorId;
  final List<MetricData> data;
  final int bufferSize;
  final int f;
  final List<String> labels;
  final List<String> units;

  SensorPacket({
    required this.sensorId,
    required this.data,
    required this.bufferSize,
    required this.f,
    required this.labels,
    required this.units
  });

  // Factory para convertir tu JSON específico
  factory SensorPacket.fromJson(Map<String, dynamic> json) {
    var bufferSize = json['bufferSize'];

    List<MetricData> data = [];
    for(var i=0; i<bufferSize; i++) {
      List<dynamic> dataBlock = json['data'][i];
      data.add(MetricData(
          values: List<double>.from(dataBlock[0]),
          timestamp: DateTime.fromMicrosecondsSinceEpoch(dataBlock[1])
      ));
    }

    return SensorPacket(
      sensorId: json['sensor_id'],
      data: data,
      bufferSize: bufferSize,
      f: json['metadata']['f'],
      labels: List<String>.from(json['metadata']['labels']),
      units: List<String>.from(json['metadata']['units'])
    );
  }
}

class MetricConfig {
  final String name;
  final Color color;
  final String unit;
  final double minVal; // Para simulación: valor mínimo esperado
  final double maxVal; // Para simulación: valor máximo esperado

  MetricConfig({
    required this.name,
    required this.color,
    required this.unit,
    required this.minVal,
    required this.maxVal,
  });
}

class SensorConfig {
  final String name;
  final IconData icon;
  final List<MetricConfig> metrics;

  SensorConfig({
    required this.name,
    required this.icon,
    required this.metrics,
  });
}