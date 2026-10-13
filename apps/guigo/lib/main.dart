import 'package:flutter/material.dart';

import 'core/input_history.dart';
import 'features/connections/connection_list_screen.dart';
import 'features/session/session_screen.dart';
import 'features/session/type_ahead.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final history = await InputHistoryStore.create();
  runApp(GuiGoApp(history: history));
}

class GuiGoApp extends StatelessWidget {
  const GuiGoApp({super.key, this.history});

  /// SAP GUI's local input history, offered under every dynpro input
  /// (features/session/type_ahead.dart); null = none (tests).
  final InputHistoryStore? history;

  @override
  Widget build(BuildContext context) {
    final h = history;
    return MaterialApp(
      title: 'GuiGo',
      builder: h == null
          ? null
          : (context, child) => TypeAheadScope(
              config: TypeAheadConfig(history: h),
              child: child ?? const SizedBox.shrink(),
            ),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A6ED1),
          brightness: Brightness.dark,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      routes: {
        '/': (c) => const ConnectionListScreen(),
        '/session': (c) => const SessionScreen(),
      },
    );
  }
}
