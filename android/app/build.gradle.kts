import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing is optional. When android/keystore.properties exists (gitignored; storeFile,
// storePassword, keyAlias, keyPassword) a release build is signed with that keystore. Absent, a
// release build is still produced but signed with the debug key: fine for a local install,
// refused by Google Play. Debug builds never need it.
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystorePropertiesFile.exists()

// Push notifications (push/PushNotifications) need app/google-services.json - the Firebase app
// registration for com.reelhouse.android, gitignored. Without it the app still builds and runs;
// Firebase just never initialises and Settings says push isn't set up in this build.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.reelhouse.android"
    // Google Play requires new apps to target API 36 (Android 16) from 31 Aug 2026; compileSdk
    // follows so the code is checked against the SDK it declares support for.
    compileSdk = 36

    defaultConfig {
        applicationId = "com.reelhouse.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        // Every build type is the same app: "+ Add", downloads, Import a list and Suggested for
        // you are in debug and release alike.
        release {
            signingConfig = if (hasReleaseKeystore) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    // On-device tests (src/androidTest): Android Auto's media browsing, driven through the
    // platform MediaBrowser against an in-process stub server.
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")

    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.core:core-splashscreen:1.0.1")
    // Offline downloads of tracks and episodes run as a WorkManager job (audio/AudioDownloads).
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    // Push notifications: new podcast episodes, finished downloads, sign-in alerts. Inert in a
    // build without google-services.json - see the top of this file.
    implementation("com.google.firebase:firebase-messaging:25.1.1")

    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.5.1")
    implementation("androidx.media3:media3-ui:1.5.1")
    // Music & Podcasts: the shared audio player runs in a MediaLibraryService, which gives the
    // media notification, lock screen, Bluetooth buttons and Android Auto's browsable library.
    // See audio/AudioPlaybackService.
    implementation("androidx.media3:media3-session:1.5.1")
    // The session's callbacks answer with ListenableFutures; this turns a coroutine into one.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.9.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub that throws on the JVM; the parsing code speaks JSON
    // throughout, so its unit tests need the real thing.
    testImplementation("org.json:json:20240303")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}
