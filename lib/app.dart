import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ui/screens/main_screen.dart';
import 'ui/screens/consent_screen.dart';
import 'providers/consent_provider.dart';
import 'providers/theme_provider.dart';
import 'utils/constants.dart';

class SilsiganApp extends ConsumerWidget {
  const SilsiganApp({super.key});

  ThemeData _buildTheme(bool isDark) {
    // AppConstants.isDark is already set when this runs, so the token getters
    // resolve against the right palette.
    return ThemeData(
      brightness: isDark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: AppConstants.bgColor,
      appBarTheme: AppBarTheme(
        backgroundColor: AppConstants.bgColor,
        elevation: 0,
        centerTitle: false,
        foregroundColor: AppConstants.textPrimary,
        iconTheme: IconThemeData(color: AppConstants.textPrimary),
      ),
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.grey,
        brightness: isDark ? Brightness.dark : Brightness.light,
      ),
      // Material surfaces (dialogs, popup menus) follow the panel tone in dark
      // mode; light mode keeps the M3 defaults the app shipped with.
      dialogTheme: isDark
          ? const DialogThemeData(backgroundColor: Color(0xFF2A2A2E))
          : const DialogThemeData(),
      popupMenuTheme: isDark
          ? const PopupMenuThemeData(color: Color(0xFF2A2A2E))
          : const PopupMenuThemeData(),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppConstants.textPrimary,
        selectionColor: AppConstants.selectionHighlightColor,
        selectionHandleColor: AppConstants.selectionHandleColor,
      ),
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(darkModeProvider);
    // Must be assigned before any descendant reads a color getter this frame.
    AppConstants.isDark = isDark;

    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    ));

    return MaterialApp(
      title: 'Silsigan',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(isDark),
      home: const _ConsentGate(),
    );
  }
}

/// Gates the app behind a one-time data-sharing consent screen so audio is
/// never streamed to the transcription/translation service before the user
/// has been told what is shared and has agreed (Apple 5.1.1(i) / 5.1.2(i)).
class _ConsentGate extends StatefulWidget {
  const _ConsentGate();

  @override
  State<_ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<_ConsentGate> {
  // null = still loading the stored flag, true/false = resolved.
  bool? _accepted;

  @override
  void initState() {
    super.initState();
    loadDataSharingConsent().then((value) {
      if (mounted) setState(() => _accepted = value);
    });
  }

  Future<void> _accept() async {
    await saveDataSharingConsent(true);
    if (mounted) setState(() => _accepted = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted == null) {
      // Brief blank frame while SharedPreferences resolves — matches bg color
      // so there's no flash before either screen appears.
      return Scaffold(backgroundColor: AppConstants.bgColor);
    }
    if (_accepted == true) {
      return const MainScreen();
    }
    return ConsentScreen(onAccepted: _accept);
  }
}
