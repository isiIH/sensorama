import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';
import 'tcp_conn.dart';
import 'sensor_config.dart';

// --- RING BUFFER ---
class RingBuffer {
  final List<FlSpot> buffer;
  int index = 0;
  bool filled = false;

  RingBuffer(int capacity)
      : buffer = List.filled(capacity, const FlSpot(0, 0));

  void add(double x, double y) {
    buffer[index] = FlSpot(x, y);
    index = (index + 1) % buffer.length;
    if (index == 0) filled = true;
  }

  List<FlSpot> getVisible(double minX) {
    if (!filled && index == 0) return [];

    final ordered = !filled
        ? buffer.sublist(0, index)
        : [...buffer.sublist(index), ...buffer.sublist(0, index)];

    int firstIndex = ordered.indexWhere((p) => p.x >= minX);

    if (firstIndex == -1) {
      if (ordered.isNotEmpty && ordered.last.x < minX) {
        return [ordered.last];
      }
      return [];
    }

    // Punto Fantasma para suavizar la curva al entrar
    int startIndex = (firstIndex > 0) ? firstIndex - 1 : 0;
    return ordered.sublist(startIndex);
  }
}

class RealTimeChart extends StatefulWidget {
  const RealTimeChart({super.key});

  @override
  State<RealTimeChart> createState() => _RealTimeChartState();
}

class _RealTimeChartState extends State<RealTimeChart> with SingleTickerProviderStateMixin {
  late final TCPConn _tcpConn;

  // Visual Data (RingBuffers)
  final List<RingBuffer> _linesData = [];

  // Pending Buffer
  final List<List<FlSpot>> _pendingDataBuffer = [];

  String nameSensor = "";
  List<String> labels = [];
  List<String> units = [];
  int freq = 0;
  final List<double> _currentValues = [];

  DateTime? _startTime;

  // Colores estilo Neon/Material
  final List<Color> _lineColors = [
    Colors.cyanAccent, Colors.pinkAccent, Colors.amberAccent,
    Colors.greenAccent, Colors.purpleAccent, Colors.lightBlueAccent,
  ];

  final double _windowDuration = 3; // Vista de ventana en segundos
  final int _sampleRate = 200;
  int _counter = 0;

  double _maxX = 0;

  // Auto-scale
  double _currentMinY = 0;
  double _currentMaxY = 100;
  double? _stableMinY;
  double? _stableMaxY;

