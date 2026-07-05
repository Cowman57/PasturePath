import 'package:flutter/material.dart';
import 'features/map/map_screen.dart';

void main() {
  runApp(const TractorGPSApp());
}

class TractorGPSApp extends StatelessWidget {
  const TractorGPSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PasturePath V4',
      theme: ThemeData(
        primarySwatch: Colors.green,
      ),
      home: const MapScreen(),
    );
  }
}
