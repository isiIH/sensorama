import 'dart:convert';

/// Represents the metadata for a sensor, received once at connection start.
/// This metadata is persisted by MAC address and used for all subsequent data packets.
class SensorMetadata {
  final String macAddress;
  final String sensorId;
  final int frequency;
  final int samplesPerPacket;
  final int dimensions;
  final List<String> labels;
  final List<String> units;
  final List<double> minSignals;
  final List<double> maxSignals;
  final DateTime receivedAt;

  SensorMetadata({
    required this.macAddress,
    required this.sensorId,
    required this.frequency,
    required this.samplesPerPacket,
    required this.dimensions,
    required this.labels,
    required this.units,
    required this.minSignals,
    required this.maxSignals,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  /// Creates a copy with updated fields
  SensorMetadata copyWith({
    String? macAddress,
    String? sensorId,
    int? frequency,
    int? samplesPerPacket,
    int? dimensions,
    List<String>? labels,
    List<String>? units,
    List<double>? minSignals,
    List<double>? maxSignals,
    DateTime? receivedAt,
  }) {
    return SensorMetadata(
      macAddress: macAddress ?? this.macAddress,
      sensorId: sensorId ?? this.sensorId,
      frequency: frequency ?? this.frequency,
      samplesPerPacket: samplesPerPacket ?? this.samplesPerPacket,
      dimensions: dimensions ?? this.dimensions,
      labels: labels ?? List.from(this.labels),
      units: units ?? List.from(this.units),
      minSignals: minSignals ?? List.from(this.minSignals),
      maxSignals: maxSignals ?? List.from(this.maxSignals),
      receivedAt: receivedAt ?? this.receivedAt,
    );
  }

  /// Serializes to JSON for persistence
  Map<String, dynamic> toJson() {
    return {
      'macAddress': macAddress,
      'sensorId': sensorId,
      'frequency': frequency,
      'samplesPerPacket': samplesPerPacket,
      'dimensions': dimensions,
      'labels': labels,
      'units': units,
      'minSignals': minSignals,
      'maxSignals': maxSignals,
      'receivedAt': receivedAt.toIso8601String(),
    };
  }

  /// Deserializes from JSON
  factory SensorMetadata.fromJson(Map<String, dynamic> json) {
    return SensorMetadata(
      macAddress: json['macAddress'] as String,
      sensorId: json['sensorId'] as String,
      frequency: json['frequency'] as int,
      samplesPerPacket: json['samplesPerPacket'] as int,
      dimensions: json['dimensions'] as int,
      labels: List<String>.from(json['labels']),
      units: List<String>.from(json['units']),
      minSignals: List<double>.from(json['minSignals'].map((x) => x.toDouble())),
      maxSignals: List<double>.from(json['maxSignals'].map((x) => x.toDouble())),
      receivedAt: DateTime.parse(json['receivedAt'] as String),
    );
  }

  /// Converts to JSON string for storage
  String toJsonString() => jsonEncode(toJson());

  /// Creates from JSON string
  factory SensorMetadata.fromJsonString(String jsonString) {
    return SensorMetadata.fromJson(jsonDecode(jsonString));
  }

  @override
  String toString() {
    return 'SensorMetadata(mac: $macAddress, sensor: $sensorId, freq: $frequency Hz, '
           'dims: $dimensions, samples/pkt: $samplesPerPacket)';
  }
}
