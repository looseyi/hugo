---
title: "完善 Cocoapods-Binary 支持 Server 端缓存"
date: 2020-01-06T11:40:06+21:00
tags: ['CocoaPods', 'iOS', 'Binary', 'Source Code']
categories: ['iOS', 'CocoaPods']
draft: false
draft: false
---

> 在开始之前，还是明确一下我们的目标，希望通过对 Cocoapods-binary 的改造使其支持 server 端缓存，从而达到 一处编译，处处使用 的 pods lib dependencies。同时会简单对比一下现有已经公开的大厂的实践和利弊，以及我们为何这么做。
## 业内实践
对于人数较多的业务团队，为了更好的团队协作组件化是不可避免的，关于如何逐步的组件拆分以及提升编译美团有一篇不错的入门 美团外卖iOS多端复用的推动、支撑与思考 里面提到了项目的二进制化，但是并没有涉及如何实现的，更多是关于如何分步进行组件化迭代。那么如何开始，又有哪些巨人的肩膀可以踩呢？
### [知乎 iOS 基于 CocoaPods 实现的二进制化方案](https://medium.com/r/?url=https%3A%2F%2Fzhuanlan.zhihu.com%2Fp%2F44280283)
知乎的实践是基于项目工程在提交 PR 后触发 binary package 的 CI 脚本，相对完整描述了如何进行源码和 binary 的切换和控制，生成的 binary package 如何在 server 端存储，还附了基本的流程图。总结一下要点：
- 通过 YML 配置 binary 白名单、文件服务配置信息等；
- 利用libo将xcodebuild后的 dSYM 和 binary 整合（包含了模拟器和真机设备）后的 ZIP 包上传至静态服务器，得到对应的 URL；
- 利用 CocoaPods Analysis 修改 podSpec 将 binary 为true的库的 source 指向获取到的 URL，同时更新 Tag。将修改后的 spec 文件推送至私有仓库；

#### 分析
1. 通过 YML 配置来控制源码和 binary 切换是不错的方式，不过如果能基于cocoapod-plugin 插件给 pod DSL 添加 binary 的属性来控制就更好了。
2. 对于修改 podspec 以及更新 Private Pod Repo 感觉是有一点冗余的。其实可以在 install 过程中检查 binary 为 true 的 pod 是否已有打好的 ZIP 包，存在则替换，否则进入 prebuild 流程打包即可。当然这里需要约定好生成的 ZIP 包名，知乎是以 tag + zhihu-static，如/path/to/server/AFNetworking-3.20-zhihu-static。本质上不论使用哪种方式引用 Pod，背后对应的都是 spec 文件里配置的 source 所指向仓库中对应的一个Git 节点（PS：每个 commit 对应的 hash，所以管理好版本很重要）。CocoaPods 在解决冲突依赖时，是依据语义化版本来递归，所以我认为是不需要单独对应的 static spec。

### [火掌柜 iOS 端基于 CocoaPods 的组件二进制化实践](https://medium.com/r/?url=https%3A%2F%2Fwww.infoq.cn%2Farticle%2FhIUoAJjKNS3_TVdaf0EG)
同样采用双私有源策略，一个静态服务器保存预先打好包的 binary，一个是源码服务地址。区别于知乎的方案的地方是，他们事先将各个私有库更新时，触发 CI 打包并上传服务器，在 pod install 过程中进行替换源。知乎是在完整项目的构建中完成对 binary 的打包和替换，知乎这样的一揽子方案才是正解。不过该文章提到不少在实践中的坑，有比较多的参考意义，他们还产出了一个 Pod 插件 CocoaPods-bin。总结一下该文章要点：
- 改造 CocoaPods-Package ，支持对单个 pod 进行二进制编译，打包上传静态服务器;
- 基于 Podfile 中添加的全局变量 tdfire_use_source_pods 来控制 binary 白名单，pod install 时注入环境变量以控制源码切换；

#### 分析
1. CocoaPods-Package 作为官方提供的插件在 1.7.0 正式版发布后做了一次更新，也是时隔多年，支持了Swift 的 package 及修复了一些问题。以单个 pod 进行二进制编译的最大麻烦在于，团队如果进行了比较重度的组件化，一般会有大量依赖库需要维护，如果每个库都需要配置一份 package 脚本成本比较高，同时第三方库也需要进行镜像维护，尽管支持了 CI 自动化也需要花费一部分精力，同时业务工程师也需要对项目有完整的认知，否则难以捋清其中的关系。
2. 以 IS_SOURCE环境变量控制 binary 和源码切换的方式也不是很友好。也是可以给 pod DSL 添加扩展来支持 binary switch。当前在每次 install 前加入变量去控制，使用上感觉有些奇怪；

