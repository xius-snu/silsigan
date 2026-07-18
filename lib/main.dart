import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'providers/theme_provider.dart';
import 'services/user_service.dart';
import 'services/background_service.dart';
import 'utils/constants.dart';

// Orientation is locked per-platform so iPad can support all orientations
// (required by Apple for iPad multitasking) while iPhone stays portrait:
//   • iPhone  → Info.plist UISupportedInterfaceOrientations = Portrait only
//   • iPad    → Info.plist UISupportedInterfaceOrientations~ipad = all four
//   • Android → AndroidManifest android:screenOrientation="portrait"
// A global SystemChrome.setPreferredOrientations lock is intentionally NOT used
// here — it would also force iPad to portrait and defeat the above.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundService.init();
  // Resolve the saved theme before the first frame so a dark-mode user never
  // sees a light flash; the override seeds the provider with the saved value.
  final darkMode = await loadSavedDarkMode();
  AppConstants.isDark = darkMode;
  await UserService.instance.init();
  UserService.instance.reportActivity('app_open');
  runApp(
    ProviderScope(
      overrides: [
        darkModeProvider.overrideWith((ref) => darkMode),
      ],
      child: const SilsiganApp(),
    ),
  );
}
