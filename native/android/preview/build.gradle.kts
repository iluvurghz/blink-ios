import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

// Берём из приложения только то, что не зависит от Android: экраны, шина тостов, состояние плеера и переходы.
// Шрифты (R.font) и всё остальное, что трогает систему, заменяют заглушки из src/main/kotlin.
val copyAppUi = tasks.register<Sync>("copyAppUi") {
    from("../app/src/main/kotlin") {
        include(
            "app/blink/player/Nav.kt",
            "app/blink/player/data/Toasts.kt",
            "app/blink/player/playback/PlayerUi.kt",
            "app/blink/player/ui/**",
        )
        exclude("app/blink/player/ui/Fonts.kt")
    }
    into(layout.buildDirectory.dir("generated/appui"))
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    sourceSets.main {
        kotlin.srcDir(copyAppUi.map { it.destinationDir })
    }
}

dependencies {
    implementation("app.blink:blink-core")
    implementation(compose.runtime)
    implementation(compose.foundation)
    implementation(compose.ui)
    implementation(compose.animation)
    implementation(compose.desktop.currentOs)
    implementation("io.coil-kt.coil3:coil-compose:${libs.versions.coil.get()}")
    implementation(libs.kotlinx.coroutines.core)
}

tasks.register<JavaExec>("screenshots") {
    group = "verification"
    description = "Рисует экраны приложения в PNG"
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass.set("preview.MainKt")
    systemProperty("java.awt.headless", "true")
    systemProperty("blink.fonts", file("../../design/res/font").absolutePath)
    systemProperty("blink.out", layout.buildDirectory.dir("screens").get().asFile.absolutePath)
}
