import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key of this machine – outside the repository:
// FAMIO_SIGNING (path to a key.properties with storeFile, storePassword,
// keyAlias, keyPassword), default ~/Famio/keys/android/key.properties.
// Without it, release builds fall back to the debug key.
// Text recognition (appointments from photos) and the barcode scanner
// need recognition models. The small package for 64-bit phones
// (`-P famioArm64=true`) takes them from Google Play services, which load
// them once on first use; the package for all phones keeps them inside and
// works without Google services. Either way the pictures stay on the phone.
val playServicesModels = project.hasProperty("famioArm64")

val signingProperties = Properties().apply {
    val file = file(
        System.getenv("FAMIO_SIGNING")
            ?: "${System.getProperty("user.home")}/Famio/keys/android/key.properties",
    )
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "de.status403.famio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications for scheduled notifications.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "de.status403.famio"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "PLAY_SERVICES_MODELS", "$playServicesModels")
        // The smaller package for 64-bit phones (server updates): with
        // `--target-platform android-arm64 -P famioArm64=true` also the
        // plugins' native code (text recognition …) only for arm64.
        if (project.hasProperty("famioArm64")) {
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
        }
    }

    signingConfigs {
        if (signingProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    // "prod" is the family's Famio; "dev" (flutter run/build --flavor dev)
    // installs next to it with its own id, name and data – for tests on a
    // real phone. Flutter knows the flavor's id, so it never touches prod.
    flavorDimensions += "env"
    productFlavors {
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "Famio")
        }
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Famio Dev")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
}

// Prod is for phones: x86_64 (emulators, a few Chromebooks) would add
// about a third to the APK (text recognition, barcode scanner). Famio Dev
// keeps it for the emulator.
androidComponents {
    onVariants(selector().withFlavor("env" to "prod")) { variant ->
        variant.packaging.jniLibs.excludes.add("lib/x86_64/**")
        variant.packaging.jniLibs.excludes.add("lib/x86/**")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    // Text in photos (appointments from a letter), on the phone; the model
    // inside the app or from Google Play services (see playServicesModels).
    if (playServicesModels) {
        implementation("com.google.android.gms:play-services-mlkit-text-recognition:19.0.1")
    } else {
        implementation("com.google.mlkit:text-recognition:16.0.1")
    }
    // Scanning letters and forms as PDF: the scanner comes with Play
    // services, the pages stay on the phone until Famio uploads them.
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0")
    testImplementation("junit:junit:4.13.2")
    // The real org.json: android.jar only has stubs in unit tests.
    testImplementation("org.json:json:20240303")
}
