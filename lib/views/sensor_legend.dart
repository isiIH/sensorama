import 'package:flutter/material.dart';
import '../models/sensor_stream.dart';

class SensorLegend extends StatelessWidget {
  final Map<String, SensorStream> activeSensors;
  final String selectedSensorId;
  final ValueChanged<String> onSensorSelected;

  const SensorLegend({
    super.key,
    required this.activeSensors,
    required this.selectedSensorId,
    required this.onSensorSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (activeSensors.isEmpty) {
      return const Text("Waiting for data...", style: TextStyle(color: Colors.white54));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: activeSensors.values.map((stream) {
          String info = " | ${stream.sensorFrequencyHz} Hz | R:${stream.rawToVisualRatio}";
          bool isSelected = selectedSensorId == stream.id;

          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: isSelected ? 0.1 : 0),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: TextButton(
              onPressed: () => onSensorSelected(isSelected ? "" : stream.id),
              style: ButtonStyle(
                splashFactory: NoSplash.splashFactory,
                overlayColor: WidgetStateProperty.all(Colors.transparent),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.id + info,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: List.generate(stream.labels.length, (index) {
                      final color = stream.colors[index];
                      return Padding(
                        padding: const EdgeInsets.only(right: 12.0),
                        child: Row(
                          children: [
                            Container(width: 8, height: 8, color: color),
                            const SizedBox(width: 4),
                            Text(stream.labels[index],
                                style: TextStyle(color: color, fontSize: 11)),
                          ],
                        ),
                      );
                    }),
                  )
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}