---
title: "浅析 Cocoapods-Packager 实现"
date: 2020-03-29T15:10:58+08:00
tags: ['CocoaPods', 'iOS', 'Packager', 'Source Code']
categories: ['iOS', 'CocoaPods']
author: "土土Edmond木"
draft: false

---



## 介绍

> CocoaPods plugin which allows you to generate a framework or static library from a podspec.
>
> This plugin is for CocoaPods *developers*, who need to distribute their Pods not only via CocoaPods, but also as frameworks or static libraries for people who do not use Pods.

作为 CococaPods 的官方插件之一，CocoaPods Packager 为 Pod 提供了 **package** 命令来生成 framework or static library。你可以仅凭一个 podspec 文件就能完成一个 framework 或 library 的生成。

那 Packager 的使用场景有哪些？网上有特别多详细的使用说明文档，而分析实现的比较少。这也是这篇文章的初衷，想知道它是如何 work 的。本身插件也不是很复杂，这里会更挖一些细节。之前简单写了一篇文章：[浅析 Cocoapods-Binary 实现](https://juejin.im/post/5dfdfcc76fb9a0165835acc6)，主要是这两个插件的核心逻辑类似，感兴趣的可以拿来对比。它们的区别在于 package 的对象是针对单个 pod 还是整个 project 的。



## CocoaPods Plugins

这次我们先简单谈一谈 CococaPods 的插件原理。作为一款社区产品，仅有的少数核心开发者是无法满足大量开发者的各种需求。因此，在 [2013 CcocoaPods 开始支持 Plugins](https://blog.cocoapods.org/CocoaPods-0.28/) 扩展，使得大家可以自行支持所需要的功能。

### What can CocoaPods Plugins do?

- 可以 Hook pod install 过程，包括 pre_install 与 post_install；
- 可以添加新的 pod 命令；
- Ruby 作为 dynamic language，你完全可以随心所欲；



### RubyGems

开始解释源码钱，需要说一说包管理，不得不提 RubyGems 和 Bundler。CocoaPods 背后的原型就是基于它们俩，当然也会参照其他语言的包管理工具如 npm、Gradle。

[**Gems**](https://rubygems.org/)

> RubyGems is a hosted ruby library service. It centralizes where you look for a library, and installing ruby libraries / apps.



[**Bundler**](https://bundler.io/)

> Bundler provides a consistent environment for Ruby projects by tracking and installing the exact gems and versions that are needed.
>
> Bundler is an exit from dependency hell, and ensures that the gems you need are present in development, staging, and production. Starting work on a project is as simple as bundle install.

RubyGems 是为 ruby library 提供集中代码托管的服务。Bundler 则是针对当前项目来管理 Gem 版本的工具，

Bundler 依据项目中的 [Gemfiles](https://bundler.io/v2.0/gemfile.html) 文件来管理 Gem，就好比 CocoaPods 通过 Podfile 来管理 Pod 的版本一样。Gemfile 长这样：

```ruby
source 'https://gems.example.com' do
  gem 'cocoapods', '1.8.4'
  gem 'another_gem', :git => 'https://looseyi.github.io.git', :branch => 'master'
end
```

很熟悉的感觉，有木有。是的，Podfile 的 DSL 和 Gemfile 如出一辙。

那什么情况会用到 Gemfile 呢？比如，公司级项目中可以通过 gemfile 来统一 CocoaPods 的版本，不然大家各自为政会导致提交代码会因为 CocoaPods 版本不同导致对项目的配置产生各种差异，导致最终的 PR 有大量 conflict 或 change，当然还可以管理 CocoaPods 的插件版本，可以指向你自己的定制版本。

Bundle 的使用也很简单，在 `gem install bundler` 后，通过添加 `bundle exec` 前缀来执行 pod 命令。这时会读取安装在本地 .bundle/ 目录或全局目录下所指定的 Gem 包来执行 pod 命令。

```ruby
bundle install #安装 gemfile 中的包
bundle exec pod install 
```



**[Gem](https://guides.rubygems.org/what-is-a-gem/)**

> The software package is called a “gem” which contains a packaged Ruby application or library.

Gem 则是包含 Ruby 代码的 application 或者 library，而它就是我们今天的主角，CocoaPods Plugin 背后的支柱。应该说 CocoaPods Plugin 本质上就是 Gem。

那我们来看一眼 Gem 的文件结构：

```powershell
tree CocoaPods -L 2
CocoaPods
├── Rakefile
├── cocoapods.gemspec
├── bin
│   ├── pod
│   └── sandbox-pod
├── lib
│   ├── cocoapods
│   ├── ...
└── spec
│   ├── cocoapods-integration-specs
│   ...
```

- bin：可执行文件目录，当 gem install 的时候，会被加载到用户的 **PATH** 路径下；
- lib：gem 的源代码目录；
- sepc：gem 的测试代码目录；
- Rakefile：是自动化测试程序 [rake](https://rubygems.org/gems/rake) 的配置文件，也可用于生成代码或者其他任务；
- gemspec：描述了 gem 的关键信息，下面会提到；



[**GemSpec**](https://guides.rubygems.org/specification-reference/)

> The gemspec specifies the information about a gem such as its name, version, description, authors and homepage.

既然 CocoaPods 也是 Gem，它的 GemSpec 包含哪些信息呢：

```ruby
Gem::Specification.new do |s|
  s.name     = "cocoapods"
  s.version  = Pod::VERSION
  s.files = Dir["lib/**/*.rb"] + %w{ bin/pod bin/sandbox-pod README.md LICENSE CHANGELOG.md }
  s.executables   = %w{ pod sandbox-pod }
  s.require_paths = %w{ lib }
  s.add_runtime_dependency 'cocoapods-core',        "= #{Pod::VERSION}"
  s.add_runtime_dependency 'claide',                '>= 1.0.2', '< 2.0'
  s.add_runtime_dependency 'xcodeproj',             '>= 1.14.0', '< 2.0'
  ...
end
```

依据那么熟悉的感觉，如果你有搞过 Pod library 的话。PodSpec 类比 Gemspec，就不多介绍了。



### CocoaPods Plugins

了解完 Gem，再看 Plugins 会清晰很多。作为 CocoaPods 的 Plugin，CocoaPods 为我们提供了方便生成 plugin 模版的命令。

```powershell
pod plugins create NAME [TEMPLATE_URL]
```

生成 plugin 模版的文件目录与 gem 相差无几，这里直接贴 cocoapods-packager 的文件目录：

```powershell
cocoapods-packager
├── Gemfile
├── Rakefile
├── cocoapods-packager.gemspec
├── lib
│   ├── cocoapods-packager
│   ├── cocoapods_packager.rb
│   ├── cocoapods_plugin.rb
│   └── pod
└── spec
    ├── command
    ├── fixtures
    ├── integration
    ├── spec_helper.rb
    └── unit
...
```

确实没啥特别的，只不过会在 gemfile 中，帮你指定好 cocoapods 的依赖，以及根据提供的 NAME 来生成通用文件。



### CocoaPods Packager

接下来我们提到的文件都是在 lib 文件夹下，即 Packager 的源代码所在地。开始前照例看一下脑图，有一个整体的认识：

![cocoapods-packager](http://ww1.sinaimg.cn/large/8157560cly1gdbb24p0iuj22ma1jw19j.jpg)

这里基本对应了 Packager 的主要文件，作者已经分的比较清楚了，整个 Package 的入口是 `/lib/pod/command/package.rb` 文件，对应脑图的 Command Run 分类。各个分类下面对应的就是各个文件内部提供的主要方法，接下来我们就从 Package 文件说起。



##Package

本文 Demo 所展示的是基于 Packager 内部提供的测试 spec 来做示例，启动命令如下：

```shell
bundle exec pod package ${workspaceRoot}/cocoapods-packager/spec/fixtures/KFData.podspec --dynamic
```

> *PS：调试所用的工具是 VSCode，如果你没有用过，绝对不要错过了。*

执行上面代码前，我们需要先在 `package.rb` 的 `initialize` 方法内打个断点。然后我们来看 Package 类：

```ruby
module Pod
    class Command
      class Package < Command
         # functions ...
    end
end
```

Package Command 继承自 CocoaPods 内部所提供的命令工具模块 [CLAide](https://github.com/CocoaPods/CLAide)::Command。所有扩展 Pod 的命令都需要继承它，同时需要重载它的 `options`、`validate`、`initialize` 和 `run` 四个方法。



### options

> A list of option name and description tuples.

执行命令所需的可选参数，是 [Array<Array\>] 的元组，由参数和对应的描述组成，选项如下：

```ruby
def self.options
    [
        ['--force',     'Overwrite existing files.'],
        ['--no-mangle', 'Do not mangle symbols of depedendant Pods.'],
        ['--embedded',  'Generate embedded frameworks.'],
        ['--library',   'Generate static libraries.'],
        ['--dynamic',   'Generate dynamic framework.'],
        ['--local',     'Use local state rather than published versions.'],
        ['--bundle-identifier', 'Bundle identifier for dynamic framework'],
        ['--exclude-deps', 'Exclude symbols from dependencies.'],
        ['--configuration', 'Build the specified configuration (e.g. Debug). Defaults to Release'],
        ['--subspecs', 'Only include the given subspecs'],
        ['--spec-sources=private,https://github.com/CocoaPods/Specs.git', 'The sources to pull dependent ' \
            'pods from (defaults to https://github.com/CocoaPods/Specs.git)']
    ]
end
```



### validate

校验所传参数有效性，如果参数中带有 `--help` 选项，则会直接抛出帮助提示。它会在 run 方法执行前被调用。重载前需要先调用 `super`，代码如下：

```ruby
def validate!
    super
    help! 'A podspec name or path is required.' unless @spec
    help! 'podspec has binary-only depedencies, mangling not possible.' if @mangle && binary_only?(@spec)
    help! '--bundle-identifier option can only be used for dynamic frameworks' if @bundle_identifier && !@dynamic
    ...
end
```



### initialize

解析参数，然后初始化打包所需的变量。这里着重介绍几个核心参数：

- @config：xcodebuild configuration，值为 *Debug*、*Release*，当然也可以自定义，默认为 *Release*；
- @package_type：所生成的包类型，可以是静态库或者动态库，默认为 static_framework;
- @subspecs：支持所打出的包仅包含部分的 subspec，如果对 subspes 有兴趣，请转[官方文档](https://guides.cocoapods.org/syntax/podspec.html#group_subspecs)；
- @exclude_deps：打包的时候踢除 dependencies 的符号表，配合 `--no-mangle` 一起使用，解决静态库打包时有其他静态库依赖的问题；
- @mangle：是否开自动修改类名等符号，默认开启。

这里稍微展开一下 **@package_type** ，它其实是由多个参数来决定的，`--embeded`、`--dynamic`、`--library`：

```ruby
if @embedded
    :static_framework
elsif @dynamic
    :dynamic_framework
elsif @library
    :static_library
else
    :static_framework
end
```

可能有部分同学对于 framework 和 libray 的概念比较模糊，这里再说一句，详细可以看 [Apple Doc](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/WhatAreFrameworks.html):

> A *framework* is a hierarchical directory that encapsulates shared resources, such as a dynamic shared library, nib files, image files, localized strings, header files, and reference documentation in a single package. 

简单来说 framework 就一文件夹，你要说和 Bundle 一样也无妨。它是静态库还是动态库，重点看它所包含的 library 类型。如果包含的是 static share library 那就是 static_framework。如果包含的是 dynamic share library 则是 dynamic_framework。而我们平时说的 `libxxx.a` 则是静态库。



### run

```ruby
 if @spec.nil?
     help! "Unable to find a podspec with path or name `#{@name}`."
     return
 end

 target_dir, work_dir = create_working_directory
 return if target_dir.nil?
 build_package

 `mv "#{work_dir}" "#{target_dir}"`
 Dir.chdir(@source_dir)
```

`run` 方法作为入口比较简单，首先就是检查是否取到所要编译的 podspec 文件。然后针对它创建对应的 `working_directory` 和 `target_directory`。

working_directory 为打包所在的临时目录，like this：

```shell
/var/folders/zn/1p8f0yls66b5788lshsjrd6c0000gn/T/cocoapods-rp699asa
```

target_directory 为最终生成 package 的所在目录，是当前 source code 目录下新开的：

```shell
${workspaceRoot}/KFData-1.0.5
```

在 `create_working_directory` 后，会主动切换当前 ruby 的运行目录至 `working_directory` 目录下，正式开始编译。`build_package` 结束后，将编译产物 copy 到 `target_directory` 下，同时切换回最初执行命令所在目录 `@source_dir` 。



### build_package

```ruby
builder = SpecBuilder.new(@spec, @source, @embedded, @dynamic)
newspec = builder.spec_metadata

@spec.available_platforms.each do |platform|
    build_in_sandbox(platform)

    newspec += builder.spec_platform(platform)
end

newspec += builder.spec_close
File.open(@spec.name + '.podspec', 'w') { |file| file.write(newspec) }
```

首先，创建一个 [SpecBuilder](https://github.com/CocoaPods/cocoapods-packager/blob/461686593c521796c723fe5f1c460e2aa2adbe55/lib/cocoapods-packager/spec_builder.rb)，其作用是用于生成描述最终产物的 podspec 文件，SpecBuilder 就是一个模版文件生成器。bundler 调用 `spec_metadata` 方法遍历指定的 `podspec` 文件复刻出对应的配置并返回新生成的 `podspec` 文件。

然后，根据 target 所支持的 platform，iOS / Mac / Watch 依次执行 `build_in_sandbox` 编译，同时将 platform 信息写入 newspec，以 iOS 为例：

```ruby
s.ios.deployment_target    = '8.0'
s.ios.vendored_framework   = 'ios/A.embeddedframework/A.framework'
```

最后，将 `podspec`  写入 `target_directory` 编译结束。



### build_in_sandbox

```ruby
config.installation_root  = Pathname.new(Dir.pwd)
config.sandbox_root       = 'Pods'

static_sandbox = build_static_sandbox(@dynamic)
static_installer = install_pod(platform.name, static_sandbox)

if @dynamic
    dynamic_sandbox = build_dynamic_sandbox(static_sandbox, static_installer)
    install_dynamic_pod(dynamic_sandbox, static_sandbox, static_installer, platform)
end

begin
    perform_build(platform, static_sandbox, dynamic_sandbox, static_installer)
ensure # in case the build fails; see Builder#xcodebuild.
    Pathname.new(config.sandbox_root).rmtree
    FileUtils.rm_f('Podfile.lock')
end
```

**Config**

首先， config 与 **initialize** 的属性 @config 完全是两个东西，@config 只是一个 'Debug' or 'Release' 的字符串，而这里的 config 是  `Pod::Config` 的实例，默认读取自 `~/.cocoapods/config.yaml` 目录下的配置。

Package 在这里指定了 config 的安装目录 `working_dirctory` 和沙盒目录 `./Pods`。[**Config**](https://github.com/CocoaPods/CocoaPods/blob/master/lib/cocoapods/config.rb) 类是保存在 `/path/to/cocoapods/lib/cocoapods/config.rb` 中。它非常重要，包括我们 CocoaPods 平时的 install 过程以及这个 Package 的 build 过程均是读取的全局的 config。作为全局需要访问的对象，一定是个 share instance 咯。在 CocoaPods 中是这么实现的；

```ruby
def self.instance
    @instance ||= new
end

module Mixin
    def config
      Config.instance
    end
end
```

各个模块通过 include 来引入，比如 Command 类中：

```ruby
include Config::Mixin
```

然后就能愉快的使用了。

有了 config 之后，就可以创建沙盒来执行 pod install。install 过程会针对 static 和 dynamic 分别 install 一次。最后，基于安装后的工程，创建 builder 开始最终的构建操作。沙盒创建和 install 是在 `pod_utils.rb` ，build 在 `builder.rb` 中，接下来会单独展开。



##Pod Utils

整个 pods_utils 文件均声明为 Package 的 private 方法，主要做的是 build sandbox 和 pod install。install 会区分 static 和 dynamic。按照 `build_in_sandbox` 调用顺序展开聊聊。

### build_static_sandbox

通过 Pathname 先生成 `static_sandbox_root` ，然后返回 `Sandbox.new(static_sandbox_root)`。static_sandbox_root 会根据参数 dynamic 来判断，是否需要创建二级目录 `/static`：

```ruby
if dynamic
    Pathname.new(config.sandbox_root + '/Static')
else
    Pathname.new(config.sandbox_root)
end
```

这么区分是由于，如果为动态库，还会生成一个 dynamic sandbox，其 path 为：

```ruby
dynamic_sandbox_root = Pathname.new(config.sandbox_root + '/Dynamic')
```

介绍一下 [SandBox](https://github.com/CocoaPods/CocoaPods/blob/master/lib/cocoapods/sandbox.rb) ，其定义如下：

> The sandbox provides support for the directory that CocoaPods uses for an installation. In this directory the Pods projects, the support files and the sources of the Pods are stored.

所以，sandbox 就是用于管理 pod install 目录。



### install_pod

既然是 pod install 当然需要来一个 podfile 了。package 会根据指定的 spec 来手动创建 podfile。

```ruby
def podfile_from_spec(path, spec_name, platform_name, deployment_target, subspecs, sources)
  options = {}
  if path
    if @local
        options[:path] = path
    else
        options[:podspec] = path
    end
  end
  options[:subspecs] = subspecs if subspecs
  Pod::Podfile.new do
    sources.each { |s| source s }
    platform(platform_name, deployment_target)
    pod(spec_name, options)

    install!('cocoapods', integrate_targets: false, deterministic_uuids: false)
    target('packager') do 
        inherit! :complete 
    end
  end
end
```

我们知道 Podfile 作为 DSL 文件，其每一行配置背后都对应具体的方法，上面的这个就是简化版的 podfile 对应的命令，options 就是我们配置的 `pod` 方法所需的参数，对应的是：`pod(spec_name, options)`。反转过来对对应的 podfile DSL 应该是这样的：

```ruby
platform :ios, '8.0'
target 'packager' do
    pod "#{spec_name}", :path => "#{path}"# or :podspec => "#{path}"
end
```

这里如果参数中指定了 path 则不会通过 spec 指定的  `source` 去download 源码下来。

接着就是 pod install 了：

```ruby
# podfile = podfile_from_spec  
...
static_installer = Installer.new(sandbox, podfile)
static_installer.install!

unless static_installer.nil?
    static_installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
        config.build_settings['CLANG_MODULES_AUTOLINK'] = 'NO'
        config.build_settings['GCC_GENERATE_DEBUGGING_SYMBOLS'] = 'NO'
    end
    end
    static_installer.pods_project.save
end

static_installer
```

这里重点就是 build_settings 的两个配置。当 static_installer install 成功后会修改它们，作用是为了支持后续dynamic_framework 的编译。`GCC_GENERATE_DEBUGGING_SYMBOLS` 这个 config 应该都知道吧？

我们来看另一个 **CLANG_MODULES_AUTOLINK**，在 stackoverflow 上有一个[解释](https://stackoverflow.com/questions/42646716/how-is-a-blank-new-cocoa-app-project-linking-with-the-system-frameworks):

> When you create a new project, Xcode will set the `Link Frameworks Automatically` flag to YES. Then the clang linking flag will be set to `CLANG_MODULES_AUTOLINK = YES`. With this option, clang will linking the framework for you automatically.

就是为了避免 install 后，项目 autolink。



### install_dynamic_pod

`build_dynamic_sandbox` 前面已经说过了，我们直接看动态库的 install：

```ruby
# 1 Create a dynamic target for only the spec pod.
dynamic_target = build_dynamic_target(dynamic_sandbox, static_installer, platform)

# 2. Build a new xcodeproj in the dynamic_sandbox with only the spec pod as a target.
project = prepare_pods_project(dynamic_sandbox, dynamic_target.name, static_installer)

# 3. Copy the source directory for the dynamic framework from the static sandbox.
copy_dynamic_target(static_sandbox, dynamic_target, dynamic_sandbox)

# 4. Create the file references.
install_file_references(dynamic_sandbox, [dynamic_target], project)

# 5. Install the target.
install_library(dynamic_sandbox, dynamic_target, project)

# 6. Write the actual .xcodeproj to the dynamic sandbox.
write_pod_project(project, dynamic_sandbox)
```

内部分了 6 个方法，还附带了详细的注释。需要注意的是，整个 install_dynamic_pod 是基于 install_pod 所生成的 `static_installer` 来修改的。这里比较复杂，一步步来。



### build_dynamic_target

```ruby
# 1
spec_targets = static_installer.pod_targets.select do |target|
target.name == @spec.name
end
static_target = spec_targets[0]
# 2
file_accessors = create_file_accessors(static_target, dynamic_sandbox)
# 3
archs = []
dynamic_target = Pod::PodTarget.new(dynamic_sandbox, true, static_target.user_build_configurations, archs, platform, static_target.specs, static_target.target_definitions, file_accessors)
dynamic_target
```

1. 通过 select `static_installer.pod_targets ` 筛选出 static_target，所过滤掉的是 target 是 spec 的第三方依赖。这里是过滤了 `QueryKit`；

2. 针对每个 subspec 生成相应的 [FileAccessory](https://rubydoc.info/gems/cocoapods/Pod/Sandbox/FileAccessor) :

   ```ruby
   <Pod::Sandbox::FileAccessor spec=KFData platform=osx root=...>
   <Pod::Sandbox::FileAccessor spec=KFData/Attribute platform=osx root=...>
   <Pod::Sandbox::FileAccessor spec=KFData/Core platform=osx root=...>
   <Pod::Sandbox::FileAccessor spec=KFData/Essentials platform=osx root=...>
   <Pod::Sandbox::FileAccessor spec=KFData/Manager platform=osx root=...>
   <Pod::Sandbox::FileAccessor spec=KFData/Store platform=osx root=...>
   ```

3. 创建 PodTarget。



### prepare_pods_project

```ruby
# Create a new pods project
pods_project = Pod::Project.new(dynamic_sandbox.project_path)

# Update build configurations
installer.analysis_result.all_user_build_configurations.each do |name, type|
  pods_project.add_build_configuration(name, type)
end

# Add the pod group for only the dynamic framework
local = dynamic_sandbox.local?(spec_name)
path = dynamic_sandbox.pod_dir(spec_name)
was_absolute = dynamic_sandbox.local_path_was_absolute?(spec_name)
pods_project.add_pod_group(spec_name, path, local, was_absolute)
pods_project
```

创建 Pod::Project，然后将 static project 中的 user configuration 复制过来，最后为 target 新建 Pods Group，这里的 group 是 [PBXGroup](https://www.rubydoc.info/gems/cocoapods/0.38.0/Pod/Project)。什么是 PBXGroup 呢？看下面的分组就明白的了：

![pbxgroup](http://ww1.sinaimg.cn/large/8157560cly1gdi3kh8vf2j20ey084dr5.jpg)

我们平时说看到的 Dependencies、Frameworks、Pods、Products、Target Support Files 他们在 CocoaPods 中都是对应了 PBXGroup。



### copy_dynamic_target

从 static sandbox 中 cp 到 dynamic sandbox 目录下。



### install_file_references

```ruby
installer = Pod::Installer::Xcode::PodsProjectGenerator::FileReferencesInstaller.new(dynamic_sandbox, pod_targets, pods_project)
installer.install!
```

通过 [FileReferencesInstaller](https://www.rubydoc.info/gems/cocoapods/0.38.0/Pod/Installer/FileReferencesInstaller) 为 dynamic target 生成文件引用，为最后的 project 写入做准备。FileReferencesInstaller 说明：

> Controller class responsible of installing the file references of the specifications in the Pods project.



### install_library

将 dynamic_target 写入新建的 project，同时会 install 依赖的 system framework。



### write_pod_project

```ruby
dynamic_project.pods.remove_from_project if dynamic_project.pods.empty?
dynamic_project.development_pods.remove_from_project if dynamic_project.development_pods.empty?
dynamic_project.sort(:groups_position => :below)
dynamic_project.recreate_user_schemes(false)

# Edit search paths so that we can find our dependency headers
dynamic_project.targets.first.build_configuration_list.build_configurations.each do |config|
config.build_settings['HEADER_SEARCH_PATHS'] = "$(inherited) #{Dir.pwd}/Pods/Static/Headers/**"
config.build_settings['USER_HEADER_SEARCH_PATHS'] = "$(inherited) #{Dir.pwd}/Pods/Static/Headers/**"
config.build_settings['OTHER_LDFLAGS'] = '$(inherited) -ObjC'
end
dynamic_project.save
```

最后，将 project 写入 dynamic sandbox，修改 Search Path 保证能查询到依赖的 header 引用。



## Builder

继 project 创建和 pod install 后，Package 中的 `perform_build` 先将所需参数传入以创建 Builder，开始执行 `builder.build(@package_type)`。build 会依据 package_type 分为三种：

- build_static_library
- build_static_framework
- build_dynamic_framework

这三个方法区别其实不大，就是 framework 的方法多了资源 copy 的过程。这里以 build_dynamic_framework 为例。



### build_dynamic_framework

```ruby
defines = compile
build_sim_libraries(defines)

if @bundle_identifier
defines = "#{defines} PRODUCT_BUNDLE_IDENTIFIER='#{@bundle_identifier}'"
end

output = "#{@dynamic_sandbox_root}/build/#{@spec.name}.framework/#{@spec.name}"

clean_directory_for_dynamic_build
if @platform.name == :ios
build_dynamic_framework_for_ios(defines, output)
else
build_dynamic_framework_for_mac(defines, output)
end

copy_resources
```

首先是先执行 `compile` 构建 `Pods-packager` ，成功后返回 defines。**compile** 实现如下：

```ruby
defines = "GCC_PREPROCESSOR_DEFINITIONS='$(inherited) PodsDummy_Pods_#{@spec.name}=PodsDummy_PodPackage_#{@spec.name}'"
defines << ' ' << @spec.consumer(@platform).compiler_flags.join(' ')
if @platform.name == :ios
    options = ios_build_options
end
xcodebuild(defines, options)
if @mangle
    return build_with_mangling(options)
end
defines
```

如果没有指定 `--no-mangle` 则正常执行 xcodebuild，否则转入 `build_with_mangling`。

build_with_mangling 内部也是调用 xcodebuild，区别在于它生成的 defines 不同。mangling 会遍历 sandbox build 目录下的 libxxx.a 静态库来查找，核心方法如下：

```ruby
defines = Symbols.mangle_for_pod_dependencies(@spec.name, @static_sandbox_root)
```

[mangle.rb](https://github.com/CocoaPods/cocoapods-packager/blob/master/lib/cocoapods-packager/mangle.rb) 的描述如下：

> performs symbol aliasing，for each dependency:
>
> ​    \- determine symbols for classes and global constants
>
> ​    \- alias each symbol to Pod#{pod_name}_#{symbol}
>
> ​    \- put defines into `GCC_PREPROCESSOR_DEFINITIONS` for passing to Xcode

mangling 也称为 namespacing，会把类名和全局常量改成 `Pod#{pod_name}_#{symbol}` 的形式。以我们调试的 KFData 的 PodsDummy_KFData 类为例：

```ruyb
no-mangle: PodsDummy_KFData
mangling: PodKFData_PodsDummy_KFData
```

就是统一在类前面添加了前缀，目的是为了避免静态库中的符号表冲突。比如，我们打包的 KFData 依赖了 QueryKit 那生成的 libKFData.a 静态库会有一份 QueryKit 的 copy，而此时如果在主工程里也直接引用了 QueryKit 那就会产生类似 `duplicate symbols for architecture x86_64` 的错误。

你可以 `nm` 工具来查看 class 的 symbol：

```shell
nm -gU KFData.framework/KFData | grep "_OBJC_CLASS_\$.*KF.*"
```

在查这个问题时，还填补了一个疑惑很久的问题：[Why do cocoapod create a dummy class for every pod?](https://stackoverflow.com/questions/39160655/why-do-cocoapod-create-a-dummy-class-for-every-pod) CocoPods 上 [issue_3410](https://github.com/CocoaPods/CocoaPods/issues/3410) 也有详细讨论



**build_sim_libraries**

由于 simulator 自由 iOS 有，实现比较简单，参数是前面 compile 返回的 defines。

```ruby
if @platform.name == :ios
    xcodebuild(defines, '-sdk iphonesimulator', 'build-sim')
end
```



**build_dynamic_framework_for_ios**

```ruby
# Specify frameworks to link and search paths
linker_flags = static_linker_flags_in_sandbox
defines = "#{defines} OTHER_LDFLAGS='$(inherited) #{linker_flags.join(' ')}'"

# Build Target Dynamic Framework for both device and Simulator
device_defines = "#{defines} LIBRARY_SEARCH_PATHS=\"#{Dir.pwd}/#{@static_sandbox_root}/build\""
device_options = ios_build_options << ' -sdk iphoneos'
xcodebuild(device_defines, device_options, 'build', @spec.name.to_s, @dynamic_sandbox_root.to_s)

sim_defines = "#{defines} LIBRARY_SEARCH_PATHS=\"#{Dir.pwd}/#{@static_sandbox_root}/build-sim\" ONLY_ACTIVE_ARCH=NO"
xcodebuild(sim_defines, '-sdk iphonesimulator', 'build-sim', @spec.name.to_s, @dynamic_sandbox_root.to_s)

# Combine architectures
`lipo #{@dynamic_sandbox_root}/build/#{@spec.name}.framework/#{@spec.name} #{@dynamic_sandbox_root}/build-sim/#{@spec.name}.framework/#{@spec.name} -create -output #{output}`

FileUtils.mkdir(@platform.name.to_s)
`mv #{@dynamic_sandbox_root}/build/#{@spec.name}.framework #{@platform.name}`
`mv #{@dynamic_sandbox_root}/build/#{@spec.name}.framework.dSYM #{@platform.name}`
```

上面贴的代码看去很多，更多的是参数拼接的工作，主要做了三件事：

- xcodebuild 模拟器支持的 framework;
- xcodebuild 真机支持的 framework;
- lipo 合并👆生成的 framework 输出到 `#{working_directory}/ios` ;

build_dynamic_framework_for_mac 省去 simulator build 这一步，也就没有 lipo 操作，更简单。这里就不列出了。

最后就是 resource、header、license 等相关资源的 copy。至此大致流程就结束了，用简单流程来回顾一下：

![cocoapods-packager](http://ww1.sinaimg.cn/large/8157560cly1gdj2fkwc7oj22bu1gs7f7.jpg)



### 总结

cocoapods-packager 的逻辑还是比较简单的，整个熟悉过程困难还是在于对 CocoaPods 的 API 和作用并不是和了解，导致很多调用需要查资料或者看 CocoaPods 源码才能了大致理解。内部实现还是围绕 xcodebuild 来展开的，通过生成 podfile 及 pod install 来构建 project 环境，算是对 CocoaPods 的深度集成了。





