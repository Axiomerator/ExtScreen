import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. The key never lives in the repository: point EXTSCREEN_KEYSTORE_PROPERTIES at a
// properties file (storeFile, storePassword, keyAlias, keyPassword), or put `keystore.properties`
// next to this project's settings file. Without one, release builds are left unsigned.
val keystoreProps = Properties().apply {
    val path = System.getenv("EXTSCREEN_KEYSTORE_PROPERTIES") ?: rootProject.file("keystore.properties").path
    val file = File(path)
    if (file.isFile) file.inputStream().use { load(it) }
}

android {
    namespace = "com.extscreen"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.extscreen"
        minSdk = 26 // Android 8.0 Oreo+ for MediaCodec low latency and modern NDK
        targetSdk = 34
        versionCode = 5
        versionName = "1.2.0"

        ndk {
            // 64-bit and 32-bit ARM phones/tablets, plus x86_64 (Chromebooks, emulators).
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a", "x86_64"))
        }
    }

    signingConfigs {
        if (keystoreProps.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            // The native library calls back into Kotlin by name over JNI, so no shrinking/renaming.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            // jniLibs directory where the compiled Rust .so is placed
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../../ui"
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
