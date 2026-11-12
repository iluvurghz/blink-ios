// Просмотр экранов Android-приложения на обычном компьютере (Compose для JVM + Skia), без эмулятора и Android SDK.
// Берёт те же файлы интерфейса, что и приложение, подставляя вместо Android-кода заглушки из src/main/kotlin/app.
pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { mavenCentral() }
    versionCatalogs {
        create("libs") { from(files("../gradle/libs.versions.toml")) }
    }
}

rootProject.name = "blink-preview"
includeBuild("../core")
