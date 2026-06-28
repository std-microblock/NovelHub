import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'data/repositories/app_repository.dart';
import 'state/providers.dart' show appRepositoryProvider;
import 'ui/editor/editor_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge-to-edge with a transparent, scrim-free system navigation bar.
  // Flutter 3.44 enables edge-to-edge by default, which otherwise leaves
  // the gesture bar (the "small white bar") overlaid on the content with a
  // translucent scrim — making the bottom look odd. This keeps it transparent
  // so app content extends behind it cleanly.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    statusBarColor: Colors.transparent,
  ));
  await JsonAppRepository.init();
  final repository = JsonAppRepository.defaultInstance();

  runApp(ProviderScope(
    overrides: [
      appRepositoryProvider.overrideWithValue(repository),
    ],
    child: const NovelHubApp(),
  ));
}

class NovelHubApp extends ConsumerWidget {
  const NovelHubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DynamicAppTheme(
      builder: (light, dark) => MaterialApp(
        title: 'NovelHub',
        debugShowCheckedModeBanner: false,
        theme: light,
        darkTheme: dark,
        home: const EditorScreen(),
      ),
    );
  }
}
