allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("${project(":flutter_background_geolocation").projectDir}/libs") }
        maven { url = uri("https://developer.huawei.com/repo/") }
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
    project.pluginManager.withPlugin("com.android.library") {
        val android = project.extensions.getByType(com.android.build.gradle.LibraryExtension::class.java)
        if (android.namespace.isNullOrEmpty()) {
            val manifest = project.file("src/main/AndroidManifest.xml")
            if (manifest.exists()) {
                val pkg = Regex("""package="([^"]+)"""")
                    .find(manifest.readText())?.groupValues?.get(1)
                if (!pkg.isNullOrEmpty()) {
                    android.namespace = pkg
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
