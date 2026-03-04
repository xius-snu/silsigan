import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui/screens/main_screen.dart';
import 'ui/screens/history_screen.dart';
import 'ui/screens/session_detail_screen.dart';
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
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const MainScreen(),
        '/history': (context) => const HistoryScreen(),
        '/detail': (context) => const SessionDetailScreen(),
      },
    );
  }
}
