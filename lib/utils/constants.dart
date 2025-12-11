import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class AppConstants {
  // ESP UUIDs
  static final Guid serviceUUID = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  static final Guid charSSIDUUID = Guid("beb5483e-36e1-4688-b7f5-ea07361b26a8");
  static final Guid charPassUUID = Guid("82141505-1a35-463d-9d7a-1808d4b005c3");
  static final Guid charConfigUUID = Guid("e4b60b73-0456-4c4f-bc14-22280d507116");
  static final Guid charActionUUID = Guid("69c2794c-8594-4b53-b093-a61574697960");
  static final Guid charProtoUUID = Guid("12345678-1234-1234-1234-1234567890ab");

  // Tasa de muestreo visual deseada para todos los gráficos.
  static const int visualRateHz = 60;
  // Ventana de tiempo mostrada en el eje X (segundos).
  static const double visualWindowSeconds = 3.0;

  // Paleta global de colores para los sensores.
  static const List<Color> palette = [
    Colors.cyanAccent, Colors.pinkAccent, Colors.amberAccent,
    Colors.greenAccent, Colors.purpleAccent, Colors.lightBlueAccent,
    Colors.orangeAccent, Colors.tealAccent, Colors.redAccent,
    Colors.indigoAccent, Colors.limeAccent, Colors.deepOrangeAccent
  ];
}