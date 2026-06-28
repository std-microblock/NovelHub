import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';

/// Material You theme: dynamic color from wallpaper on Android, seeded
/// ColorScheme elsewhere (Windows desktop).
class AppTheme {
  static const _seed = Color(0xFF6750A4);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: brightness,
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      );
}

/// Wraps [MaterialApp] with dynamic color when available.
class DynamicAppTheme extends StatelessWidget {
  final Widget Function(ThemeData light, ThemeData dark) builder;
  const DynamicAppTheme({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(builder: (lightDynamic, darkDynamic) {
      final light = lightDynamic != null
          ? ThemeData(
              useMaterial3: true,
              colorScheme: lightDynamic.harmonized(),
            )
          : AppTheme.light();
      final dark = darkDynamic != null
          ? ThemeData(
              useMaterial3: true,
              colorScheme: darkDynamic.harmonized(),
            )
          : AppTheme.dark();
      return builder(light, dark);
    });
  }
}
