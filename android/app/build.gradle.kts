plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.tractorgps_v3_0_5"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.tractorgps_v3_0_5"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            // Note: Removing .debug suffix to share job storage with release builds
            // applicationIdSuffix = ".debug"
            resValue("string", "app_name", "PasturePath (Debug)")
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Flutter still reports app-release.apk; also copy PasturePath-<version>.apk
android.applicationVariants.configureEach {
    val version = versionName
    val mode = buildType.name
    assembleProvider.configure {
        doLast {
            val dir = layout.buildDirectory.get().asFile.resolve("outputs/flutter-apk")
            val src = dir.resolve("app-$mode.apk")
            if (src.exists() && !version.isNullOrBlank()) {
                src.copyTo(dir.resolve("PasturePath-$version.apk"), overwrite = true)
            }
        }
    }
}
