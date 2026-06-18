# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Firebase / FCM — keep rules are injected by google-services plugin via
# the merged ProGuard config. No manual rules needed here.

# Prevent R8 from stripping serialization
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature

# For native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# JSON serialization support removed - no longer needed for Firebase

# Keep your models if you use Gson/JSON serialization
-keep class com.kamryy.sealed.** { *; }

# Play Core library (not used but referenced by Flutter)
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
