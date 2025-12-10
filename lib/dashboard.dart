import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';
import 'protocol/tcp_conn.dart';
import 'protocol/udp_conn.dart';
import 'protocol/protocol.dart';

// --- CONFIGURACIÓN DE VISUALIZACIÓN GLOBAL ---
// Tasa de muestreo visual deseada para todos los gráficos (60 puntos/segundo).
const int visualRateHz = 60;

// --- RING BUFFER (Sin cambios) ---
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
      if (ordered.isNotEmpty && ordered.last.x < minX) return [ordered.last];
      return [];
    }
    int startIndex = (firstIndex > 0) ? firstIndex - 1 : 0;
    return ordered.sublist(startIndex);
  }
}

// --- CLASE AUXILIAR PARA GESTIONAR CADA SENSOR INDIVIDUALMENTE ---
class SensorStream {
  final String id;
  final List<String> labels;
  final List<String> units;
  final int sensorFrequencyHz; // Frecuencia del sensor
  final List<Color> colors;

  // Factor de downsampling: indica cuántos datos brutos se ignoran por cada dato que se grafica.
  final int rawToVisualRatio;
  // Acumulador para la interpolación de velocidad
  double drawAccumulator = 0.0;
  final int pointsInWindow = (visualRateHz / 2.5).ceil();

  // Datos visuales (RingBuffers)
  final List<RingBuffer> linesData = [];
  // Buffer de entrada pendiente
  final List<List<FlSpot>> pendingBuffer = [];
  // Valores actuales para la leyenda
  final List<double> currentValues = [];

  // Contador interno para el downsampling
  int _counter = 0;

