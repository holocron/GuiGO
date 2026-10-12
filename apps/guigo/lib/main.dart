import 'package:flutter/material.dart';

import 'features/connections/connection_list_screen.dart';
import 'features/session/session_screen.dart';

void main() {
  runApp(const GuiGoApp());
}

class GuiGoApp extends StatelessWidget {
  const GuiGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GuiGo',
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
