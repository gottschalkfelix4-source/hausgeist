import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-Signatur: lokal aus android/key.properties, in der CI aus Umgebungsvariablen.
// Fehlt beides, wird mit dem Debug-Schluessel signiert (nur fuer Tests).
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signingValue(prop: String, env: String): String? =
    keyProps.getProperty(prop) ?: System.getenv(env)?.takeIf { it.isNotBlank() }
val releaseStoreFile = signingValue("storeFile", "HAUSGEIST_KEYSTORE")

android {
    namespace = "de.hausgeist.wall"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "de.hausgeist.wall"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Tablets sind ARM: x86-Bibliotheken (v. a. der Spracherkennung, ~30 MB) nicht einpacken.
    packaging {
        jniLibs { excludes += listOf("lib/x86/**", "lib/x86_64/**") }
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = signingValue("storePassword", "HAUSGEIST_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "HAUSGEIST_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "HAUSGEIST_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
