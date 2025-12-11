import 'package:fl_chart/fl_chart.dart';

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

    // Si no está lleno, tomamos de 0 a index. Si está lleno, reordenamos para que sea continuo.
    final ordered = !filled
        ? buffer.sublist(0, index)
        : [...buffer.sublist(index), ...buffer.sublist(0, index)];

    int firstIndex = ordered.indexWhere((p) => p.x >= minX);
    if (firstIndex == -1) {
      if (ordered.isNotEmpty && ordered.last.x < minX) return [ordered.last];
      return [];
    }

    // Incluimos un punto anterior para evitar huecos visuales al inicio
    int startIndex = (firstIndex > 0) ? firstIndex - 1 : 0;
    return ordered.sublist(startIndex);
  }
}