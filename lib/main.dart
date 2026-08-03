import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'features/map/map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(TractorGPSApp(themeController: ThemeController()));
}

class TractorGPSApp extends StatefulWidget {
  const TractorGPSApp({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<TractorGPSApp> createState() => _TractorGPSAppState();
}

class _TractorGPSAppState extends State<TractorGPSApp> {
  @override
  void initState() {
    super.initState();
    widget.themeController.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      // Keep MapScreen alive across theme changes so map/GPS state is preserved.
      builder: (context, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'PasturePath V4',
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: widget.themeController.mode,
          home: child,
        );
      },
      child: MapScreen(themeController: widget.themeController),
    );
  }
}
