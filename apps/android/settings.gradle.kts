pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "InkBridge"

// :core      pure Kotlin/JVM: protocol, input processing, transport, client.
//            No Android imports, so its tests run on the JVM in seconds.
// :app       the Android application (BOOX-facing UI and MotionEvent adapter).
// :simulator a JVM command-line "virtual tablet" for testing the Mac host
//            without hardware.
include(":core", ":app", ":simulator")
