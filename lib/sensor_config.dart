import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// MODELOS DE DATOS
// ---------------------------------------------------------------------------

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