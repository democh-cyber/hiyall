# R8 / ProGuard rules for the release build (build.gradle.kts: isMinifyEnabled = true).
# Libraries ship their own consumer rules inside their AARs; only what they do not cover is here. Every rule
# says why it exists. Test a minified build (`scripts/build-release.sh android`, then install the AAB with
# bundletool) before relying on a change; R8 problems show up at run time, not in the compile.

# Stack traces: keep file names and line numbers so the mapping file (build/app/outputs/mapping/release/mapping.txt)
# can turn a Sentry or Play crash back into source. Upload mapping.txt and build/symbols with every release.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Annotations and generic signatures that reflection-based libraries (Tink, Sentry) read at run time.
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# Firebase Auth / Messaging / Core: discovered at run time through ComponentDiscoveryService, which instantiates the
# registrar classes named in the merged manifest metadata by reflection. The libraries keep these in their own
# rules; this is the belt for the one entry point we depend on directly.
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-keep class com.google.firebase.provider.FirebaseInitProvider { *; }

# firebase_messaging (Flutter plugin): the background service and receiver are named in the plugin manifest and
# started by the system, so they must keep their names.
-keep class io.flutter.plugins.firebase.messaging.** { *; }

# Sentry (sentry_flutter -> sentry-android): the native SDK is started by the plugin and reads its integrations by
# class name; its consumer rules cover this, the keep is repeated so a rules regression cannot silently disable
# crash capture.
-keep class io.sentry.** { *; }
-dontwarn io.sentry.**

# flutter_secure_storage: ciphers and the Android Keystore are looked up by algorithm name and the plugin's own
# classes are called through a method channel. Keeping the plugin package costs a few KB and avoids losing chat
# keys to a renamed class.
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Tink / androidx.security (pulled in by the secure-storage and Firebase dependencies): optional annotation
# libraries that are referenced but not shipped; without these R8 stops with "Missing class" errors.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**

# Rust (hiyall_e2ee via flutter_rust_bridge): bound through dart:ffi by symbol name, not through JNI, so no Java or
# Kotlin class has to be kept for it. The native library is not touched by R8. If JNI is ever added, add its
# classes here.

# Google Play Core / deferred components: Flutter's engine refers to these classes only when deferred components
# are used (they are not). Silences the R8 missing-class error.
-dontwarn com.google.android.play.core.**
