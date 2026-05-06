# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Firebase/FCM ProGuard rules removed in Task 2.5 - production Android
# builds no longer include Google dependencies. UnifiedPush handles delivery.

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
