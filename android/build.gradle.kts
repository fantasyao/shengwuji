plugins {
    java
}

allprojects {
    // repositories 已移至 settings.gradle.kts 的 dependencyResolutionManagement
    // 使用 RepositoriesMode.PREFER_SETTINGS 确保优先使用settings配置
}

// 设置自定义 build 目录
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

// 配置 clean 任务
tasks.named<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// 统一配置 Java Toolchain (根项目)
java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

subprojects {
    // 设置子项目的 build 目录
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    if (project.name != "app") {
        project.evaluationDependsOn(":app")
    }

    // 重点：使用 afterEvaluate 确保在所有插件加载完后执行强制覆盖
    afterEvaluate {
        // 1. 统一所有 Java 编译任务 (解决 audioplayers 等插件的 1.8 冲突)
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = "17"
            targetCompatibility = "17"
            // 添加你想要的 lint 参数
            options.compilerArgs.addAll(listOf("-Xlint:unchecked", "-Xlint:deprecation"))
        }

        // 2. 统一所有 Kotlin 编译任务
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }

        // 3. 针对 Android 扩展配置进行强制覆盖
        plugins.withType<com.android.build.gradle.BasePlugin> {
            extensions.configure<com.android.build.gradle.BaseExtension> {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
    }
}