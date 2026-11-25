# 第三方组件及源码

本项目新增的 SDK 桥接、原生界面和安装工具使用 GPL-3.0-or-later。根目录 LICENSE 是 GPL 第 3 版全文；可以依据第 3 版或任何后续版本使用这些新增代码。

FineWine 来自 [stoicswe/Endfield_FineWine](https://github.com/stoicswe/Endfield_FineWine)，固定源码提交 `fbac1a88e7dc1c1c40881a6b5a367387780a2361`，发布模块版本 3.1.2。完整项目快照保存在 `ThirdParty/FineWine`，原有许可证、作者信息、补丁和构建脚本保持在该目录中。

构建过程下载上述发布版本的 `endfield-wine-modules.tar.gz`，并校验 `dependencies.lock.json` 中的 SHA-256。归档内的 Wine 模块使用 LGPL-2.1-or-later，MoltenVK 使用 Apache-2.0；这些组件不因与本项目一同分发而变更许可证。模块的 `COPYING.LIB`、`LICENSE.MoltenVK`、`SOURCE.txt` 和 `SHA256SUMS` 随应用一起分发。

这些模块的基础源码来源是 [CrossOver 26.3.0 开源源码归档](https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz) 与 [MoltenVK 固定提交](https://github.com/KhronosGroup/MoltenVK/tree/db66022459ffb663aa2b50f6b018bc2e124f5edf)。对应的 FineWine 修改与构建方法见本地 `ThirdParty/FineWine/patches`、`scripts` 和各自的源码锁定文件。发布二进制前，分发者应按照各组件许可证提供对应源码及必要构建材料，保留以上信息。

CrossOver 商业应用、游戏、官方 SDK、图标、背景、字体与商标归各自权利人所有。它们不包含在本项目的授权范围内。本仓库和 DMG 不分发 CrossOver 商业应用、官方 SDK DLL、游戏安装文件或从 SDK 提取的美术资源；安装和运行时从用户本机已有文件读取。

`Resources/AppIcon.png` 是用户提供的应用及磁盘图标原图，权利归原权利人。本项目的 GPL 代码许可证不授予该图片或相关商标的权利。构建脚本保留原图比例及透明度，将其转换为 macOS 图标尺寸。
