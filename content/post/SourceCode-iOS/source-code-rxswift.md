---
title: "源码浅析 RxSwift 5.0 - Subscription"
date: 2020-03-16T23:10:58+08:00
tags: ['SourceCode', 'iOS', 'Reactive']
author: "土土Edmond木"
---



### 前言

ReactiveX 它是一个与语言无关的编程思想。作为成员框架之一 RxSwift 落地了大部分 ReactiveX 中关于流的操作。官方描述：

> An API for asynchronous programming with observable streams
>
> ReactiveX is a combination of the best ideas from the Observer pattern, the Iterator pattern, and functional programming

本篇主要介绍 RxSwift 的内部流是如何产生和订阅，这里默认大家是有 RxSwift 使用经验的。关于响应式编程在移动端已经是一个相对成熟的概念了，有很多好文章，比如 [FRP](https://halfrost.com/tag/rac/) 系列。如果你在项目中犹豫使用哪个框架可以看看这两篇文章的分析：

-  [FRP对比—ReactiveCocoa、RxSwift、Bacon以及背后的Functional](https://dreampiggy.com/2016/11/17/FRP%E7%AE%80%E4%BB%8B%E2%80%94ReactiveCocoa%E3%80%81RxSwift%E3%80%81Bacon%E4%BB%A5%E5%8F%8A%E8%83%8C%E5%90%8E%E7%9A%84Functional/)
- [iOS响应式编程：ReactiveCocoa vs RxSwift 选谁好](https://www.jianshu.com/p/2f83b766a081)



## Observable

Rx 中的 Observable Stream(观察流)，为了方便这里简称为 **流**。流中的元数据可以有多个或者单个，这里统称为节点。既然一切皆流，那就从流的创建讲起，上代码：

```swift
Observable.of(1, 2, 3)
    .subscribe( { print($0) })
```

我们看第一行，它把 **Swift.Sequence<Int\>** 序列 *[1, 2, 3]* 转换为流，[of(_:)](https://github.com/ReactiveX/RxSwift/blob/c6c0c540109678b96639c25e9c0ebe4a6d7a69a9/RxSwift/Observables/Sequence.swift) 方法的声明如下：

```swift
extension ObservableType {
   
    public static func of(_ elements: Element ..., scheduler: ImmediateSchedulerType = CurrentThreadScheduler.instance) -> Observable<Element> {
        return ObservableSequence(elements: elements, scheduler: scheduler)
    }
}
```

利用 Swift 的 [Protcol Extesion](https://docs.swift.org/swift-book/LanguageGuide/Protocols.html#) 来为 ObservableType 添加默认了实现，它把 Sequence<Int\> 存入了 ObservableSequence 中并返回。

大概了解一下 ObservableSequence 的类关系：

```swift
| --- ObservableSequence
    | --- Producer 
        | --- Observable (class)
            | --- ObservableType (Protocol)
                | --- ObservableConvertibleType (Protocol)
```

根协议 ObservableConvertibleType 利用关联类型声明了返回值为关联类型的泛型方法 `asObservable`:

```swift
public protocol ObservableConvertibleType {
    /// Type of elements in sequence.
    associatedtype Element
    func asObservable() -> Observable<Element>
}
```

协议 ObservableType 则声明了 `subscribe(_:)` 方法：

```swift
public protocol ObservableType: ObservableConvertibleType {
   
    func subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element
}

extension ObservableType {
    /// Default implementation of converting `ObservableType` to `Observable`.
    public func asObservable() -> Observable<Element> {
        // temporary workaround
        //return Observable.create(subscribe: self.subscribe)
        return Observable.create { o in
            return self.subscribe(o)
        }
    }
}
```

并利用 `subscribe(_:)` 方法完成了对 `asObservable()` 默认实现的扩展。

关于注释  temporary workaround，翻了一下 [git history](https://github.com/ReactiveX/RxSwift/blob/master/RxSwift/ObservableType.swift) 在 Swift 3.0 添加的。这种写法在 Swift 5.0 上是可以 work 的，不知为何注释了。那为什么可以这么写呢 ？稍微扯一下，可以看 [creat(_:)](https://github.com/ReactiveX/RxSwift/blob/master/RxSwift/Observables/Create.swift) 的声明：

```swift
extension ObservableType {
   
    public static func create(_ subscribe: @escaping (AnyObserver<Element>) -> Disposable) -> Observable<Element> {
        return AnonymousObservable(subscribe)
    }
}
```

其参数 subscribe 是一个 closure，而 closure 本质就是匿名函数。在 Swift 中函数作为一等公民，是可以直接作为参数传递的。因此，上面可以省略 closure 直接写成：

```swift
Observable.create(self.subscribe)
```

再来 Observable ：

```swift
public class Observable<Element> : ObservableType {
    
    public func subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
        rxAbstractMethod()
    }
    
    public func asObservable() -> Observable<Element> {
        return self
    }
}
```

它仅做了两件事：

1. 将 `subscribe(_:)` 方法标记为抽象方法，并通过 [fatalError](https://swifter.tips/fatalerror/) 来强制要求子类去实现；
2. 在 `asObservable() ` 中将 self 直接 return。

上面代码中没有列出 `init()` 和 `deinit()` 的实现，RxSwift 在这两方法中引入了内部的资源统计，用于 debug，实现如下，感兴趣的可以深究:

```swift
init() {
    #if TRACE_RESOURCES
        _ = Resources.incrementTotal()
    #endif
}
deinit {
    #if TRACE_RESOURCES
        _ = Resources.decrementTotal()
    #endif
}
```

序列存储已经结束，流的创建才刚刚开始。先贴一张脑图补一补，其实每个流的变换操作背后都对应一个 ObservableType 的扩展。

![rxswift](http://ww1.sinaimg.cn/large/8157560cly1gcvl07flwjj224o1smqh7.jpg)

# [Producer](https://github.com/ReactiveX/RxSwift/blob/c6c0c540109678b96639c25e9c0ebe4a6d7a69a9/RxSwift/Observables/Producer.swift)

再来看本文的重点之一 Producer：

```swift
class Producer<Element> : Observable<Element> {
    override func subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
        /// Scheduler {
        let disposer = SinkDisposer()
        let sinkAndSubscription = self.run(observer, cancel: disposer)
        disposer.setSinkAndSubscription(sink: sinkAndSubscription.sink, subscription: sinkAndSubscription.subscription)
        /// }
    }

    func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == Element {
        rxAbstractMethod()
    }
}
```

> 注释的 Scheduler 是 RxSwift 中相关的线程调度，它会根据标识选择相应线程去处理任务，我们先忽略。

看字面意思也能猜出它的作用吧。同样为抽象类，它的角色更像是一个管理者。它管理着 Observable 的创建、订阅、回收。每个 Producer 实例则对应一条流水线，而 RxSwift 则可以看作大型工厂，通过 Producer 持续的生产和消费 Observable。

###run(_:cancel:)

它对应流的创建，也包括对每个节点发送 Event 事件。作为抽象方法，子类通过重载来提供流的多元化创建。同时 run 方法所返回的 sink 则保存了各个节点的元数据，subscription 则保存了流的订阅操作。详细会在 Sink 类作展开。

###subscribe(_:)

它通过 sinkDisposer 来统一回收流所引用的元数据以及订阅相关的资源。

1. 判断是否需要用 `scheduler` 切换到指定的线程，来进行订阅逻辑的处理；
2. 创建 sinkDisposer，同 obserer 一起作为 `run(_:cancel:)` 的入参；
3. 将执行 `run(_:cancel:)` 方法后的结果保存到 sinkDisposer 中，为之后的资源销毁做准备；
4. 最后返回 sinkDisposer；

那就先就近先看 SinkDisposer 类。



### SinkDisposer

> The returned disposable needs to release all references once it was disposed.  

SinkDisposer 用于保证所有引用资源的最终释放。其声明如下：

```swift
private final class SinkDisposer: Cancelable {
    private enum DisposeState: Int32 {
        case disposed = 1
        case sinkAndSubscriptionSet = 2
    }

    private let _state = AtomicInt(0)
    private var _sink: Disposable?
    private var _subscription: Disposable?

    var isDisposed: Bool {
        return isFlagSet(self._state, DisposeState.disposed.rawValue)
    }

    func setSinkAndSubscription(sink: Disposable, subscription: Disposable) { ... }

    func dispose() { ... }
}
```

先分析它的继承关系：

```swift
| --- SinkDisposer
    | --- Cancelable
        | --- Disposable
```

Disposable 则是用于释放资源:

```swift
public protocol Disposable {
    /// Dispose resource.
    func dispose()
}
```

Cancelable，用于标识资源是否被释放：

```swift
public protocol Cancelable : Disposable {
    /// Was resource disposed.
    var isDisposed: Bool { get }
}
```

那 sinkDisposer 对保存结果做了什么处理，又是如何来释放资源的呢？主要靠下面这个方法。

####setSinkAndSubscription

实现如下：

```swift
self._sink = sink
self._subscription = subscription

let previousState = fetchOr(self._state, DisposeState.sinkAndSubscriptionSet.rawValue)
if (previousState & DisposeState.sinkAndSubscriptionSet.rawValue) != 0 {
    rxFatalError("Sink and subscription were already set")
}

if (previousState & DisposeState.disposed.rawValue) != 0 {
    sink.dispose()
    subscription.dispose()
    self._sink = nil
    self._subscription = nil
}
```

1. 保存 sink 和 subscription （均为 Disposable）
2. 获取 previousState （当前资源的状态是否被标示为已清理或已设置) ；
3. 如果 previousState 为 .sinkAndSubscriptionSet，则已设置过资源，直接抛错来防止重复调用；
4. 如果 previousState 为 .disposed，则资源已不可用，会对 sink 和 subscription 执行 `dispose()` 以释放资源，同时将它们置 nil。

这里，可能有小伙伴有疑问，一个 state 如何保存两个状态？来瞅一眼 [AtomicInt](https://github.com/ReactiveX/RxSwift/blob/master/Platform/AtomicInt.swift) 简化后的部分实现：

```swift
final class AtomicInt: NSLock {
    fileprivate var value: Int32
    public init(_ value: Int32 = 0) {
        self.value = value
    }
}

func fetchOr(_ this: AtomicInt, _ mask: Int32) -> Int32 {
    this.lock()
    let oldValue = this.value
    this.value |= mask
    this.unlock()
    return oldValue
}

func increment(_ this: AtomicInt) -> Int32 {
    return add(this, 1)
}

func decrement(_ this: AtomicInt) -> Int32 {
    return sub(this, 1)
}

...
```

> 说明：Atomic 中有返回值都的方法都有 **@discardableResult** 标记，只是这边简化了，同时所有方法都是
> **@inline(__always)** 标记的。

之前版本的 AtomicInt 是用 [OSAtomic.h](https://opensource.apple.com/source/xnu/xnu-201.5/libkern/libkern/OSAtomic.h.auto.html) 的 API 来实现的，现在改成用 NSLock 了。

这里看到 *位运算符* 大家应该知道它是怎么实现了吧。它通过每个 bit 来保存一个 flag 从而提高了访问效率。

接着我们看 `fetchOr(_:_:)` 它其实做了两件事情。

1. 先取出当前 value 做为返回值；
2. 将 mask 值保存到 value 中；

by the way，前面提到过 RxSwift 内部的资源统计方法 `Resources.incrementTotal()`  就是用 `increment(_:)` 实现的。 `Resources.decrementTotal()` 同理。



#### dispose

理解了 setSinkAndSubscription 后 dispose 就不难了，实现如下：

```swift
let previousState = fetchOr(self._state, DisposeState.disposed.rawValue)

if (previousState & DisposeState.disposed.rawValue) != 0 {
    return
}

if (previousState & DisposeState.sinkAndSubscriptionSet.rawValue) != 0 {
    guard let sink = self._sink else {
        rxFatalError("Sink not set")
    }
    guard let subscription = self._subscription else {
        rxFatalError("Subscription not set")
    }

    sink.dispose()
    subscription.dispose()

    self._sink = nil
    self._subscription = nil
}
```

1. 先取出 previousState 并将 .disposed 值写入 _state;
2. 判断 previousState 为 disposed：
   1. 如果是则表明已经清理过，直接 return；
   2. 否则对 sink 和 subscription 执行 `dispose()` 以释放资源，同时将它们置 nil。

RxSwift 通过 AutomicInt 的位运算，巧妙的用一个变量高效完成了多个状态的存储，最重要的是它保证了只有一次有效的 `dispose` 操作。还有很重要的一点，在释放资源后，sinkDisposer 都会主动将 sink 和 subscription 置 nil，这是为了解决**循环引用**。因为在 Sink 内部其实也引用了 sinkDisposer。



## Sink

项目中的 issue 有一个简单描述 [What is a Sink ?](https://github.com/ReactiveX/RxSwift/issues/817) 

> It's an internal class used to implement the operators, that receives events and processes them. 

Sink，接受 Event 事件并进行相应处理或者将其转发，是实现各种运算符的内部类，比如 Map、Reduce、Filter 运算符等。作为 Producer 背后的苦力一直默默付出。

Sink 从哪里来的呢？继续以开头的 `Observable.of(1, 2, 3)` 为例，看 ObservableSequence 的 run 方法实现：

```swift
final private class ObservableSequence<Sequence: Swift.Sequence>: Producer<Sequence.Element> {
    /// init ...
   
    override func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == Element {
        let sink = ObservableSequenceSink(parent: self, observer: observer, cancel: cancel)
        let subscription = sink.run()
        return (sink: sink, subscription: subscription)
    }
}
```

在其初始化时将关键数据都保存起来：

- self 为 Swift.Sequence<Int\>
- observer
- cancel 为 SinkDisposer

Sink 创建完后会将执行 `run()` 的结果作为 subscription，同 sink 一起返回后存入 sinkDisposer 中。这也是前面提到的有循环引用的情况，不过在 sinkDispoer 的 dispose 过程中做了 break。

Sink 声明如下：

```swift
class Sink<Observer: ObserverType> : Disposable {
    fileprivate let _observer: Observer
    fileprivate let _cancel: Cancelable // sinkDisposer
    private let _disposed = AtomicInt(0)

    final func forwardOn(_ event: Event<Observer.Element>) {
        if isFlagSet(self._disposed, 1) {
            return
        }
        self._observer.on(event)
    }

    final func forwarder() -> SinkForward<Observer> {
        return SinkForward(forward: self)
    }

    final var disposed: Bool {
        return isFlagSet(self._disposed, 1)
    }

    func dispose() {
        fetchOr(self._disposed, 1)
        self._cancel.dispose()
    }
}
```

又见到 AtomicInt，这次是修饰 _disposed 属性，各位自行理解。我们看核心方法：

1. `forwardOn(_:)` 用于转发，将 event 事件传递到 `Observer.on(_:)`；
2. `dispose()` 直接调用 sinkDisposer -> `dispose()`;

`forwarder()`  返回的 SinkForward 是 Observer 对象，它将 sink 的 observer 做了包装，该方法主要用于 `timeout()` 方法。转发逻辑如下：

```swift
final class SinkForward<Observer: ObserverType>: ObserverType {

    final func on(_ event: Event<Element>) {
        switch event {
        case .next:
            self._forward._observer.on(event)
        case .error, .completed:
            self._forward._observer.on(event)
            self._forward._cancel.dispose()
        }
    }
}
```

它不仅收集资源同时还加工以及转发事件。最后回到 ObservableSequenceSink 来看 `run()` 方法：

```swift
final private class ObservableSequenceSink<Sequence: Swift.Sequence, Observer: ObserverType>: Sink<Observer> where Sequence.Element == Observer.Element {
    typealias Parent = ObservableSequence<Sequence>

    private let _parent: Parent

    func run() -> Disposable {
        return self._parent._scheduler.scheduleRecursive(self._parent._elements.makeIterator()) { iterator, recurse in
            var mutableIterator = iterator
            if let next = mutableIterator.next() {
                self.forwardOn(.next(next))
                recurse(mutableIterator)
            }
            else {
                self.forwardOn(.completed)
                self.dispose()
            }
        }
    }
}
```

**_scheduler.scheduleRecursive** 背后是 RxSwift 对于容器对象的线程调度，也不展开。这里的 `run()`方法 做了几个事情：

1. Scheduler 会在指定线程中调用 Swift.Sequence 的迭代器，以遍历每个元素。
2. 获取到元素后，将 next 事件不断转发给 Observer；
3. 迭代结束后，发送 completed 事件至 Observer 并调用 dispose 出发 sinkDisposer 的资源清理操作；



关于 Sink 再说明一下，本篇是以 Sequence 作为切入点，不同 Operator 背后的 Producer 所产生的 Sink 实现是有不少区别的，比如 Just 流只产生单个节点，则直接在重载的 subscribe 方法里发送 Event 然后就调用 dispose 结束了。因此，每个 operator 的实现会有比较大的出路，但是整体流程是由这些内部类来限制和保证的。



## Subscription

我们回到文章开头接着聊一聊订阅：

```swift
.subscribe( { print($0) })
```

同 `of(_:)` 一样，订阅也是对 [ObservableType 扩展](https://github.com/ReactiveX/RxSwift/blob/master/RxSwift/ObservableType%2BExtensions.swift)来实现的。简化后如下：

```swift
extension ObservableType {

    public func subscribe(_ on: @escaping (Event<Element>) -> Void)
        -> Disposable {
            let observer = AnonymousObserver { e in
                on(e)
            }
            return self.asObservable().subscribe(observer)
    }

    public func subscribe(onNext: ((Element) -> Void)? = nil, onError: ((Swift.Error) -> Void)? = nil, onCompleted: (() -> Void)? = nil, onDisposed: (() -> Void)? = nil)
        -> Disposable {
        ...
    }
}
```

两个 subscribe 方法都是将订阅的操作存入 AnonymousObserver 中，然后通过 `asObservable()` 获取 producer 并最终其 `subscribe(_:)` 以完成订阅。

我们看看 [AnonymousObserver](https://github.com/ReactiveX/RxSwift/blob/master/RxSwift/Observers/AnonymousObserver.swift) 是什么来头：

```swift
final class AnonymousObserver<Element>: ObserverBase<Element> {
    typealias EventHandler = (Event<Element>) -> Void
    
    private let _eventHandler : EventHandler
    /// 这里同样忽略了 `init()` 与 `deinit()` 的资源统计逻辑
    init(_ eventHandler: @escaping EventHandler) {
        /// 资源统计
        self._eventHandler = eventHandler
    }

    override func onCore(_ event: Event<Element>) {
        return self._eventHandler(event)
    }
}
```

很简单，仅有一个 `_eventHandler` 属性保存订阅操作，然后在 `onCore(_:)` 中调用它。在翻它父类之前，看一眼它的继承关系：

```swift
| --- AnonymousObserver
    | --- ObserverBase
        | --- Disposable、ObserverType
```

Disposable 我们已经知道了，看 ObserverType：

```swift
public protocol ObserverType {
    associatedtype Element

    func on(_ event: Event<Element>)
}

/// Convenience API extensions to provide alternate next, error, completed events
extension ObserverType {

    public func onNext(_ element: Element) {
        self.on(.next(element))
    }

    public func onCompleted() {
        self.on(.completed)
    }
    
    public func onError(_ error: Swift.Error) {
        self.on(.error(error))
    }
}
```

声明了 `on(_:)` 方法，同时针对 Event 的类型提供了三个便利方法。Event 则是一个嵌套枚举类型：

```swift
public enum Event<Element> {
    /// Next element is produced.
    case next(Element)

    /// Sequence terminated with an error.
    case error(Swift.Error)

    /// Sequence completed successfully.
    case completed
}
```

#### ObserverBase

我们来看 [ObserverBase](https://github.com/ReactiveX/RxSwift/blob/master/RxSwift/Observers/ObserverBase.swift)：

```swift
class ObserverBase<Element> : Disposable, ObserverType {
    private let _isStopped = AtomicInt(0)

    func on(_ event: Event<Element>) {
        switch event {
        case .next:
            if load(self._isStopped) == 0 {
                self.onCore(event)
            }
        case .error, .completed:
            if fetchOr(self._isStopped, 1) == 0 {
                self.onCore(event)
            }
        }
    }

    func onCore(_ event: Event<Element>) {
        rxAbstractMethod()
    }

    func dispose() {
        fetchOr(self._isStopped, 1)
    }
}
```

ObserverBase 利用 Atomic 声明的 _isStopped 属性作为哨兵，以保证资源被标记 _isStopped 后不会产生重复调用的。那么，如何做到的呢？

通过判断 _isStopped 是否为 0 来表示资源是否可用。一旦调用 `dispose()` 会将其值置为 1，则资源不可用。

另一种情况则在 `on` 方法内，实现逻辑如下：

1. event 为 .next 事件：通过 `load(_:)` 取出 _isStopped 值并判断值是否为 0，是则执行 `onCore(event)` ；
2. event 为 .error、.completed 事件：
   1. 通过 `fetchOr(_:)` 取出 _isStopped 当前值后并将其置为 1，以保证不再重入；
   2. 判断 _isStopped 当前值是否为 0，是则执行 `onCore(event)` 。

因此 ObserverBase 核心功作用是保证暴露给子类的  `onCore(_:)`  在观察结束后不会被重复执行。也就是保证 AnonymousObserver 的 eventHandler 被正确执行。



最后，回顾一下订阅相关流程：

![rxswift-subscription](http://ww1.sinaimg.cn/large/8157560cly1gd35tywfx7j223n0wogtr.jpg)



## 总结

RxSwift 所展示的订阅流的处理，不仅充分利用了 Swift 语言本身的特性，如为协议添加默认实现、采用泛型来约束类的行为、天然支持链式调用等。通过经典的设计模式 [Producer–consumer](https://www.wikiwand.com/en/Producer%E2%80%93consumer_problem)，以多元化的 Producer 来轻松支持各种 operator 的实现。还有就是巧妙的运用了位运算来简化逻辑。

由于篇幅有限，Schedule 的调度逻辑并未展开，还有就是 DisposeBag 通篇未提及，就当是思考作业啦。



