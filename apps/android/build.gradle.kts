plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    id("org.jetbrains.kotlin.jvm") version "2.0.21" apply false
}

// Keep build output out of the (Dropbox-synced) source tree.
subprojects {
    layout.buildDirectory.set(
        file("${System.getProperty("user.home")}/Library/Caches/InkBridge/android-build/${project.name}")
    )
}
