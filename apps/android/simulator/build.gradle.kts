plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
}

application {
    mainClass.set("app.inkbridge.simulator.MainKt")
}
