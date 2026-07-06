plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
   namespace = "com.vant.chat"
    
    // 1. Updated to SDK 36 as required by mobile_scanner
    compileSdk = 36 

    // 2. Updated to NDK 27.1 (required by plugins)
    ndkVersion = "27.1.12297006"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.vant.chat"
        
        // 3. Increased minSdk to 23 for mobile_scanner compatibility
        minSdk = 23 
        
        // 4. Target SDK should match or be lower than compileSdk
        targetSdk = 36 
        
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "env"

    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Vant Chat Dev")
        }
        create("prod") {
            dimension = "env"
            // no suffix - keeps applicationId = com.vant.chat (existing production id)
            resValue("string", "app_name", "Vant Chat")
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    implementation("io.branch.sdk.android:library:5.+")
    implementation("com.google.android.material:material:1.9.0")
    implementation("com.google.firebase:firebase-messaging:24.1.0")
    implementation("com.github.bumptech.glide:glide:4.16.0")
    // Self-managed ConnectionService for incoming call UI over lock screen (Android 14+)
    implementation("androidx.core:core-telecom:1.0.0")
}
