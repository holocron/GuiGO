import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/input_history.dart';
import 'features/connections/connection_list_screen.dart';
import 'features/session/session_screen.dart';
import 'features/session/type_ahead.dart';

Future<void> main() async {
  // every error nobody caught — a framework error in a build, a dropped
  // future's failure, a platform callback's — is logged, never fatal:
  // the app stays up with its session. The
  // binding is initialized inside the zone too: runApp in another zone
  // than the binding's is a framework warning
  runZonedGuarded<void>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      installErrorHandlers();
      final history = await InputHistoryStore.create();
      // the listboxes' value sets are held in memory for the app session
      // only: a set can hold personal data (PA20's contract list), so the
      // on-disk cache SAP GUI keeps (ValueSetDiskCache.attach) stays off
      // until the user opts in
      runApp(GuiGoApp(history: history));
    },
    (error, stack) => logUncaught('zone', error, stack),
  );
}

/// The framework's and the platform's uncaught-error hooks, both logging
/// ([logUncaught]); the framework's keeps its own report
/// ([FlutterError.presentError]: the red box in debug, the console dump)
/// and the platform's reports the error handled so the engine does not
/// terminate the isolate.
void installErrorHandlers() {
  final present = FlutterError.onError ?? FlutterError.presentError;
  FlutterError.onError = (details) {
    present(details);
    logUncaught('flutter', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logUncaught('platform', error, stack);
    return true;
  };
}

/// One line per uncaught error on the console ([debugPrint]: throttled, so
/// a burst cannot starve the UI thread), the stack in debug builds only.
void logUncaught(String source, Object error, StackTrace? stack) {
  debugPrint('GuiGo uncaught ($source): $error');
  if (kDebugMode && stack != null) debugPrint('$stack');
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
