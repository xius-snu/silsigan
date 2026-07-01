import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/user_service.dart';
import 'services/background_service.dart';

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
  await UserService.instance.init();
  UserService.instance.reportActivity('app_open');
  runApp(
    const ProviderScope(
      child: SilsiganApp(),
    ),
  );
}
