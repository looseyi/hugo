---
title: "浅析 Cocoapods-Binary 实现"
date: 2019-12-21T11:37:41+21:00
draft: false
tags: ['CocoaPods', 'iOS', 'Binary']
categories: ['iOS', 'CocoaPods']
author: "土土Edmond木"
---

## 背景
公司级别的项目在发展过程，不可避免会遇到项目过大，导致的编译和开发效率的降低。在如何提高编译速度，加快生产效率，各大厂都有各种尝试，可惜在业内没有一个成本低、效果好的开源方案。而作者所在的公司，由于业务线聚合，原有两条完全不同的交易线业务以组件的形式合并到主App，加剧了编译的问题。项目的完整编译时间从原有的5分钟，直接 double 到25分钟左右，同时 CI 的打包也不断的往30分钟的趋势奔去。
## 思路
CocoaPods-Binar 是针对二进制化的一个整体的实践，而非像 CocoaPods-Packager 仅仅针对单个私有库的。所谓的二进制化，简单说来可以通过 podSpec 将 source 指向事先打包好的 binary 来提高编译效率，这个是目前的主流做法。当然也可以通过更改编译缓存如 CCache 或者换个编译器 Buck (FB) / Bazel (Google) 来实现分布式编译。微信团队的这篇 [微信编译速度优化](https://mp.weixin.qq.com/s/-wgBhE11xEXDS7Hqgq3FjA) 有进行了比较完整的阐述。而本文的主角 CocoaPods-Binary 是通过将 dependencies 预编译成 binary 后缓存至本地，然后将原有的 Source Code link 到 binary 以几乎零成本的方式实现编译效率的提高。唯一缺点就是无法实现服务端缓存（这是我们需要改造的地方，不过这个可以通过定制化实现)，所谓的分布式的二进制编译。
## CocoaPod-Binary
最早发现这个 plugin 是在浏览官方 blog 时发现的，而且作者还是国内 developer 。该插件发布也有两年多，目前支持到 Pods 版本 1.6.x。我们先来看看类图构成：

![](https://user-gold-cdn.xitu.io/2019/12/21/16f28fd6d97d3ea7?w=2850&h=1490&f=png&s=370440)

CocoaPods 本身提供了比较不错的插件模版，如需要的话可以看这篇文章。CocoaPods-Binary 的核心代码都在 lib/cocoapods-binary 文件夹下。我们来看看整个插件的主要部件，及其对应的作用。
### Main
作为整个插件的执行的入口，通过 CocoaPods 提供的 pre_install hook 在 pod install 的 prepare 阶段拦截到当前的 pod install context，进而 fork 出一份独立的 installer 以完成将预编译源码 clone 至 Pod/_Prebuild 目录下。
### Helper
主要对 Sandbox、Installer、Pod、Podfile Options 相关的类添加各种 attribute 状态来满足逻辑需要。例如，子类化 Sandbox > PrebuildSandbox 来指定 generate frameworks 的地址、prebuild Pods 的地址，以及是否存在编译好的 framework 等；对 Podfile DSL 添加 binary、all_bianry 关键字来控制 binary 和源码的切换。
### Room Build Framework
核心类，通过 xcodebuild 将所有 :binary => true 的 dependencies 编译成 binary 和 dSYM，并输出到指定目录。这里针对 iOS 平台输出的 framework 多做了一步处理，当检测到是 platform 是 iOS 会分别对模拟器和真机设备单独编译，最后再利用 libo 将各自的 binary 和 dSYM 合并成一份输出。
### Prebuild Installer
利用 ruby 语言的动态性，重载 Installer 的 run_plugins_post_install_hooks 以实现 pre_install 结束后触发 build framework 将 dependencies 打包成二进制包。对于 dependencies 是否需要进行预编译是通过检查生成的 framework 中是否存在 xxx_name 文件作为标识该 lib 是否已经完成编译过（xxx 为对应 lib 名称。
### Integration
在插件源码同步完预编译结束后，会将 install context 交还，进入 install 最后阶段。在这里将完成对 binary frameworks 的 symbol link 以替换原有 Pods 源码和 Embed 操作则会修改各个 pod.xcproject 配置，最后生成 project。
## 结果
基本的模块介绍完，我们来看看，引入 CocoaPods-Binary 插件后 Pods 的文件构成：

![](https://user-gold-cdn.xitu.io/2019/12/21/16f28fe274deb12a?w=1218&h=113&f=png&s=42173)

_Prebuild 目录下则完整保存了一份 Pods 源代码，同时多出来的 GeneratedFrameworks 则缓存了预编译后的 binary 文件以及 dSYM 符号表。在最后的 integration 阶段 symbol link 替换完后源码则会被删除同时指向binary。

![](https://user-gold-cdn.xitu.io/2019/12/21/16f28fe4bebba8af?w=805&h=102&f=png&s=26338)

至此，整个 pod install 就算完成了，那 CocoaPods有哪些限制呢？
- 由于 CocoaPods 在 1.7.x 以上版本，修改了 framework 生成逻辑，不会把 bundle copy 至 framework，因此我们需要将 Pod 环境固定到 1.6.2；
- pod 要支持 binary，header ref 需要变更为 #import <>或者 @import 以符合 moduler 标准；
- 统一 CI 和开发的 compiler 环境，如果项目支持 Swift，不同 compiler 编译产物有 Swift 版本兼容问题；
- 最终的 binary size 会比使用源码的时候大一点，不建议最终上传 Store；
- 建议 Git ignore Pods 文件夹，否则在 source code 与 binary 切换过程会有大量的 file change，增加 git 负担；

## 流程图
无图无真相，简单的流程图希望能帮助各位理解 CocoaPods-Binary 作者的基本思路；

![](https://user-gold-cdn.xitu.io/2019/12/21/16f28fe79cec4bae?w=3891&h=2218&f=png&s=435060)