  SensorStream({
    required this.id,
    required this.labels,
    required this.units,
    required this.sensorFrequencyHz,
    required this.colors,
  }) : rawToVisualRatio = (sensorFrequencyHz / visualRateHz * 2.5).ceil() { // (visualRateHz / 2.5) puntos en pantalla

    // Capacidad: 10 segundos * Tasa de visualización deseada (60 Hz)
    int capacity = (10 * visualRateHz * 1.5).ceil();

    for (int i = 0; i < labels.length; i++) {
      linesData.add(RingBuffer(capacity));
      pendingBuffer.add([]);
      currentValues.add(0.0);
    }
  }
}


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
  DateTime? _globalStartTime; // Tiempo 0 para todos los sensores

  // Renombrada: Ventana de tiempo mostrada en el eje X
  final double _visualWindowSeconds = 3;

  // Paleta global de colores
  final List<Color> _palette = [
    Colors.cyanAccent, Colors.pinkAccent, Colors.amberAccent,
    Colors.greenAccent, Colors.purpleAccent, Colors.lightBlueAccent,
    Colors.orangeAccent, Colors.tealAccent, Colors.redAccent,
    Colors.indigoAccent, Colors.limeAccent, Colors.deepOrangeAccent
  ];
  int _colorIndex = 0;

  double _maxX = 0;

  // Auto-scale Y
  double _currentMinY = -10;
  double _currentMaxY = 10;
  double? _stableMinY;
  double? _stableMaxY;

  String _selectedSensor = "";

  @override
  void initState() {
    super.initState();
    _tcpConn = TCPConn();
    _udpConn = UDPConn();
    // 🔑 El listener ahora reacciona a los cambios de datos Y al estado de conexión
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

  // --- PROCESAMIENTO DE PAQUETES DE RED ---
  void _onNewSensorDataTCP() {
    _processSensorPacket(_tcpConn.currentPacket);
  }

  void _onNewSensorDataUDP() {
    _processSensorPacket(_udpConn.currentPacket);
  }

  void _processSensorPacket(SensorPacket packet) {
    // Actualizar el tiempo global
    _globalStartTime ??= packet.data.first.timestamp;

    if (!_activeSensors.containsKey(packet.sensorId)) {
      _initializeNewSensor(packet);
    }

    final stream = _activeSensors[packet.sensorId]!;

    for (MetricData metricData in packet.data) {
      // 🔑 Lógica de downsampling PER-SENSOR
      stream._counter++;
      if (stream._counter % stream.rawToVisualRatio != 0) continue;

      // Resetear contador después de un ciclo (opcional, pero útil)
      if (stream._counter >= stream.rawToVisualRatio) stream._counter = 0;

      final double x = metricData.timestamp
          .difference(_globalStartTime!)
          .inMicroseconds / 1000000.0;

      for (int i = 0; i < metricData.values.length; i++) {
        if (i < stream.pendingBuffer.length) {
          stream.pendingBuffer[i].add(FlSpot(x, metricData.values[i]));
        }
      }
    }
  }

  void _initializeNewSensor(SensorPacket packet) {
    List<Color> assignedColors = [];
    for(int i=0; i<packet.labels.length; i++) {
      assignedColors.add(_palette[_colorIndex % _palette.length]);
      _colorIndex++;
    }

    _activeSensors[packet.sensorId] = SensorStream(
      id: packet.sensorId,
      labels: packet.labels,
      units: packet.units,
      sensorFrequencyHz: packet.f > 0 ? packet.f : 60,
      colors: assignedColors,
    );
  }

  // --- TICK DEL RELOJ DE ANIMACIÓN (MODIFICADO: VACIADO SUAVE) ---
  void _onTick(Duration elapsed) {
    if (_activeSensors.isEmpty) return;

    bool hasChanges = false;

    // CONFIGURACIÓN DE LA INTERPOLACIÓN
    // Cuántos puntos queremos tener idealmente en espera (buffer de seguridad)
    // 5 frames a 60Hz son ~83ms de latencia, imperceptible pero suaviza mucho.
    const int targetBufferSize = 15;

    // Factor de agresividad: qué tan rápido aceleramos si nos quedamos atrás.
    // 0.1 significa que corregimos el 10% del error por frame.
    const double correctionFactor = 0.1;

    for (var stream in _activeSensors.values) {
      if (stream.pendingBuffer.isEmpty || stream.pendingBuffer[0].isEmpty) continue;

      // 1. Calcular cuántos puntos tenemos en espera (del primer canal)
      int pendingCount = stream.pendingBuffer[0].length;

      // 2. CALCULAR VELOCIDAD DE DIBUJO (Speed)
      // Velocidad base = 1.0 (1 punto por frame, sincronizado con visualRateHz)
      double speed = 1.0;

      if (pendingCount > targetBufferSize) {
        // Estamos retrasados: Aceleramos proporcionalmente al error
        // Ejemplo: Si hay 20 pendientes, (20 - 5) * 0.1 = 1.5 -> Speed = 2.5
        // Esto vacía el buffer suavemente sin saltos bruscos.
        speed += (pendingCount - targetBufferSize) * correctionFactor;
      } else if (pendingCount < targetBufferSize) {
        speed -= (targetBufferSize - pendingCount) * correctionFactor; // speed será < 1.0

        // Limitamos la velocidad mínima para asegurar que el gráfico siga moviéndose lentamente.
        speed = math.max(0.01, speed);
      }

      // 3. Acumular la velocidad
      stream.drawAccumulator += speed;

      // 4. Determinar cuántos puntos enteros podemos mover ahora
      int pointsToMove = stream.drawAccumulator.floor();

      if (pointsToMove > 0) {
        // Restamos los enteros usados, guardamos el decimal para el siguiente frame
        stream.drawAccumulator -= pointsToMove;

        // Limitamos para no tratar de sacar más de lo que existe
        if (pointsToMove > pendingCount) pointsToMove = pendingCount;

        hasChanges = true;

        // 5. Mover los puntos del buffer pendiente al buffer visual
        for (int i = 0; i < stream.pendingBuffer.length; i++) {
          var pending = stream.pendingBuffer[i];

          // Extraer el lote calculado
          var pointsChunk = pending.sublist(0, pointsToMove);
          pending.removeRange(0, pointsToMove);

          // Añadir al gráfico
          for (var p in pointsChunk) {
            stream.linesData[i].add(p.x, p.y);
          }

          if (pointsChunk.isNotEmpty) {
            if (pointsChunk.last.x > _maxX) _maxX = pointsChunk.last.x;
            stream.currentValues[i] = pointsChunk.last.y;
          }
        }
      }
    }

    if (hasChanges) {
      setState(() {
        _updateGlobalMinMax();
      });
    }
  }

  // Escala automática basada en TODOS los sensores visibles
  void _updateGlobalMinMax() {
    double min = double.infinity;
    double max = double.negativeInfinity;
    bool hasData = false;

    // Renombrada: Ventana de tiempo mostrada
    double visibleThreshold = _maxX - _visualWindowSeconds;

    for (var stream in _activeSensors.values) {
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

    // Padding vertical del 10%
    double range = max - min;
    double targetMin = min - (range * 0.1);
    double targetMax = max + (range * 0.1);

    if (_stableMaxY == null) {
      _stableMaxY = targetMax;
      _stableMinY = targetMin;
    } else {
      // Lerp (suavizado)
      _stableMaxY = _stableMaxY! + (targetMax - _stableMaxY!) * 0.1;
      _stableMinY = _stableMinY! + (targetMin - _stableMinY!) * 0.1;
    }

    _currentMinY = _stableMinY!;
    _currentMaxY = _stableMaxY!;
  }

  @override
  Widget build(BuildContext context) {
    double minX = _maxX > _visualWindowSeconds ? _maxX - _visualWindowSeconds : 0;
    double maxXDisplay = _maxX > _visualWindowSeconds ? _maxX : _visualWindowSeconds;

    // Generar todas las líneas de todos los sensores
    List<LineChartBarData> allLines = [];

    for (var stream in _activeSensors.values) {
      if (_selectedSensor != "" && _selectedSensor != stream.id) continue;

      for (int i = 0; i < stream.linesData.length; i++) {
        final visiblePoints = stream.linesData[i].getVisible(minX);

        allLines.add(LineChartBarData(
          spots: visiblePoints,
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
          _buildMultiSensorLegend(),

          const SizedBox(height: 10),

          // GRÁFICO
          Expanded(
            child: LineChart(
              LineChartData(
                lineTouchData: const LineTouchData(enabled: false),
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: Colors.white10, strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(show: false),

                titlesData: FlTitlesData(
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
                        return  Padding(
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
                      maxIncluded: false,
                      minIncluded: false,
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (value, meta) => Text(
                        value.toStringAsPrecision(3),
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ),
                  ),
                ),

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

  Widget _buildMultiSensorLegend() {
    if (_activeSensors.isEmpty) {
      return const Text("Waiting for data...", style: TextStyle(color: Colors.white54));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: _activeSensors.values.map((stream) {
          // Mostrar la frecuencia original y el ratio aplicado
          String info = " | ${stream.sensorFrequencyHz} Hz | R:${stream.rawToVisualRatio}";
          bool isSelected = _selectedSensor == stream.id;

          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: isSelected ? 0.1 : 0),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: TextButton(
              onPressed: () {
                setState(() {
                  _selectedSensor = isSelected ? "" : stream.id;
                });
              },
              style: ButtonStyle(
                splashFactory: NoSplash.splashFactory, // Removes the splash effect
                overlayColor: WidgetStateProperty.all(Colors.transparent), // Removes overlay color on press
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(stream.id + info, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 12)),
                  const SizedBox(height: 4),
                  Row(
                    children: List.generate(stream.labels.length, (index) {
                      final val = stream.currentValues[index];
                      final color = stream.colors[index];
                      return Padding(
                        padding: const EdgeInsets.only(right: 12.0),
                        child: Row(
                          children: [
                            Container(width: 8, height: 8, color: color),
                            const SizedBox(width: 4),
                            Text(stream.labels[index],
                                style: TextStyle(color: color, fontSize: 11)
                            ),
                            /*SizedBox(
                              width: 50,
                              child: Text(val.toStringAsFixed(1), style: TextStyle(color: color, fontSize: 11)),
                            ),*/
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