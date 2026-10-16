# 人情礼金记账系统 Android APK 打包指南 (Android Build)

> 本文档介绍了如何通过 GitHub Actions CI/CD 流水线自动化将项目打包为独立的 Android 原生 APK 安装包。  
> 快速启动请参考主页 [README.md](../README.md)。

---

## 一、打包方案概览

本项目原生支持通过 Python for Android (uildozer) 工具链构建为离线随身携带的 APK 应用，并在 GitHub 托管独立的专有仓库 [gift_bookkeeping_apk](https://github.com/18227370901/gift_bookkeeping_apk.git)。

项目已集成全自动 GitHub Actions 流水线，无需本地繁琐配置 Android SDK / NDK 开发环境，推送代码即可自动产出可安装的 .apk 文件。

---

## 📱 打包为 Android APK (通过 GitHub Actions)

本仓库已预置 GitHub Actions 自动化构建工作流：
1. 将代码提交至您的 GitHub 仓库。
2. 进入 GitHub 仓库页面的 **Actions** 标签页。
3. 选择 **Build and Release Android APK** 工作流，点击 **Run workflow**。
4. 编译完成后即可在 **Artifacts** 或 **Releases** 下载安装包。

---


---

