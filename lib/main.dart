import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'app.dart';
import 'providers/theme_provider.dart';
import 'providers/desktop_audio_source_provider.dart';
import 'services/user_service.dart';
import 'services/account_service.dart';
import 'services/background_service.dart';
import 'utils/constants.dart';
import 'utils/desktop.dart';

// Orientation is locked per-platform so iPad can support all orientations
// (required by Apple for iPad multitasking) while iPhone stays portrait:
//   • iPhone  → Info.plist UISupportedInterfaceOrientations = Portrait only
//   • iPad    → Info.plist UISupportedInterfaceOrientations~ipad = all four
//   • Android → AndroidManifest android:screenOrientation="portrait"
// A global SystemChrome.setPreferredOrientations lock is intentionally NOT used
// here — it would also force iPad to portrait and defeat the above.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // sqflite has no Windows/Linux plugin; FFI + bundled sqlite3.dll is required
  // before any DatabaseService call (history, autosave).
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // FFI's default path is `.dart_tool/...` relative to cwd, which is
    // unwritable under Program Files. Keep history in per-user AppData.
    final support = await getApplicationSupportDirectory();
    await databaseFactory.setDatabasesPath(support.path);
  }
  BackgroundService.init();
  // A sticky mic foreground service can outlive (even resurrect after) the
  // app being swiped away mid-recording; reap it so a relaunch doesn't sit
  // next to a zombie holding wake locks and a stale notification.
  BackgroundService.reapZombieService();
  // Resolve the saved theme before the first frame so a dark-mode user never
  // sees a light flash; the override seeds the provider with the saved value.
  final darkMode = await loadSavedDarkMode();
  AppConstants.isDark = darkMode;
  await UserService.instance.init();
  // Cheap: reads the saved account out of prefs. Any network verification it
  // needs runs in the background so it can't delay the first frame.
  await AccountService.instance.restore();
  UserService.instance.reportActivity('app_open');
  final desktopAudio = isDesktopPlatform
      ? await loadSavedDesktopAudioSettings()
      : const DesktopAudioSettings();
  runApp(
    ProviderScope(
      overrides: [
        darkModeProvider.overrideWith((ref) => darkMode),
        if (isDesktopPlatform)
          desktopAudioSettingsProvider.overrideWith((ref) => desktopAudio),
      ],
      child: const SilsiganApp(),
    ),
  );
}
