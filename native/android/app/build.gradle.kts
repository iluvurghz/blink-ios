import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// Публичный ключ Supabase в репозиторий не кладём: он приходит при сборке (свойство или переменная окружения).
val anonKey = providers.gradleProperty("blink.supabaseAnonKey")
    .orElse(providers.environmentVariable("BLINK_SUPABASE_ANON_KEY"))
    .orElse("")
val versionTag = providers.gradleProperty("blink.versionName").orElse("0.1.0")
val buildNumber = providers.environmentVariable("GITHUB_RUN_NUMBER").map { it.toInt() }.orElse(1)

android {
    namespace = "app.blink.player"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.blink.player"
        minSdk = 26
        targetSdk = 36
        versionCode = buildNumber.get()
        versionName = versionTag.get()
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${anonKey.get()}\"")
        buildConfigField("String", "BASE_URL", "\"https://blinkmusic.cc\"")
    }

    // Ключ debug.keystore общеизвестный: он нужен, чтобы сборки из CI обновлялись друг поверх друга
    // (скачанные треки не пропадают). Для магазинов будет свой ключ.
    signingConfigs {
        create("blink") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            signingConfig = signingConfigs.getByName("blink")
        }
        // Как release (быстро, без отладки), но с общим ключом: ставится на телефон одним файлом.
        create("alpha") {
            initWith(getByName("release"))
            applicationIdSuffix = ".alpha"
            versionNameSuffix = "-alpha"
            isMinifyEnabled = false
            isDebuggable = false
            signingConfig = signingConfigs.getByName("blink")
            matchingFallbacks += listOf("release")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("blink")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        // Шрифты и знак иконки общие с iOS: лежат в native/design/res
        getByName("main").res.srcDir("../../design/res")
    }

    packaging {
        resources.excludes += listOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/DEPENDENCIES")
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("app.blink:blink-core")

    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.runtime.compose)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.foundation)
    implementation(libs.compose.animation)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.guava)

    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
}
