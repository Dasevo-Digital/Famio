allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// The small package for 64-bit phones also takes the barcode model from
// Google Play services (see app/build.gradle.kts); mobile_scanner reads
// this property.
if (hasProperty("famioArm64")) {
    extra["dev.steenbakker.mobile_scanner.useUnbundled"] = "true"
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
