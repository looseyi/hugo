---
title: "UserDefaults By Swift Property Wrapper"
date: 2019-10-29T01:37:56+08:00
lastmod: 2019-10-29T01:37:56+08:00
draft: true
tags: ['Swift', 'iOS', 'CS']
categories: ['iOS', 'CS']
author: "土土Edmond木"

---

## 背景

> 对于 iOS 开发来说，NSUserDefaults 应该是再熟悉不过的一个轻量的缓存工具。它提供了 Objc 中最基本的数据存储功能，支持 CS 和 Objc 的基本的数据类型。
> 使用也是非常简单的，只需将每个 `property key` 和相应的存储类型绑定就完事了。但是这里面存在两个小问题：
>
> 1. 使用者在调用过程中，需要同时知道 `key` 和相关的数据类型，导致工程中 `key` 漫天飞，而我们关心的其实是其关联的数据；
> 2. 存储数据后都需要调用 `synchronize()` 进行同步有时候容易忽略掉；

## 常规实现

上述问题，通常的解决方案是在项目中维护一个单独类进行管理📦，主要是 imp 中对 property 封装的胶水代码比较🤢。

```Objective-C

@interface UserDefault : NSObject <NSCoding>
@property (nonatomic, copy) NSString *pass;
@end

@implementation UserDefault
- (NSString *)pass {
  return NSUserDefaults standardUserDefaults] stringForKey:@"Pass"];
}
- (void)setPass:(NSString *)pass
{
  NSUserDefaults standardUserDefaults] setString:pass.copy forKey:@"Pass"];
}
@end

```

swift 中代码如下：

```Swift

class UserDefault {
    static var pass: String? {
        set { UserDefaults.stander.set(newValue forKey: "Pass") }
        get { UserDefaults.stander.string(forKey: "Pass") } /// swift 5 语法 OpaqueTypes, return 可不写
    }
    ...
}

```

但是这么做带来了另外的问题，维护的全局类会越来越臃肿。很多无关的属性杂糅到一处，并不是很友好；
本文中介绍的 `SwiftUserDefault` 就试图解决这个问题。我们希望达到到效果就是在你声明静态变量到时候就顺带讲 `UserDefault` 到 accessor 给搞定了，这样可以方便到将变量声明至你真正需要到地方。
Swift 5.1 带来的[PropertyWrapper](https://forums.swift.org/t/pitch-3-property-wrappers-formerly-known-as-property-delegates/24961)。基本使用本文不做太多介绍，可以参考 [属性代理](https://juejin.im/post/5cfcf51151882518e845c17c)。

如果用 PropertyWrapper 包装过的 `UserDefaults` 长什么样子:

```
@propertyDelegate
struct UserDefault<T> {
  let key: String
  let defaultValue: T
  var value: T {
    get { return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}

enum GlobalSettings {
  @UserDefault(key: "FOO_FEATURE_ENABLED", defaultValue: false)
  static var isFooFeatureEnabled: Bool
}
```





Now, support Swift 5.1, and you can use by  

**SwiftUserDefault**, which is just wrap NSUserDefaults, make you easy to use.



```swift
struct TestUserDefault {
  @UserDefaultsItem("objectTest") static var objectTest: AnyObject
  @UserDefaultsItem("stringTest") static var stringTest: String
  @UserDefaultsItem("boolTest") static var boolTest: Bool
  @UserDefaultsItem("intTest") static var intTest: Int
  @UserDefaultsItem("floatTest") static var floatTest: Float
  @UserDefaultsItem("doubleTest") static var doubleTest: Double
  @UserDefaultsItem("dataTest") static var dataTest: Data
  @UserDefaultsItem("dateTest") static var dateTest: Date
  @UserDefaultsItem("[Bool]") static var boolArrayTest: [Bool]
  @UserDefaultsItem("[Int]") static var intArrayTest: [Int]
  @UserDefaultsItem("[String]") static var stringArrayTest: [String]
  @UserDefaultsItem("[Data]") static var dataArrayTest: [Data]
  @UserDefaultsItem("<String : Int>") static var dictIntTest: [String : Int]
  @UserDefaultsItem("<String : String>") static var dictStringTest: [String : String]
  @UserDefaultsItem("<String : Date>") static var dictDateTest: [String : Date]
  @UserDefaultsItem("<String : Bool>") static var dictBoolTest: [String : Bool]
}
```

In your project, use can declear your store type, like above, *UserDefaultsItem* would synchronize it once you set newValue, if newValue is nil, the key's value would be remove from *NSUserDefaults*.

>  set value
>
>  ```
>  TestUserDefault.stringTest = "I'am test"
>  ```
>
>  get value
>
>  ```
>  let value = TestUserDefault.stringTest // will be  optional value "I'am test"
>  ```



#### Install

By CocoaPods use:

> pod SwiftUserDefault