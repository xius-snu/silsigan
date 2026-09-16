// Generated from the Firebase Android/iOS apps in project silsigan-ebbee.
// Re-run `flutterfire configure` if you add another platform; it will
// overwrite this file. These values are client config (package-restricted),
// not the Render service-account secret.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Firebase is not configured for web.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        throw UnsupportedError(
          'Firebase is not configured for $defaultTargetPlatform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAzTqbyNRJ_K6UZ5DlXW565YRgXzsFatog',
    appId: '1:508835371112:android:9d4a9e0c569c24daa043dd',
    messagingSenderId: '508835371112',
    projectId: 'silsigan-ebbee',
    storageBucket: 'silsigan-ebbee.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAXADpGKLotVjdX1FLbxmlsLhpAMfY95VY',
    appId: '1:508835371112:ios:f69940a457fd58c0a043dd',
    messagingSenderId: '508835371112',
    projectId: 'silsigan-ebbee',
    storageBucket: 'silsigan-ebbee.firebasestorage.app',
    iosBundleId: 'com.silsigan.app',
  );

  /// Same Firebase iOS app — macOS shares bundle id `com.silsigan.app`.
  static const FirebaseOptions macos = ios;
}
