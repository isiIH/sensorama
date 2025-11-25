import 'package:flutter/material.dart';
import 'dashboard.dart';

// ---------------------------------------------------------------------------
// WIDGET PRINCIPAL
// ---------------------------------------------------------------------------

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sensorama',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF101418), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF101418),
      ),
      home: const DashboardScreen(),
    );
  }
}