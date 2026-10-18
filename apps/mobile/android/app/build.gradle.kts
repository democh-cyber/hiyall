import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. android/key.properties (git-ignored; CI writes it from secrets) must name a private upload
// keystore: storeFile, storePassword, keyAlias, keyPassword. A release task without a complete file fails here,
// at configuration time, with the reason. There is no fallback to the debug key, ever.
val signingFile = rootProject.file("key.properties")
val signingValues = Properties()
if (signingFile.exists()) signingFile.inputStream().use { signingValues.load(it) }
val releaseRequested = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
if (releaseRequested) {
    if (!signingFile.exists()) {
        throw GradleException("Release signing is not configured: android/key.properties is missing. See docs/mobile/16-release-and-reliability.md (Android signing). Debug keys are never used for release.")
    }
    val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword").filter { signingValues.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) {
        throw GradleException("android/key.properties is missing: ${missing.joinToString(", ")}")
    }
    if (!file(signingValues.getProperty("storeFile")).isFile) {
        throw GradleException("android/key.properties: storeFile does not point at an existing keystore file")
    }
}

// AdMob app id for the manifest (google_mobile_ads). Never committed: ADMOB_APP_ID_ANDROID from the environment or a gradle property.
// Debug and profile builds fall back to Google's published TEST app id; a release build without one fails here, with the reason.
val admobTestAppId = "ca-app-pub-3940256099942544~3347511713"
val admobAppId = (System.getenv("ADMOB_APP_ID_ANDROID") ?: (project.findProperty("ADMOB_APP_ID_ANDROID") as String?)).orEmpty().trim()
if (releaseRequested && admobAppId.isEmpty()) {
    throw GradleException("ADMOB_APP_ID_ANDROID is not set: the release build needs the AdMob app id of the Android app (ca-app-pub-<publisher>~<app>). See docs/mobile/NN-shop-and-ads.md. The Google TEST id is for debug builds only.")
}
if (releaseRequested && admobAppId == admobTestAppId) {
    throw GradleException("ADMOB_APP_ID_ANDROID is Google's TEST app id: a release build needs the real one.")
}

android {
    namespace = "app.hiyall.hiyall"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Final and permanent once the app is on Play: it must equal the namespace above, the MainActivity package,
        // iOS PRODUCT_BUNDLE_IDENTIFIER and the Android app registered in Firebase (scripts/release-preflight.sh checks).
        applicationId = "app.hiyall.hiyall"
        // The Flutter SDK pins these (3.47.6: minSdk 24, compileSdk and targetSdk 36 = Android 16, which is what
        // Google Play requires of new apps and updates from 31 August 2026). Re-check the Play requirement and the
        // Flutter default before every release; docs/mobile/16-release-and-reliability.md, "Android".
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionName and versionCode come from pubspec.yaml (`version: 1.0.0+1`) or from
        // `flutter build --build-name --build-number`, which scripts/build-release.sh passes. Play rejects a
        // versionCode it has seen before, so the build number must grow on every upload.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["admobAppId"] = if (admobAppId.isEmpty()) admobTestAppId else admobAppId
    }

    signingConfigs {
        if (signingFile.exists()) create("release") {
            keyAlias = signingValues.getProperty("keyAlias")
            keyPassword = signingValues.getProperty("keyPassword")
            storeFile = file(signingValues.getProperty("storeFile"))
            storePassword = signingValues.getProperty("storePassword")
        }
    }
    buildTypes {
        release {
            // Only ever the release config; with no key.properties the release tasks have already failed above.
            if (signingFile.exists()) signingConfig = signingConfigs.getByName("release")
            // R8 shrinking and obfuscation, with the keep rules (each explained) in proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Ship a symbol table for the Rust library in the bundle so Play and Sentry can name native frames.
            ndk { debugSymbolLevel = "SYMBOL_TABLE" }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
