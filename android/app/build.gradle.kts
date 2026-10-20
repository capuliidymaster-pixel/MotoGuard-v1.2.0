plugins {
    id("com.android.application")

    // Firebase / Google Services
    id("com.google.gms.google-services")

    // Kotlin
    id("kotlin-android")

    // Flutter
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // Android package configuration
    namespace = "com.example.moto"

    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        // Must match the registered Firebase Android package
        applicationId = "com.g7psu.motoguard"

        minSdk = flutter.minSdkVersion
        targetSdk = 36

        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    compileOptions {
        // Use Java 17 consistently
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        // Required by flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
    }

    buildTypes {
        release {
            // For testing only; configure release signing before publishing
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        )
    }
}

dependencies {
    // Java API desugaring for notification compatibility
    coreLibraryDesugaring(
        "com.android.tools:desugar_jdk_libs:2.1.5"
    )
}

flutter {
    source = "../.."
}