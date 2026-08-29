plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cutebot.cute_bot"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cutebot.cute_bot"
        // Project floor is Android 11 (API 30). flutter_gemma_litertlm's
        // libLiteRtLm needs API 30+ Bionic syscalls (pthread_cond_clockwait).
        // The original brief said API 29; this is a hard engine constraint.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // .litertlm FFI is arm64-v8a only. Restrict so Play doesn't offer
        // a broken APK to 32-bit / x86 devices. Replace (don't +=) so
        // plugin jni from sherpa-onnx x86/armeabi never merge in.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // sherpa-onnx ships onnxruntime; keep a single copy if another
            // plugin also unpacks it.
            pickFirsts += "**/libonnxruntime.so"
            pickFirsts += "**/libc++_shared.so"
            // Keep native libs compressed in the APK. AGP's default
            // (uncompressed, page-aligned) would nearly triple sideload
            // size — LiteRT + onnxruntime dominate the package.
            useLegacyPackaging = true
            excludes += "lib/armeabi-v7a/**"
            excludes += "lib/x86/**"
            excludes += "lib/x86_64/**"
            // LiteRT-LM's hook also ships Qualcomm Hexagon NPU (QNN) and
            // WebGPU companions. Companion inference is OpenCL GPU (see
            // AndroidManifest libvndksupport / libOpenCL). NPU is unused
            // and the skel/stub set is tens of MB.
            excludes += "**/libQnn*.so"
            excludes += "**/libLiteRtDispatch_Qualcomm.so"
            excludes += "**/libLiteRtWebGpuAccelerator.so"
            excludes += "**/libLiteRtTopKWebGpuSampler.so"
        }
        dex {
            useLegacyPackaging = true
        }
        resources {
            excludes += "META-INF/androidx/**"
            excludes += "META-INF/*.version"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Watchdog worker (M2.5). WorkManager survives process death and
    // reboot, which is the whole point of the safety net.
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    // JVM unit test for the watchdog decision (BotServiceStarterTest).
    testImplementation("junit:junit:4.13.2")
}
