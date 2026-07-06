import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui/screens/main_screen.dart';
import 'ui/screens/consent_screen.dart';
import 'providers/consent_provider.dart';
import 'utils/constants.dart';

class SilsiganApp extends StatelessWidget {
  const SilsiganApp({super.key});

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));

    return MaterialApp(
      title: 'Silsigan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppConstants.bgColor,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppConstants.bgColor,
          elevation: 0,
          centerTitle: false,
          foregroundColor: AppConstants.textPrimary,
          iconTheme: IconThemeData(color: AppConstants.textPrimary),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.grey,
          brightness: Brightness.light,
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: AppConstants.textPrimary,
          selectionColor: AppConstants.selectionHighlightColor,
          selectionHandleColor: AppConstants.selectionHandleColor,
        ),
        useMaterial3: true,
      ),
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
      return const Scaffold(backgroundColor: AppConstants.bgColor);
    }
    if (_accepted == true) {
      return const MainScreen();
    }
    return ConsentScreen(onAccepted: _accept);
  }
}
