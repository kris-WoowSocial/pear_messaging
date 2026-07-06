buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.google.gms:google-services:4.4.0")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Force all Compose libraries to a consistent version.
// Some dependencies (e.g. flutter_callkit_incoming, flutter_stripe) pull in
// activity-compose:1.10.1 which requires Compose UI 1.7.x. Without this,
// Gradle resolves Compose UI to 1.6.0 causing a NoSuchMethodError for
// performImeAction$default at runtime on Accessibility interactions.
val composeVersion = "1.7.8"
subprojects {
    configurations.all {
        resolutionStrategy.eachDependency {
            if (requested.group == "androidx.compose.ui" ||
                requested.group == "androidx.compose.foundation" ||
                requested.group == "androidx.compose.material" ||
                requested.group == "androidx.compose.runtime" ||
                requested.group == "androidx.compose.animation"
            ) {
                useVersion(composeVersion)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
