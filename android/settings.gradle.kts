pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // --- 插入阿里云镜像开始 ---
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        // --- 插入阿里云镜像结束 ---

        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        // Flutter 官方国内 CDN Maven 仓库（storage.flutter-io.cn 镜像 download.flutter.io）
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        // 清华 Flutter Maven 镜像（备用）
        maven { url = uri("https://mirrors.tuna.tsinghua.edu.cn/flutter/download.flutter.io") }
        // Maven Central + JitPack
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
        // Google Maven
        google()
        // 阿里云镜像
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        // Microsoft Maven packages (用于 Microsoft Recognizers)
        maven { url = uri("https://pkgs.dev.azure.com/xamarin/maven/v3/index.json") }
    }
}



plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")