import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';

// Imports de nuestra arquitectura
import '../utils/constants.dart';
import '../models/sensor_stream.dart';
import '../models/sensor_packet.dart';
import 'sensor_legend.dart';

// Imports de protocols
import '../protocol/tcp_conn.dart';
import '../protocol/udp_conn.dart';

class RealTimeChart extends StatefulWidget {
  const RealTimeChart({super.key});

  @override
  State<RealTimeChart> createState() => _RealTimeChartState();
}

class _RealTimeChartState extends State<RealTimeChart> with SingleTickerProviderStateMixin {
  late final TCPConn _tcpConn;
  late final UDPConn _udpConn;
  late final Ticker _ticker;

  final Map<String, SensorStream> _activeSensors = {};
  DateTime? _globalStartTime;

  int _colorIndex = 0;
  double _maxX = 0;
  String _selectedSensor = "";
  String _selectedMetric = "";

  // Variables para Auto-scale Y
  double _currentMinY = 0;
  double _currentMaxY = 10;
  double? _stableMinY;
  double? _stableMaxY;

  @override
  void initState() {
    super.initState();
    _tcpConn = TCPConn();
    _udpConn = UDPConn();

    _tcpConn.addListener(_onNewSensorDataTCP);
    _udpConn.addListener(_onNewSensorDataUDP);

    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tcpConn.removeListener(_onNewSensorDataTCP);
    _udpConn.removeListener(_onNewSensorDataUDP);
    super.dispose();
  }

  void _onNewSensorDataTCP() => _processSensorPacket(_tcpConn.currentPacket);
  void _onNewSensorDataUDP() => _processSensorPacket(_udpConn.currentPacket);

  void _processSensorPacket(SensorPacket packet) {
    _globalStartTime ??= packet.data.first.timestamp;

    if (!_activeSensors.containsKey(packet.sensorId)) {
      _initializeNewSensor(packet);
    }

    final stream = _activeSensors[packet.sensorId]!;

    for (MetricData metricData in packet.data) {
      final double x = metricData.timestamp
          .difference(_globalStartTime!)
          .inMicroseconds / 1000000.0;

      // Delegamos la lógica de añadir/downsampling al modelo
      stream.addRawData(x, metricData.values);
    }
  }

  void _initializeNewSensor(SensorPacket packet) {
    List<Color> assignedColors = [];
    for(int i=0; i<packet.labels.length; i++) {
      assignedColors.add(AppConstants.palette[_colorIndex % AppConstants.palette.length]);
      _colorIndex++;
    }

    _activeSensors[packet.sensorId] = SensorStream(
      id: packet.sensorId,
      labels: packet.labels,
      units: packet.units,
      sensorFrequencyHz: packet.f,
      colors: assignedColors,
    );
  }

  // --- LÓGICA DE ANIMACIÓN (Suavizado) ---
  void _onTick(Duration elapsed) {
    if (_activeSensors.isEmpty) return;

    bool hasChanges = false;
    const int targetBufferSize = 15;
    const double correctionFactor = 0.1;

    for (var stream in _activeSensors.values) {
      if (stream.pendingBuffer.isEmpty || stream.pendingBuffer[0].isEmpty) continue;

      int pendingCount = stream.pendingBuffer[0].length;
      double speed = 1.0;

      // Ajuste dinámico de velocidad basado en la presión del buffer
      if (pendingCount > targetBufferSize) {
        speed += (pendingCount - targetBufferSize) * correctionFactor;
      } else if (pendingCount < targetBufferSize) {
        speed -= (targetBufferSize - pendingCount) * correctionFactor;
        speed = math.max(0.01, speed);
      }

      stream.drawAccumulator += speed;
      int pointsToMove = stream.drawAccumulator.floor();

      if (pointsToMove > 0) {
        stream.drawAccumulator -= pointsToMove;
        if (pointsToMove > pendingCount) pointsToMove = pendingCount;

        hasChanges = true;

        for (int i = 0; i < stream.pendingBuffer.length; i++) {
          var pending = stream.pendingBuffer[i];
          var pointsChunk = pending.sublist(0, pointsToMove);
          pending.removeRange(0, pointsToMove);

          for (var p in pointsChunk) {
            stream.linesData[i].add(p.x, p.y);
          }
          if (pointsChunk.isNotEmpty && pointsChunk.last.x > _maxX) _maxX = pointsChunk.last.x;
        }
      }
    }

    if (hasChanges) {
      setState(() {
        _updateGlobalMinMax();
      });
    }
  }

