import com.android.build.api.dsl.LibraryExtension

import org.gradle.api.tasks.compile.JavaCompile
import org.gradle.jvm.toolchain.JavaLanguageVersion
import org.gradle.jvm.toolchain.JavaToolchainService
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// flutter_reactive_ble 5.5.0 declares compileSdk 33 after plugin application.
// Align Android library subprojects after evaluation without editing pub cache.
subprojects {
    if (state.executed) {
        extensions.findByType(LibraryExtension::class.java)?.compileSdk = 36
    } else {
        afterEvaluate {
            extensions.findByType(LibraryExtension::class.java)?.compileSdk = 36
        }
    }
}
