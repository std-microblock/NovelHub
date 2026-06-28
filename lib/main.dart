import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'data/repositories/app_repository.dart';
import 'state/providers.dart' show appRepositoryProvider;
import 'ui/editor/editor_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