  void _updateGlobalMinMax() {
    double min = double.infinity;
    double max = double.negativeInfinity;
    bool hasData = false;
    double visibleThreshold = _maxX - AppConstants.visualWindowSeconds;

    for (var stream in _activeSensors.values) {
      // Ignorar sensores no seleccionados si hay filtro activo (opcional)
      if (_selectedSensor.isNotEmpty && stream.id != _selectedSensor) continue;

      for (var ring in stream.linesData) {
        var line = ring.getVisible(visibleThreshold);
        if (line.isNotEmpty) {
          for (var spot in line) {
            if (spot.x < visibleThreshold) continue;
            hasData = true;
            if (spot.y < min) min = spot.y;
            if (spot.y > max) max = spot.y;
          }
        }
      }
    }

    if (!hasData) return;
    if (min == max) { min -= 1; max += 1; }

    double range = max - min;
    double targetMin = min - (range * 0.1);
    double targetMax = max + (range * 0.1);

    if (_stableMaxY == null) {
      _stableMaxY = targetMax;
      _stableMinY = targetMin;
    } else {
      _stableMaxY = _stableMaxY! + (targetMax - _stableMaxY!) * 0.1;
      _stableMinY = _stableMinY! + (targetMin - _stableMinY!) * 0.1;
    }

    _currentMinY = _stableMinY!;
    _currentMaxY = _stableMaxY!;
  }

  @override
  Widget build(BuildContext context) {
    double minX = _maxX > AppConstants.visualWindowSeconds ? _maxX - AppConstants.visualWindowSeconds : 0;
    double maxXDisplay = _maxX > AppConstants.visualWindowSeconds ? _maxX : AppConstants.visualWindowSeconds;

    List<LineChartBarData> allLines = [];
    for (var stream in _activeSensors.values) {
      if (_selectedSensor != "" && _selectedSensor != stream.id) continue;

      for (int i = 0; i < stream.linesData.length; i++) {
        allLines.add(LineChartBarData(
          spots: stream.linesData[i].getVisible(minX),
          barWidth: 2,
          color: stream.colors[i],
          dotData: const FlDotData(show: false),
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          SensorLegend(
            activeSensors: _activeSensors,
            selectedSensorId: _selectedSensor,
            onSensorSelected: (id) => setState(() => _selectedSensor = id),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: LineChart(
              LineChartData(
                lineTouchData: const LineTouchData(enabled: false),
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10, strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: _buildTitlesData(),
                minX: minX,
                maxX: maxXDisplay,
                minY: _currentMinY,
                maxY: _currentMaxY,
                lineBarsData: allLines,
              ),
              duration: Duration.zero,
            ),
          ),
        ],
      ),
    );
  }

  FlTitlesData _buildTitlesData() {
    return FlTitlesData(
      show: true,
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 60,
          interval: 1,
          getTitlesWidget: (value, meta) {
            if (_globalStartTime == null) return const SizedBox.shrink();
            final date = _globalStartTime!.add(Duration(milliseconds: (value * 1000).toInt()));
            return Padding(
              padding: const EdgeInsets.only(top: 10),
              child: RotatedBox(
                quarterTurns: -1,
                child: Text(
                  DateFormat('HH:mm:ss').format(date),
                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                ),
              ),
            );
          },
        ),
      ),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          minIncluded: false,
          maxIncluded: false,
          showTitles: true,
          reservedSize: 40,
          getTitlesWidget: (value, meta) => Text(
            value.toStringAsPrecision(3),
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ),
      ),
    );
  }
}