  double _pointsToDrawAccumulator = 0.0;
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _tcpConn = TCPConn();
    _tcpConn.addListener(_onNewSensorData);
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tcpConn.removeListener(_onNewSensorData);
    super.dispose();
  }

  void _onNewSensorData() {
    if (_tcpConn.packets.isEmpty) return;

    final SensorPacket lastPacket = _tcpConn.packets.last;
    nameSensor = lastPacket.sensorId;
    labels = lastPacket.labels;
    units = lastPacket.units;
    freq = lastPacket.f > 0 ? lastPacket.f : 0;

    int channels = lastPacket.data.first.values.length;
    while (_pendingDataBuffer.length < channels) {
      _pendingDataBuffer.add([]);
      // Buffer circular de seguridad
      int capacity = ((freq / _sampleRate) * 10).toInt();
      _linesData.add(RingBuffer(capacity));
    }

    for (MetricData metricData in lastPacket.data) {
      _counter++;
      if(_counter % _sampleRate != 0) continue;

      _startTime ??= metricData.timestamp;

      // Cálculo de X en SEGUNDOS (tiempo relativo)
      final double x = metricData.timestamp
          .difference(_startTime!)
          .inMicroseconds / 1000000.0;

      for (int i = 0; i < metricData.values.length; i++) {
        if (i < _pendingDataBuffer.length) {
          _pendingDataBuffer[i].add(FlSpot(x, metricData.values[i]));
        }
      }
    }
  }

  void _onTick(Duration elapsed) {
    bool hasChanges = false;
    double realTimeRate = (freq / _sampleRate) / 60.0;

    int bufferSize = _pendingDataBuffer.isNotEmpty ? _pendingDataBuffer[0].length : 0;
    double multiplier = 1.0;
    int oneSecondData = (freq / _sampleRate).round();

    if (bufferSize > oneSecondData * 1.5) {
      multiplier = 1.2;
    }
    else if (bufferSize < (oneSecondData * 0.1)) {
      multiplier = 0.9;
    } else {
      multiplier = 1.0;
    }

      _pointsToDrawAccumulator += (realTimeRate * multiplier);
      int pointsToExtract = _pointsToDrawAccumulator.floor();

      if (pointsToExtract > 0) {
        _pointsToDrawAccumulator -= pointsToExtract;

        for (int i = 0; i < _pendingDataBuffer.length; i++) {
          if (_pendingDataBuffer[i].isNotEmpty) {
            hasChanges = true;
            int count = _pendingDataBuffer[i].length < pointsToExtract
                ? _pendingDataBuffer[i].length : pointsToExtract;

            var points = _pendingDataBuffer[i].sublist(0, count);
            _pendingDataBuffer[i].removeRange(0, count);

            for(var p in points) {
              _linesData[i].add(p.x, p.y);
            }

            if (points.isNotEmpty) {
              _maxX = points.last.x;
              if (_currentValues.length <= i) _currentValues.add(0);
              _currentValues[i] = points.last.y;
            }
          }
        }
      }

      if (hasChanges) {
        setState(() {
          _updateMinMax();
        });
      }
  }

  void _updateMinMax() {
    double min = double.infinity;
    double max = double.negativeInfinity;
    bool hasData = false;

    // Calculamos ventana en segundos (ej. 3.0 segundos)
    double visibleThreshold = _maxX - _windowDuration;

    for (var ring in _linesData) {
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

    if (!hasData) return;
    if (min == max) { min -= 1; max += 1; }

    const double stepSize = 10.0;
    double targetMin = (min / stepSize).floor() * stepSize - stepSize;
    double targetMax = (max / stepSize).ceil() * stepSize + stepSize;

    if (_stableMaxY == null || _stableMinY == null) {
      _stableMaxY = targetMax;
      _stableMinY = targetMin;
      _currentMinY = targetMin;
      _currentMaxY = targetMax;
      return;
    }

    // Lógica de histéresis suave
    if (targetMax > _stableMaxY!) _stableMaxY = targetMax;
    if (targetMin < _stableMinY!) _stableMinY = targetMin;

    if (targetMax < _stableMaxY!) _stableMaxY = _stableMaxY! - (_stableMaxY! - targetMax) * 0.05;
    if (targetMin > _stableMinY!) _stableMinY = _stableMinY! + (targetMin - _stableMinY!) * 0.05;

    _currentMinY = _stableMinY!;
    _currentMaxY = _stableMaxY!;
  }

  @override
  Widget build(BuildContext context) {
    // Conversión de ventana a Segundos para el eje X
    double minX = _maxX > _windowDuration ? _maxX - _windowDuration : 0;
    double maxXDisplay = _maxX > _windowDuration ? _maxX : _windowDuration;

    return Column(
      children: [
        // Encabezado con datos actuales
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(nameSensor.isEmpty ? "Esperando datos..." : "$nameSensor (${_linesData.length} ch)", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)),
            const SizedBox(height: 4),
            _buildLegend(),
          ],
        ),
        const SizedBox(height: 12),

        // GRÁFICO
        Expanded(
          child: LineChart(
            LineChartData(
              // --- ESTILO BASADO EN SAMPLE 10 ---
              lineTouchData: const LineTouchData(enabled: false),
              clipData: const FlClipData.all(), // Recorta lo que sale del área
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false, // Más limpio sin líneas verticales
                drawHorizontalLine: true,
                getDrawingHorizontalLine: (value) => FlLine(
                  color: Colors.white.withValues(alpha: 0.1),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false), // Sin bordes duros

              // Ejes
              titlesData: FlTitlesData(
                show: true,
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 60,
                    interval: 1, // Cada 1 segundo
                    getTitlesWidget: (value, meta) {
                      // Formato de tiempo limpio
                      if (_startTime == null) return const SizedBox.shrink();
                      final date = _startTime!.add(Duration(milliseconds: (value * 1000).toInt()));
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
                    showTitles: true,
                    reservedSize: 40,
                    getTitlesWidget: (value, meta) => Text(
                        value.toInt().toString(),
                        style: const TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.bold)
                    ),
                  ),
                ),
              ),

              minX: minX,
              maxX: maxXDisplay,
              minY: _currentMinY,
              maxY: _currentMaxY,

              // --- GENERACIÓN DE LÍNEAS CON GRADIENTE ---
              lineBarsData: List.generate(_linesData.length, (index) {
                // Obtenemos los puntos visibles
                final visiblePoints = _linesData[index].getVisible(minX);

                return LineChartBarData(
                  spots: visiblePoints,

                  // Estilo Sample 10:
                  isCurved: false, // Sin curva para máximo rendimiento y precisión
                  // Si quieres curva: isCurved: true, curveSmoothness: 0.1

                  barWidth: 3, // Línea un poco más gruesa
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false), // Sin puntos
                  color: _lineColors[index % _lineColors.length],

                  // EL GRADIENTE MÁGICO (Desvanecer cola)
                  /*gradient: LinearGradient(
                    colors: [
                      color.withOpacity(0.0), // Transparente al inicio
                      color.withOpacity(1.0), // Sólido al final (nuevo dato)
                    ],
                    // Ajustamos el gradiente para que cubra la ventana visible
                    stops: const [0.0, 1.0],
                  ),*/
                );
              }),
            ),
            // Importante: Duración 0 porque nosotros animamos con el Ticker
            duration: Duration.zero,
          ),
        ),
      ],
    );
  }

  Widget _buildLegend() {
    int count = labels.length;
    if (count == 0) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Wrap(
          spacing: 16.0,
          runSpacing: 8.0,
          alignment: WrapAlignment.center,
          children: List.generate(count, (index) {
            double val = index < _currentValues.length ? _currentValues[index] : 0;
            Color color = _lineColors[index % _lineColors.length];
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Indicador de color sólido
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                    val.toStringAsFixed(1),
                    style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)
                ),
                const SizedBox(width: 4),
                Text(
                    "${labels[index]} [${units[index]}]",
                    style: const TextStyle(color: Colors.white54, fontSize: 12)
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}