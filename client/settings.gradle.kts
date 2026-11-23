pluginManagement {
    val local = java.util.Properties().apply {
        val propertiesFile = file("local.properties")
        if (propertiesFile.isFile) propertiesFile.inputStream().use { load(it) }
    }
    val flutterSdk = gradle.startParameter.projectProperties["flutter.sdk"]
        ?: local.getProperty("flutter.sdk")
        ?: System.getenv("FLUTTER_ROOT")
        ?: error("Set flutter.sdk in client/local.properties or set FLUTTER_ROOT to the pinned Flutter SDK.")
    includeBuild(file("$flutterSdk/packages/flutter_tools/gradle"))

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
rootProject.name = "extscreen-client"
include(":app")
