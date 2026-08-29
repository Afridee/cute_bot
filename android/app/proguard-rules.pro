# Flutter embedding + plugins (MethodChannel, JNI).
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

-keepclasseswithmembernames class * {
    native <methods>;
}

# Manifest components, MethodChannels, WorkManager watchdog.
-keep class com.cutebot.cute_bot.** { *; }
-keep class * extends androidx.work.ListenableWorker { *; }

# Foreground-task plugin: service name is hardcoded in AndroidManifest.
-keep class com.pravera.flutter_foreground_task.** { *; }
