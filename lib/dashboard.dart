import 'package:flutter/material.dart';
import 'sensor_config.dart';
import 'chart.dart';

// Configuración estática de los sensores
final List<SensorConfig> availableSensors = [
  SensorConfig(
    name: "ECG / Cardíaco",
    icon: Icons.monitor_heart,
    metrics: [
      MetricConfig(name: "Voltaje ECG", color: Colors.green, unit: "mV", minVal: -1.0, maxVal: 2.0),
      MetricConfig(name: "Frecuencia (BPM)", color: Colors.red, unit: "BPM", minVal: 60, maxVal: 120),
    ],
  ),
  SensorConfig(
    name: "Acelerómetro",
    icon: Icons.open_with,
    metrics: [
      MetricConfig(name: "Eje X", color: Colors.blue, unit: "m/s²", minVal: -10, maxVal: 10),
      MetricConfig(name: "Eje Y", color: Colors.orange, unit: "m/s²", minVal: -10, maxVal: 10),
      MetricConfig(name: "Eje Z", color: Colors.purple, unit: "m/s²", minVal: 0, maxVal: 20),
    ],
  ),
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late SensorConfig _selectedSensor;
  late MetricConfig _selectedMetric;

  @override
  void initState() {
    super.initState();
    _selectedSensor = availableSensors[0];
    _selectedMetric = _selectedSensor.metrics[0];
  }

  @override
  void dispose() {
    // TODO: implement dispose
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(0.0),
      child: Column(
        children: [
          // SELECCIÓN DE SENSOR
          SizedBox(
            height: 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: availableSensors.length,
              itemBuilder: (context, index) {
                final sensor = availableSensors[index];
                final isSelected = sensor == _selectedSensor;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilterChip(
                    selected: isSelected,
                    label: Text(sensor.name),
                    avatar: Icon(sensor.icon, size: 18, color: isSelected ? Colors.black : Colors.white),
                    onSelected: (_) {
                      setState(() {
                        _selectedSensor = sensor;
                        _selectedMetric = sensor.metrics[0];
                      });
                    },
                    checkmarkColor: Colors.black,
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 10),

          // SELECCIÓN DE MÉTRICA
          SizedBox(
            height: 50,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _selectedSensor.metrics.length,
              itemBuilder: (context, index) {
                final metric = _selectedSensor.metrics[index];
                final isSelected = metric == _selectedMetric;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: isSelected,
                    label: Text(metric.name),
                    onSelected: (_) {
                      setState(() {
                        _selectedMetric = metric;
                      });
                    },
                    selectedColor: metric.color.withValues(alpha: 0.8),
                    backgroundColor: Colors.white10,
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 20),

          // GRÁFICO EN TIEMPO REAL (Expanded para ocupar el resto)
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.fromLTRB(16, 24, 24, 16),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1F24),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white10),
              ),
              child: RealTimeChart(),
            ),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}