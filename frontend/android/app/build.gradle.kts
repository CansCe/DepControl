plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.depcontrol.frontend"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The published identity of the app. Deliberately not the generated
        // `app.depcontrol.frontend`: `frontend` is this repo's name for a
        // workspace member, not something that belongs in a Play Store listing.
        //
        // Change this before the first upload if you want something else — it
        // is permanent afterwards, and a published application ID cannot be
        // altered without shipping a different app. The `namespace` above is
        // separate: it only names the generated R class, so it can keep
        // matching the Kotlin package.
        applicationId = "app.depcontrol"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Still the debug keys, so `flutter run --release` works out of the
            // box. An APK signed with these can be installed and tested but
            // cannot be published — Play refuses the debug certificate, and an
            // app's signing key cannot be changed after the first upload.
            //
            // Left as-is on purpose: a release keystore is a secret, generated
            // once with `keytool` and kept out of the repo. See docs/DEPLOY.md.
            signingConfig = signingConfigs.getByName("debug")
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
