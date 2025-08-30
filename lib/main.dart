import 'package:flutter/material.dart';
import 'features/map/map_screen.dart';

void main() async {
  // Ensures plugins like SharedPreferences, PathProvider work at startup
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TractorGPSApp());
}

class TractorGPSApp extends StatelessWidget {
  const TractorGPSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TractorGPS V3.0.5',
      theme: ThemeData(
        primarySwatch: Colors.green,
      ),
      home: const MapScreen(),
    );
  }
}
