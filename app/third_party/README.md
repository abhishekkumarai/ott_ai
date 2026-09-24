# Vendored packages

## flutter_inappwebview_android 1.1.3
Unmodified except `android/build.gradle`: `proguard-android.txt` -> `proguard-android-optimize.txt`.
Current Android Gradle Plugin rejects the old default ProGuard file, which breaks `flutter build apk`.
Drop this override (pubspec `dependency_overrides`) once a stable upstream release fixes it.
