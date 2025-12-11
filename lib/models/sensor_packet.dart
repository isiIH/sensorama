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
  final String macAddress;
  final List<MetricData> data;
  final int bufferSize;
  final int f;
  final List<String> labels;
  final List<String> units;

  SensorPacket({
    required this.sensorId,
    required this.macAddress,
    required this.data,
    required this.bufferSize,
    required this.f,
    required this.labels,
    required this.units
  });
}