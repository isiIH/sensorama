import 'package:flutter/material.dart';
import 'sensor_config.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// WIDGET DEL GRÁFICO STREAMING
// ---------------------------------------------------------------------------

class RealTimeChart extends StatefulWidget {
  final MetricConfig metric;
  final bool isPaused;

  const RealTimeChart({
    super.key,
    required this.metric,
    required this.isPaused,
  });

  @override
  State<RealTimeChart> createState() => _RealTimeChartState();
}

class _RealTimeChartState extends State<RealTimeChart> {
  // Lista de puntos a mostrar
  final List<FlSpot> _points = [];

  // Variables para controlar el tiempo
  double _currentTime = 0;
  final double _incTime = 0.05; // Mostrar un nuevo dato simulado cada 0.05s
  final double _pointLimit = 120; // Número de puntos que muestra el gráfico
  late final double _windowSize = _incTime * _pointLimit; // Segundos mostrados en pantalla
  Timer? _timer;


  // Valor actual para mostrar en texto grande
  double _currentValue = 0;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(RealTimeChart oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambiamos de métrica, limpiamos el gráfico para empezar de nuevo
    if (oldWidget.metric != widget.metric) {
      _points.clear();
      _currentTime = 0;
      _currentValue = 0;
    }

    // Manejar pausa/play
    if (widget.isPaused && _timer != null) {
      _timer?.cancel();
    } else if (!widget.isPaused && (_timer == null || !_timer!.isActive)) {
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    // Actualizamos cada 50ms (20 FPS) para fluidez
    _timer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (mounted) {
        _addSimulatedDataPoint();
      }
    });
  }

  void _addSimulatedDataPoint() {
    setState(() {
      // 1. Incrementar tiempo
      _currentTime += 0.05; // 50ms = 0.05s

      // 2. Generar dato aleatorio simulado (Seno + Ruido)
      // En tu app real, aquí leerías el valor del Bluetooth
      double noise = (math.Random().nextDouble() - 0.5) * (widget.metric.maxVal - widget.metric.minVal) * 0.1;
      double baseSignal = math.sin(_currentTime * 2) * (widget.metric.maxVal - widget.metric.minVal) * 0.3;
      double center = (widget.metric.maxVal + widget.metric.minVal) / 2;

      _currentValue = center + baseSignal + noise;

      // 3. Añadir punto
      _points.add(FlSpot(_currentTime, _currentValue));

      // 4. Limpieza: Remover puntos que ya salieron de la ventana visual
      // (minX = _currentTime - _windowSize). Mantenemos un poco de margen.
      if (_points.length > _pointLimit) {
        _points.removeAt(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Calculamos los límites de la ventana deslizante
    double minX = _currentTime > _windowSize ? _currentTime - _windowSize : 0;
    double maxX = _currentTime > _windowSize ? _currentTime : _windowSize;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Encabezado con valor numérico
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.metric.name.toUpperCase(),
                  style: const TextStyle(color: Colors.grey, fontSize: 12, letterSpacing: 1.2),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _currentValue.toStringAsFixed(2),
                      style: TextStyle(
                        color: widget.metric.color,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        fontFamily: "monospace", // Fuente monoespaciada evita saltos
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.metric.unit,
                      style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
            // Indicador "LIVE"
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: widget.isPaused ? Colors.grey.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: widget.isPaused ? Colors.grey : Colors.red),
              ),
              child: Text(
                widget.isPaused ? "PAUSE" : "● LIVE",
                style: TextStyle(
                  color: widget.isPaused ? Colors.white : Colors.red,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          ],
        ),

        const SizedBox(height: 20),

        // El Gráfico
        Expanded(
          child: LineChart(
            LineChartData(
              // 1. Optimización: Desactivar interacciones táctiles complejas para rendimiento
              lineTouchData: const LineTouchData(enabled: false),

              // 2. Cuadrícula
              gridData: FlGridData(
                show: true,
                drawVerticalLine: true,
                getDrawingVerticalLine: (value) => const FlLine(color: Colors.white10, strokeWidth: 1),
                getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white10, strokeWidth: 1),
              ),

              // 3. Títulos (Ejes)
              titlesData: FlTitlesData(
                show: true,
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    interval: 1, // Mostrar etiqueta cada segundo
                    getTitlesWidget: (value, meta) {
                      // Formatear el timestamp a algo legible (ej: segundos)
                      return Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          value.toStringAsFixed(0),
                          style: const TextStyle(color: Colors.grey, fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
                leftTitles: AxisTitles(sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    getTitlesWidget: (value, meta) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 0.0),
                    child: Text(
                      value.toStringAsFixed(0),
                      style: const TextStyle(color: Colors.grey, fontSize: 10),
                    ),
                  );
                },
                )), // Ocultamos Y para limpieza
              ),

              // 4. Bordes
              borderData: FlBorderData(show: false),

              // 5. VENTANA DESLIZANTE (CLAVE DEL STREAMING)
              minX: minX,
              maxX: maxX,
              // Fijamos Y para que el gráfico no salte verticalmente
              minY: widget.metric.minVal,
              maxY: widget.metric.maxVal,

              // 6. Configuración de límites (Clipping)
              clipData: const FlClipData.all(), // Importante: Corta las líneas que salen del área

              // 7. Datos de la línea
              lineBarsData: [
                LineChartBarData(
                  spots: _points,
                  isCurved: true,
                  curveSmoothness: 0.15, // Menos curva = más rendimiento
                  color: widget.metric.color,
                  barWidth: 2,
                  isStrokeCapRound: true,
                  dotData: const FlDotData(show: false), // Ocultar puntos individuales
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      colors: [
                        widget.metric.color.withOpacity(0.3),
                        widget.metric.color.withOpacity(0.0),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ],
            ),
            // Animación suave entre frames (opcional, poner en 0 para datos muy rápidos)
            duration: const Duration(milliseconds: 0),
          ),
        ),
      ],
    );
  }
}