## 改造 CocoaPods-Binary
关于 Cocoapods-Binary 前段时间写过一篇简单介绍，[浅析 Cocoapods-Binary 实现](https://juejin.im/post/5dfdfcc76fb9a0165835acc6)。在了解了该插件如何工作之后，就可以将我们端想法付诸实践了。
首先，我们要做的事情很多插件都已经帮我们完成了，而我们要做的就是简单的支持一下对 binary framework 的静态服务器存储和下发就好，先来一张流程图：

![](https://user-gold-cdn.xitu.io/2020/1/6/16f769e9c045137f?w=3891&h=2218&f=png&s=589877)

- 上图中的 featch remote framework 和 upload zips to server 就是我们要做的事情。
在 Prebuild framework 之前检查当前 pod_target 是否有对应的 server cache，存在则 download 至本地同时 unarchive 至 GenerateFramework 文件目录下，然后跳过当前 pod_target 的编译。

[exist_remote_framewo = sandbox.fetch_remote_framework_for_target(target)](https://gist.github.com/looseyi/97820689ff80aa58c9791ece45d22a96)

```ruby
def fetch_remote_framework_for_target(target)
    existed_remote_framework = self.remote_framework_names.include?(zip_framework_name(target))

    return false unless existed_remote_framework

    begin
        zip_framework_path = self.ftp.get(remote_framework_dir + zip_framework_name(target))
    rescue
        Pod::UI.puts "Retry fetch remote fameworks"
        self.reset_ftp
        zip_framework_path = self.ftp.get(remote_framework_dir + zip_framework_name(target))
    end

    return false unless File.exist?(zip_framework_path)

    target_framework_path = generate_framework_path + target.name
    return true unless Dir.empty?(target_framework_path)

    extract_framework_path = generate_framework_path + target.name
    zf = Zipper.new(zip_framework_path, extract_framework_path)
    zf.extract()
    true
end
```

在 Prebuild 结束后会进行文件清理和 binary 的替换链接，在此时进行批量 binary 文件的同步。将GenerateFramework 目录中所匹配的 pod_target 且资源服务器所不存在的 binary 文件进行上传，统一至 static_frameworks 目录下，文件名则是 pod_name + tag, 例如 pod 'AFNetworking', '3.0'对应的 zip framework 名字为 AFNeworkings-3.0.0.zip 。
[sync_prebuild_framework_to_server(target)](https://gist.github.com/looseyi/f5674ad527c1a7e6d5cf896cfb4f0237)

```ruby
def sync_prebuild_framework_to_server(target)
    zip_framework = zip_framework_name(target)
    target_framework_path = framework_folder_path_for_target_name(target.name)
    zip_framework_path = framework_folder_path_for_target_name(zip_framework)

    # ftp server 已有相同 Tag 的包
    return if self.remote_framework_names.include? zip_framework
    # 本地 archive 失败
    return if !File.exist?(target_framework_path) || Dir.empty?(target_framework_path)

    begin
        Zipper.new(target_framework_path, zip_framework_path).write unless File.exist?(zip_framework_path)
        self.ftp.put(zip_framework_path, remote_framework_dir)
        remote_zip_framework_path = self.ftp.local_file(remote_framework_dir + zip_framework)
        FileUtils.mv zip_framework_path, remote_zip_framework_path, :force => true    
    rescue
        Pod::UI.puts "ReTry To Sync Once"
        self.reset_ftp
        sync_prebuild_framework_to_server(target)
    end
end
```

实践过程中，为了方便直接是利用了公司现有的 ftp 文件服务器，单独开了一个进行目录维护。相比 CocoaPods-binary 仅增加了 ftp_tools.rb 和 zip_tools.rb 两个文件，实现比较简单这里就不贴出来了。
## 限制
- 最终的 binary size 会比使用源码的时候大一点，不建议最终上传 Store 的时候使用；
- 缺少一个验证的机制，如果已发布的二进制包不能被项目正常引用，那么会导致所有人的编译失败；；
- 由于工程采用的是全部静态库依赖的形式，所以在二进制和源码切换的过程中会对 project 文件产生更改；
- CocoaPods 在 1.7 以上版本，更改了framework 逻辑，不会把 resource copy 至 framework，因此我们需要将 CocoaPods 版本固定到 1.6.x；
- 对于动态配置生成的 framework，例如RN 相关的依赖等，不支持binary；
- 不同版本 Swift 编译出的 binary 是不能兼容。如果项目中引用了 Swift 库Xcode 版本需要统一。

在使用 binary 的过程中，还有一些意想不到的问题。例如，为了减少源码和 binary 切换过程中产生的大量 git change，将 Pods 目录进行了 ignore，导致工程师在过渡阶段切换分支中，多数被限制在 pod install 中一些三方库的 download 上面，非翻所不能也。还有，在 install 后发现 pod 对应的 symbol link 没有正确生成、对应的 source 没有 copy 成功、业务 framework 打包耗时超常等一系列问题。
## 总结
真实项目实践中，没有一劳永逸的办法。不同的业务依赖和环境配置，包括工程代码的规范，甚至简单的头文件管理都会导致开发过程产生各种各样的问题。总之，是一个不断探索和进化的过程。