---
title: "浅析 - CocoaLumberjack 3.6 之 DDLog"
date: 2020-05-04T18:20:00+08:00
tags: ['Source Code', 'iOS', 'Logger']
categories: ['iOS']
draft: false
author: "土土Edmond木"
---



# 介绍

> **CocoaLumberjack** is a fast & simple, yet powerful & flexible logging framework for Mac and iOS. 

先扯一下 lumberjack 这个单词，对应的就是它的 logo，一位伐木工，好想知道作者对用意啊，是基础建设的意思吗？

写这篇文章的理由并非心血来潮，而是最近在使用过程中偶然发现，它居然有这么多隐藏功能，尽管项目里引入也有好多年了。接着又看了一下官方提供的 demos， 简直是惊呆了（也太丰富了吧，强烈建议各位看看官方 Demo）。最后，因为国内基本都是关于它的使用介绍，本文希望能从代码的角度来看看它的一些设计和🤔。最后会介绍一下它所支持的扩展。



### Document

作为历史悠久的 library，它的 [document](https://github.com/CocoaLumberjack/CocoaLumberjack/tree/master/Documentation) 还是非常详细的，主要分三个级别：

- Beginner 入门级：[使用说明](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/GettingStarted.md)、[自定义日志格式](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/CustomFormatters.md)、[性能测试](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/Performance.md)、支持[彩色输出](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/XcodeColors.md)等；
- Intermediate 进阶：lumberjack [内部概述](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/Architecture.md)，如何定制 [custom logging context](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/CustomContext.md)、[custrom logger](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/CustomLoggers.md)、[custom log levels](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/CustomLogLevels.md) 等；
- Advanced：高阶：[动态修改 log levels](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/DynamicLogLevels.md)、[log 文件管理（压缩、上传](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/LogFileManagement.md)。



### [Architecture](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/Architecture.md)

照例，我们先预览一下类图，有个大概的印象。

![CocoaLumberjackClassDiagram.png](http://ww1.sinaimg.cn/large/8157560cly1gdzck4x5v5j213v0iv41x.jpg)



在梳理完脑图才发现官方其实提供了完整的 UML 图。不过既然整理了脑图，那我把它贴在文末。

UML 上直观感受就是 class 并不多，但是功能确实十分完善，我们一点点来看看。





# DDLog

本文默认你是经历过新手村的，如果对 Lumberjack 的 API 完全不熟悉，请挪步：[getting start](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/GettingStarted.md)。

核心文件 DDLog.h 中有声明了最重要的两个协议 **DDLoger** 和 **DDLogFormatter**，而 **DDLog** class 可以看作是一个 manager 的存在，它管理着所有注册在案的 loogers 和 formatters。这三个对于正常项目来说已经完全够用了。我们就从 protocol 着手，最后来说这个 DDLog。



## Loggers

> A logger is a class that does something with a log message. The lumberjack framework comes with several different loggers. (You can also [create your own](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/CustomLoggers.md).) Loggers such as `DDOSLogger` can be used to duplicate the functionality of `NSLog`. And `DDFileLogger` can be used to write log messages to a log file.

loggers 相关类主要是对 log message 进行加工处理。那么一条 DDLogMessage 会存有哪些可用信息呢？



### DDLogMessage

> Used by the logging primitives. (And the macros use the logging primitives.)

log message 用于记录日志原语，它是通过宏来实现的。logging primitives 是什么意思呢？可以理解为 log message 保存了 log 被调用时的一系列相关环境的上下文。单词 primitive 一开始没看明白，不过计算机中倒是有一个[原语](https://baike.baidu.com/item/%E5%8E%9F%E8%AF%AD)的概念（不一定对），可以帮助大家理解这个单词。

具体存了哪些东西呢？

```objc
@interface DDLogMessage : NSObject <NSCopying>
{
    // Direct accessors to be used only for performance
    @public
    NSString *_message;
    DDLogLevel _level;
    DDLogFlag _flag;
    NSInteger _context;
    NSString *_file;
    NSString *_fileName;
    NSString *_function;
    NSUInteger _line;
    id _tag;
    DDLogMessageOptions _options;
    NSDate * _timestamp;
    NSString *_threadID;
    NSString *_threadName;
    NSString *_queueLabel;
    NSUInteger _qos;
}
```

这里通过前置声明实例变量，这样调用方可以避开 getter 直接访问变量，来提高访问效率。当然作者也提供了 readonly 的 @property method。

首先，message、file、function **默认不会执行 copy 操作**，如果需要可以通过 DDLogMessageOptions 来控制：

```objc
typedef NS_OPTIONS(NSInteger, DDLogMessageOptions){
	 /// Use this to use a copy of the file path
    DDLogMessageCopyFile        = 1 << 0,
 	 /// Use this to use a copy of the function name
    DDLogMessageCopyFunction    = 1 << 1,
	 /// Use this to use avoid a copy of the message
    DDLogMessageDontCopyMessage = 1 << 2
};
```

我们知道，对于 NSString 的操作需要使用 copy ，以保证我们对它操作时是安全及不可变的。这里针对 message、file、function 却不采用 copy，是为了避免不必要的 allocations 开销。因为 file 和 function 是通过 _\_FILE\_\_ and _\_FUNCTION\_\_ 这两个宏来获取的，它们本质上就是一个字符常量，所以可以这么操作。而 message 正常由 DDlog 内部生成的，Lumberjack 来保证 mesage 不可修改。So 官方提示如下：

> If you find need to manually create logMessage objects, there is one thing you should be aware of.

说的就是，当你需要手动生成 log message 的时候需要注意，这三个参数的内存修饰操作。

log message 内部实现就比较简单了，以 message 字段为例：

```objc
BOOL copyMessage = (options & DDLogMessageDontCopyMessage) == 0;
_message = copyMessage ? [message copy] : message;
```

另外，就是每个 logMessage 会记录当前调用的 thread & queue 信息，分别如下:

```objc
__uint64_t tid;
if (pthread_threadid_np(NULL, &tid) == 0) {
    _threadID = [[NSString alloc] initWithFormat:@"%llu", tid];
} else {
    _threadID = @"missing threadId";
}
_threadName   = NSThread.currentThread.name;
// Try to get the current queue's label
_queueLabel = [[NSString alloc] initWithFormat:@"%s", dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)];
if (@available(macOS 10.10, iOS 8.0, *))
    _qos = (NSUInteger) qos_class_self();
```



### DDLogLevel

> Log levels are used to filter out logs. Used together with flags.

每一条 log mesage 都设置了对应的日志级别，用于过滤 logs 的。其定义是一个枚举：

```objc
typedef NS_ENUM(NSUInteger, DDLogLevel) {
    // No logs
    DDLogLevelOff       = 0, 
    // Error logs only
    DDLogLevelError     = (DDLogFlagError), 
    // Error and warning logs
    DDLogLevelWarning   = (DDLogLevelError   | DDLogFlagWarning),
    // Error, warning and info logs
    DDLogLevelInfo      = (DDLogLevelWarning | DDLogFlagInfo), 
    // Error, warning, info and debug logs
    DDLogLevelDebug     = (DDLogLevelInfo    | DDLogFlagDebug), 
    // Error, warning, info, debug and verbose logs
    DDLogLevelVerbose   = (DDLogLevelDebug   | DDLogFlagVerbose), 
    // All logs (1...11111)
    DDLogLevelAll       = NSUIntegerMax 
};
```

而 loglevel 是由 DDLogFlag 控制，其声明如下：

```objc
typedef NS_OPTIONS(NSUInteger, DDLogFlag) {
    // 0...00001 DDLogFlagError
    DDLogFlagError      = (1 << 0),
    // 0...00010 DDLogFlagWarning
    DDLogFlagWarning    = (1 << 1),
    // 0...00100 DDLogFlagInfo
    DDLogFlagInfo       = (1 << 2),
    // 0...01000 DDLogFlagDebug
    DDLogFlagDebug      = (1 << 3),
    // 0...10000 DDLogFlagVerbose
    DDLogFlagVerbose    = (1 << 4)
};
```

这些就是 DDLog 所预设的 5 种 level，对于新手来说基本够用了。同时，对于有自定义 level 需求的用户来说，可以通过结构化的宏，就能轻松实现。详见 [CustomLogLevels.md](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/CustomLogLevels.md)。

其核心是先将预设的 level 清除，然后在进行重新定义：

```objc
// First undefine the default stuff we don't want to use.
#undef DDLogError
#undef DDLogWarn
#undef DDLogInfo
#undef DDLogDebug
#undef DDLogVerbose
...
// Now define everything how we want it
#define LOG_FLAG_FATAL   (1 << 0)  // 0...000001
#define LOG_LEVEL_FATAL   (LOG_FLAG_FATAL)  // 0...000001
#define LOG_FATAL   (ddLogLevel & LOG_FLAG_FATAL )
#define DDLogFatal(frmt, ...)    SYNC_LOG_OBJC_MAYBE(ddLogLevel, LOG_FLAG_FATAL,  0, frmt, ##__VA_ARGS__)
...
```

除了对 level 的重定义之外，我们也可以通过对 level 进行扩展来满足我们对需求。由于 lumberjack 使用的是 bitmask 且只预设了 5 个 bit，对应 5 种 log flag。

而 logLevel 作为 Int 类型，意味着对于 32 位的系统而言，预留给我们的 levels 还有 28 bits，因为默认的 level 仅仅占用了 4 bits。扩展空间可以说是绰绰有余的。官方提供了两个需要进行扩展的场景，详见：[FineGrainedLogging.md](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/FineGrainedLogging.md)。



### DDLoger

> This protocol describes a basic logger behavior. 
>  *  Basically, it can log messages, store a logFormatter plus a bunch of optional behaviors.
>  *  (i.e. flush, get its loggerQueue, get its name, ...

```objective-c
@protocol DDLogger <NSObject>

- (void)logMessage:(DDLogMessage *)logMessage NS_SWIFT_NAME(log(message:));
@property (nonatomic, strong, nullable) id <DDLogFormatter> logFormatter;

@optional
- (void)didAddLogger;
- (void)didAddLoggerInQueue:(dispatch_queue_t)queue;
- (void)willRemoveLogger;
- (void)flush;

@property (nonatomic, DISPATCH_QUEUE_REFERENCE_TYPE, readonly) dispatch_queue_t loggerQueue;
@property (copy, nonatomic, readonly) DDLoggerName loggerName;

@end
```

logMessage 没啥好说的，logFormatter 会在后面介绍。重点看上面的几个 optional 方法和参数。

**loggerQueue**

先看 loggerQueue，由于日志打印均为异步操作，所以会为每个 looger 分配一个 dispatch_queue_t。如果 logger 未提供 loggerQueue，那么 DDLog 为根据你所指定的 loggerName 主动为你生成。

**didAddLogger**

同样由于异步打印日志的原因，looger 被添加到 loogers 中时也是异步的过程，didAddLogger 方法就是用于通知  logger 已被成功添加，而这个操作时在 loggerQueue 中完成的。

同样，`didAddLoggerInQueue:` 和 `willRemoveLogger` 目的也是类似。

**flush**

用于刷新存在在队列中还未处理的 log message。比如，database logger 可能通过 I/O buffer 来减少日志存储频率，毕竟磁盘 I/O 是比较耗时的，这种情况下，logger 中可能留有未被及时处理的 log message。

DDLog 会通过 `flushLog` 来执行 flush 。需要⚠️的是，当应用退出的时候  `flushLog` 会被自动调用。当然，作为开发者我们可以在适当的情况下手动触发刷新，正常是不需要手动触发的。 



### DDLogFormatter

> Formatter allow you to format a log message before the logger logs it. 

```objective-c
@protocol DDLogFormatter <NSObject>

@required
- (nullable NSString *)formatLogMessage:(DDLogMessage *)logMessage NS_SWIFT_NAME(format(message:));

@optional
- (void)didAddToLogger:(id <DDLogger>)logger;
- (void)didAddToLogger:(id <DDLogger>)logger inQueue:(dispatch_queue_t)queue;
- (void)willRemoveFromLogger:(id <DDLogger>)logger;

@end
```

**formatLogMessage:**

formatter 是可以添加到任何 logger 上的，通过 `formatLogMessage:` 极大提高了 logging 的自由度。怎么理解呢？我们可以通过 `formatLogMessage:` 给 file logger 和 console 返回不同的结果。例如 console 一般系统会自动在 log 前添加时间戳，而当我们写入 log file 时就需要自行来添加时间。我们还可以通过返回 nil 将其作为 filter 来过滤对应的 log。

**didAddToLogger**

一个 formatter 可以被添加到多个 logger 上。当 formatter 被添加时，通过这个方法来通知它。该方法是需要保证线程安全的，否则可能会出现线程安全异常。

同理，`didAddToLogger: inQueue` 是指在指定队列中进行 format 操作。

`willRemoveFromLogger` 则是 formatter 被移除时的通知。 



## DDLog

> The main class, exposes all logging mechanisms, loggers, ...
>
> For most of the users, this class is hidden behind the logging functions like `DDLogInfo`

DDLog 作为 lumberjack 的管理类，负责将用户的 log 信息收集后集中调度至不同的 logger 已达到不同的功能，比如 console log 和 file log。因此，作为单例是必须的。我们先来看看它初始化都准备了什么东西。

### Initialize

```objective-c
@interface DDLog ()

@property (nonatomic, strong) NSMutableArray *_loggers;

@end

@implementation DDLog

static dispatch_queue_t _loggingQueue;
static dispatch_group_t _loggingGroup;
static dispatch_semaphore_t _queueSemaphore;
static NSUInteger _numProcessors;
...
```

上面几个均为私有变量，_loggers 自不必说，任何 logger 的添加/删除都需要在 loggingQueue/loggingThread 中进行的。

**_loggingQueue**

全局的 log queue 用于保证 FIFO 的操作顺序，所有 logger 会通过它来顺序执行各 logger 的 `logMessage:` 。

**_loggingGroup**

由于每个 logger 添加时候都配置了对应的 log queue。因此，loggers 之间的记录行为是并发执行的。而 dispatch group 可以同步所有 loggers 的操作，确保记录行为顺利完成。

**_queueSemaphore**

防止所使用的队列过爆。由于大多数记录都是异步操作，因此，可能遭到恶意线程大量的增加 log 影响正常的记录行为。最大限制数为 DDLOG_MAX_QUEUE_SIZE (1000)，也就是说当队列数超过限制，则会主动阻塞线程，以待执行队列降至安全水平。

例如：在大型循环中随意添加日志语句时会发生过💥。

**_numProcessors**

记录处理器内核数量，以针对单核情况时进行相应的优化。



作为静态变量，其初始化则放在 `initialize`，如下：

```objective-c
+ (void)initialize {
    static dispatch_once_t DDLogOnceToken;

    dispatch_once(&DDLogOnceToken, ^{
        NSLogDebug(@"DDLog: Using grand central dispatch");

        _loggingQueue = dispatch_queue_create("cocoa.lumberjack", NULL);
        _loggingGroup = dispatch_group_create();

        void *nonNullValue = GlobalLoggingQueueIdentityKey; // Whatever, just not null
        dispatch_queue_set_specific(_loggingQueue, GlobalLoggingQueueIdentityKey, nonNullValue, NULL);

        _queueSemaphore = dispatch_semaphore_create(DDLOG_MAX_QUEUE_SIZE);

        // Figure out how many processors are available.
        // This may be used later for an optimization on uniprocessor machines.

        _numProcessors = MAX([NSProcessInfo processInfo].processorCount, (NSUInteger) 1);

        NSLogDebug(@"DDLog: numProcessors = %@", @(_numProcessors));
    });
}
```

上述代码中，通过 `dispatch_queue_set_specific` 为 _loggingQueue 添加了 key：**GlobalLoggingQueueIdentityKey** 作为标记。之后会在所有的内部方法执行前通过 `dispatch_get_specific` 获取 flag 来进行断言，确保内部方法都是在全局的 _loggingQueue 中调度的。



接着，我们来看看 DDLog 实例的初始化，仅做了两件事：

- _loggers 初始化；
- 尝试注册通知，确保 APP 进程结束前能够及时将 Logger 中的 message 处理完毕；

由于 lumberjack 支持全平台以及命令行，这里的 notificationName 判断条件相对多一些：

```objective-c
#if TARGET_OS_IOS
    NSString *notificationName = UIApplicationWillTerminateNotification;
#else
    NSString *notificationName = nil;
    // On Command Line Tool apps AppKit may not be available
#if !defined(DD_CLI) && __has_include(<AppKit/NSApplication.h>)
    if (NSApp) {
        notificationName = NSApplicationWillTerminateNotification;
    }
#endif
    if (!notificationName) {
        // If there is no NSApp -> we are running Command Line Tool app.
        // In this case terminate notification wouldn't be fired, so we use workaround.
        __weak __auto_type weakSelf = self;
        atexit_b (^{
            [weakSelf applicationWillTerminate:nil];
        });
    }
#endif /* if TARGET_OS_IOS */
```

稍微提一点，命令行中是如何来监听程序退出？这里用到了 `atexit`

> The atexit() function registers the given function to be called at program exit, whether via exit(3) or via return from the program's main().  Functions so registered are called in reverse order; no arguments are passed.

就是说，程序在退出时，系统会主动调用通过 atexit 注册的 callbacks，可以注册多个回调，按照顺序执行。

DDLog 在收到通知后会触发 `flush`，这个我们晚一点展开。

```objective-c
if (notificationName) {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminate:)
                                                 name:notificationName
                                               object:nil];
}

- (void)applicationWillTerminate:(NSNotification * __attribute__((unused)))notification {
    [self flushLog];
}
```



### Logger Management

对 logger 的操作主要是添加和删除。

**AddLogger**

DDLog 提供了多个添加 logger 的 convince 方法：

```objective-c
+ (void)addLogger:(id <DDLogger>)logger;
- (void)addLogger:(id <DDLogger>)logger;
+ (void)addLogger:(id <DDLogger>)logger withLevel:(DDLogLevel)level;
- (void)addLogger:(id <DDLogger>)logger withLevel:(DDLogLevel)level；

- (void)addLogger:(id <DDLogger>)logger withLevel:(DDLogLevel)level {
    if (!logger) {
        return;
    }
    dispatch_async(_loggingQueue, ^{ @autoreleasepool {
        [self lt_addLogger:logger level:level];
    } });
}
```

在放入 _loggingQueue 后，最终走到了 `lt_addLogger: level:` 方法。这里的前缀 `lt` 是 lgging thread 的缩写。在 logger 添加前会检查去重：

```objective-c
for (DDLoggerNode *node in self._loggers) {
    if (node->_logger == logger && node->_level == level) {
        // Exactly same logger already added, exit
        return;
    }
}
```

**DDLoggerNode**

```objc
@interface DDLoggerNode : NSObject
{
    // Direct accessors to be used only for performance
    @public
    id <DDLogger> _logger;
    DDLogLevel _level;
    dispatch_queue_t _loggerQueue;
}

+ (instancetype)nodeWithLogger:(id <DDLogger>)logger
                   loggerQueue:(dispatch_queue_t)loggerQueue
                         level:(DDLogLevel)level;
```

私有类，用于关联 logger、level 和 loggerQueue。

稍微提一下，在 DDLoggerNode 的初始化方法中的，兼容了 MRC 的使用。内部使用了一个宏 `OS_OBJECT_USE_OBJC` 来区分 GCD 是否支持 ARC。在6.0 之前 GCD 中的对象是不支持 ARC，因此在 6.0 之前 `OS_OBJECT_USE_OBJC` 是没有的。

```objective-c
if (loggerQueue) {
    _loggerQueue = loggerQueue;
    #if !OS_OBJECT_USE_OBJC
    dispatch_retain(loggerQueue);
    #endif
}
```

接着就是前面所提到的 QueueIdentity 的断言：

```objective-c
NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
         @"This method should only be run on the logging thread/queue");
```

准备 loggerQueue：

```objective-c
dispatch_queue_t loggerQueue = NULL;
if ([logger respondsToSelector:@selector(loggerQueue)]) {
    loggerQueue = logger.loggerQueue;
}

if (loggerQueue == nil) {
    const char *loggerQueueName = NULL;
    if ([logger respondsToSelector:@selector(loggerName)]) {
        loggerQueueName = logger.loggerName.UTF8String;
    }
    loggerQueue = dispatch_queue_create(loggerQueueName, NULL);
}
```

这段代码，有没有似曾相识的干？这是在 `DDLogger Protocol` 声明时提到的逻辑。如果 logger 提供了 loggerQueue 则直接使用。否则，通过 loggerName 来创建。

最后就是创建 DDLoggerNode，添加 logger，发送 `didAddLogger` 通知。

```objective-c
DDLoggerNode *loggerNode = [DDLoggerNode nodeWithLogger:logger loggerQueue:loggerQueue level:level];
[self._loggers addObject:loggerNode];

if ([logger respondsToSelector:@selector(didAddLoggerInQueue:)]) {
    dispatch_async(loggerNode->_loggerQueue, ^{ @autoreleasepool {
        [logger didAddLoggerInQueue:loggerNode->_loggerQueue];
    } });
} else if ([logger respondsToSelector:@selector(didAddLogger)]) {
    dispatch_async(loggerNode->_loggerQueue, ^{ @autoreleasepool {
        [logger didAddLogger];
    } });
}
```



**RemoveLogger**

同 addLogger 类似，removeLogger 也提供了实例方法和类方法。类方法通过 sharedInstance 最终收口到实例方法：

```objective-c
- (void)removeLogger:(id <DDLogger>)logger {
    if (!logger) {
        return;
    }
    dispatch_async(_loggingQueue, ^{ @autoreleasepool {
        [self lt_removeLogger:logger];
    } });
}
```

**-[DDLog lt_removeLogger:]**

删除前，照例是 loggingQueue 检查，然后遍历获取 loggerNode：

```objective-c
DDLoggerNode *loggerNode = nil;
for (DDLoggerNode *node in self._loggers) {
    if (node->_logger == logger) {
        loggerNode = node;
        break;
    }
}
```

如果 loggerNode 不存在，则提前结束。存在，则会先向 loggerNode 发送 `willRemoveLogger` 通知，再移除。

```objective-c
if ([logger respondsToSelector:@selector(willRemoveLogger)]) {
    dispatch_async(loggerNode->_loggerQueue, ^{ @autoreleasepool {
        [logger willRemoveLogger];
    } });
}
[self._loggers removeObject:loggerNode];
```

DDLog 还提供了 removeAllLoggers 的方法，以一次性清零 loggers，实现同 `lt_removeLogger:` 类似，这里不展开了。



### Logging

logging 相关方法是 DDLog 的核心，提供三种类型的实例方法，以及分别对应的类方法。我们来看第一个：

```objective-c
+ (void)log:(BOOL)asynchronous
      level:(DDLogLevel)level
       flag:(DDLogFlag)flag
    context:(NSInteger)context
       file:(const char *)file
   function:(nullable const char *)function
       line:(NSUInteger)line
        tag:(nullable id)tag
     format:(NSString *)format, ... NS_FORMAT_FUNCTION(9,10);
```

熟悉吧，这些参数前面都介绍过了，是构造 log message 所需的关参数。最后一个 C 写法的可变参数 `...` 用于生成 log message string，同样 DDLog 也提供了它的变种 `args:(va_list)argList` ，这就是第二种 log 方法。最后一种则是由用户直接提供 logMessage。

对于 `...` 的可变参数的获取，是通过 c 提供的宏，代码如下：

```objective-c
va_list args;
va_start(args, format);
NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
va_end(args);
```



**-[DDLog queueLogMessage: asynchronously:]**

准备好 log message 则开始分发，进行异步调用：

```objc
- (void)queueLogMessage:(DDLogMessage *)logMessage asynchronously:(BOOL)asyncFlag {
   dispatch_block_t logBlock = ^{
        dispatch_semaphore_wait(_queueSemaphore, DISPATCH_TIME_FOREVER);
        @autoreleasepool {
            [self lt_log:logMessage];
        }
    };

    if (asyncFlag) {
        dispatch_async(_loggingQueue, logBlock);
    } else if (dispatch_get_specific(GlobalLoggingQueueIdentityKey)) {
        logBlock();
    } else {
        dispatch_sync(_loggingQueue, logBlock);
    }
}
```

先忽略 logBlock，看 DDLog 如果处理 loggingQueue 调度，以及如何来避免线程死锁问题。这里的解决方式绝对需要**划重点**。大家经常遇到的主线程死锁，很常见的情况如下：

```objc
- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"1");
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSLog(@"2");
    });
    NSLog(@"3");
}
```

这个也是面试会被常常问到的 case。核心点在于，上述代码在 main thread 执行了 dispatch_sync 开启了 main queue 的同步等待。解决方案就有很多种，比如 SDWebImage 中就提供了 [dispatch_main_async_safe](https://looseyi.github.io/post/sourcecode-ios/source-code-sdweb-1/) 来避免该问题。

回到 DDLog，现在大家可以明白在 dispatch_sync 前为何需要多一步 queue identity 的判断了吧。另外，关于这个问题，[github issuse #812](https://github.com/CocoaLumberjack/CocoaLumberjack/issues/812#issuecomment-298853313) 中有比较详细的论述。

接着看 logBlock，它在执行第一行代码时，就开启了 semaphore_wait 直到可用队列数小于 maximumQueueSize。通常来说，我们会通过给 queueSize 加锁的方式来确保可用队列数的准确性和线程安全。但是这里作者希望，能够更快速的来获取添加 log mesage 入队列的时机，毕竟锁的开销比较大。

这种实践在很多优秀开源库中都用到了，比如 SDWebImage。



**- [DDLog lt_log:]**

该方法是将 log message 分配到所以满足的 logger 手中。开始前照例进行 QueueIdentity 的断言。接着依据 CPU 内核数是单核或者多核区别对待：

```objective-c
if (_numProcessors > 1) {  ... } else { ... }
```

1. 多核处理器，代码如下：

```objective-c
for (DDLoggerNode *loggerNode in self._loggers) {
    if (!(logMessage->_flag & loggerNode->_level)) {
        continue;
    }
    dispatch_group_async(_loggingGroup, loggerNode->_loggerQueue, ^{ @autoreleasepool {
        [loggerNode->_logger logMessage:logMessage];
    } });
}
dispatch_group_wait(_loggingGroup, DISPATCH_TIME_FOREVER);
```

稍微提一下 DDLog 的设计思路，由于一条 log message 可能会提供给多个不同类型的 logger 处理。例如，一条 log 可能同时需要输出到终端、写入到 log file 中、通过 websocket 输出到浏览器方便测试等操作。

首先，通过 logMessage->_flag 过滤掉 level 不匹配的 loggerNode。然后从匹配到的 loggerNode 中取出 loggerQueue 和 logger 调用 `logMessage:` 。

重点来了，这里利用 _loggingGroup 将本次的 `logMessage:` 关联到 group 中，打包成一个 "事务"，以保证每次的 `lt_log:` 都是顺序执行的。而每个 logger 本身都分配了独立的 loggerQueue，通过这种组合，即保证了 logger 的并发调用，又能满足 queueSize 的限制。

使用 dispatch_group_wait 还有一个目的，就是确保那些执行效果慢的 logger 也能按顺序完成调用，避免队列任务过多时，这些 logger 没能及时完成导致大量的 padding log message 没有被及时处理。

2. 对单核处理就比较简单了，就是第二步不同。不存在 gropu 操作：

```objective-c
dispatch_sync(loggerNode->_loggerQueue, ^{ @autoreleasepool {
    [loggerNode->_logger logMessage:logMessage];
} });
```

最后，分配完 logger message 后，需要将 _queueSemaphore 加 1:

```objective-c
dispatch_semaphore_signal(_queueSemaphore);
```



**lt_flush**

DDLog 的最后一个方法，会在程序结束前由通知来触发执行，其实现同 `lt_log:` 类似：

```objective-c
- (void)lt_flush {
    NSAssert(dispatch_get_specific(GlobalLoggingQueueIdentityKey),
             @"This method should only be run on the logging thread/queue");

    for (DDLoggerNode *loggerNode in self._loggers) {
        if ([loggerNode->_logger respondsToSelector:@selector(flush)]) {
            dispatch_group_async(_loggingGroup, loggerNode->_loggerQueue, ^{ @autoreleasepool {
                [loggerNode->_logger flush];
            } });
        }
    }
    dispatch_group_wait(_loggingGroup, DISPATCH_TIME_FOREVER);
}
```



### 小结

DDLog 名副其实的 manager，利用了信号量和 group 高效的完成对 message 的调度，主要做了以下工作：

1. 管理 logger 的生命周期，并对其添加、删除操作进行相应通知；
2. 生成 logMessage 并在线程安全的情况下，将其分配到对应的 logger 以加工 message。
3. 在程序结束后，及时通知 logger 清理 pending 状态的 message。



# Loggers

现在我们来聊聊 logger。DDLog 给我们提供了一个 logger 基类 DDAbstractLogger 以及几个默认实现。一一来过一下；



## DDAbstractLogger

AbstractLogger 声明如下：

```objective-c
@interface DDAbstractLogger : NSObject <DDLogger>
{
    @public
    id <DDLogFormatter> _logFormatter;
    dispatch_queue_t _loggerQueue;
}

@property (nonatomic, strong, nullable) id <DDLogFormatter> logFormatter;
@property (nonatomic, DISPATCH_QUEUE_REFERENCE_TYPE) dispatch_queue_t loggerQueue;
@property (nonatomic, readonly, getter=isOnGlobalLoggingQueue)  BOOL onGlobalLoggingQueue;
@property (nonatomic, readonly, getter=isOnInternalLoggerQueue) BOOL onInternalLoggerQueue;

@end
```

先看初始化方法 `init` ：

### Init

AdstractLogger 默认提供了 loggerQueue 以及当前是否为 loggerQueue 和 全局 loggingQueue 的 convene 方法。loggerQueue 的初始化是在 `init` 中完成的，整个 `init` 也就做了这一件事。

```objective-c
const char *loggerQueueName = NULL;

if ([self respondsToSelector:@selector(loggerName)]) {
    loggerQueueName = self.loggerName.UTF8String;
}

_loggerQueue = dispatch_queue_create(loggerQueueName, NULL);
void *key = (__bridge void *)self;
void *nonNullValue = (__bridge void *)self;
dispatch_queue_set_specific(_loggerQueue, key, nonNullValue, NULL);
```

同样先获取 queueName，这里默认返回的 `loggerName` 是 `NSStringFromClass([self class]);` 。

同时，以 self 的地址作为 flag 关联到 loggerQueue，并用于判断 `onInternalLoggerQueue` 。



### LogFormatter

AdstractLogger 最主要的是实现了 logFormatter 的 getter/setter 方法。同时代码中赋予了十分详细的说明，先看看 getter 实现。

**Getter**

首先是线程相关的断言，确保当前不在 global queue 和 loggerQueue：

```objective-c
NSAssert(![self isOnGlobalLoggingQueue], @"Core architecture requirement failure");
NSAssert(![self isOnInternalLoggerQueue], @"MUST access ivar directly, NOT via self.* syntax.");
```

接着在 loggingQueue 和 loggerQueue 中获取 logFormatter：

```objc
dispatch_queue_t globalLoggingQueue = [DDLog loggingQueue];

__block id <DDLogFormatter> result;

dispatch_sync(globalLoggingQueue, ^{
    dispatch_sync(self->_loggerQueue, ^{
        result = self->_logFormatter;
    });
});
return result;
```

看去一个普通的 formatter 为何需要如此大动干戈，需要层层深入来呢？我们来看一段代码：

```objective-c
DDLogVerbose(@"log msg 1");
DDLogVerbose(@"log msg 2");
[logger setFormatter:myFormatter];
DDLogVerbose(@"log msg 3");
```

从直觉上，我们希望看到的结果是新设置的 formatter 仅应用在第 3 条 log message 上。然而 DDLog 在整个 logging 过程中却都是异步调用的。

1. log message 最终是在单独的 loggerQueue 中执行的，是由 logger 各自持有的 queue；
2. 在进入每个 loggerQueue 之前，又要经过一道全局的 loggingQueue。

So，想要线程安全又要符合直觉的话，只能遵循 log message 的脚步，走一遍相关 queue。

需要强调一点，logger在内部**最好直接访问 FORMATTER VARIABLE** ，如果需要的话。一旦使用 `self.`  可能会导致线程死锁。



**Setter**

同 getter 一致，先断言，然后依次进入队列 `DDLog.loggingQueue -> self->_loggerQueue` 执行 block 开始真正的赋值：

```objc
@autoreleasepool {
    if (self->_logFormatter != logFormatter) {
        if ([self->_logFormatter respondsToSelector:@selector(willRemoveFromLogger:)]) {
            [self->_logFormatter willRemoveFromLogger:self];
        }

        self->_logFormatter = logFormatter;

        if ([self->_logFormatter respondsToSelector:@selector(didAddToLogger:inQueue:)]) {
            [self->_logFormatter didAddToLogger:self inQueue:self->_loggerQueue];
        } else if ([self->_logFormatter respondsToSelector:@selector(didAddToLogger:)]) {
            [self->_logFormatter didAddToLogger:self];
        }
    }
}
```



## DDASLLogger

ASLLogger 是对 **Apple System Log** API 的封装，我们经常使用的 `NSLog` 会将其输出定向到两个地方：

- [Apple System Log](https://support.apple.com/zh-cn/guide/console/cnsl1012/mac)
- [Standard error](https://www.wikiwand.com/en/Standard_streams) （telemetry）

不过 ASLLogger 在 macosx 10.12 iOS 10.0 已经被废弃了，取而代之的是 DDOSLoger。ASLLogger 背后使用的 API 是 [**<asl.h>**](https://opensource.apple.com/source/Libc/Libc-583/include/asl.h.auto.html) ，它也提供了几种 message level

```objective-c
/*! @defineblock Log Message Priority Levels Log levels of the message. */
#define ASL_LEVEL_EMERG   0
#define ASL_LEVEL_ALERT   1
#define ASL_LEVEL_CRIT    2 // DDLogFlagError
#define ASL_LEVEL_ERR     3 // DDLogFlagWarning
#define ASL_LEVEL_WARNING 4 // DDLogFlagInfo, Regular NSLog's level
#define ASL_LEVEL_NOTICE  5 // default
#define ASL_LEVEL_INFO    6
#define ASL_LEVEL_DEBUG   7
```

默认情况下 ASL 会过滤 NOTICE 之上的信息，这也是为何 DDLog 基本也就设置了 5 种日志级别。

### logMessage

logMessage 是每个 logger 处理 log message 的方法。ASLLogger 首先会过滤 filename 为 `DDASLLogCapture` (主动监听的系统 log)。然后对 message 进行 formate：

```objc
NSString * message = _logFormatter ? [_logFormatter formatLogMessage:logMessage] : logMessage->_message;
```

如果 message 存在，生成 `aslmsg`  通过 `asl_send` 发送至 ASL。实现如下：

```objective-c
const char *msg = [message UTF8String];
size_t aslLogLevel; // logMessage->_flag 获取 ASL_LEVEL_XXX

static char const *const level_strings[] = { "0", "1", "2", "3", "4", "5", "6", "7" };

uid_t const readUID = geteuid(); /// the effective user ID of the calling process

char readUIDString[16]; /// formatted output conversion
#ifndef NS_BLOCK_ASSERTIONS
size_t l = (size_t)snprintf(readUIDString, sizeof(readUIDString), "%d", readUID);
#else
snprintf(readUIDString, sizeof(readUIDString), "%d", readUID);
#endif

NSAssert(l < sizeof(readUIDString), @"Formatted euid is too long.");
NSAssert(aslLogLevel < (sizeof(level_strings) / sizeof(level_strings[0])), @"Unhandled ASL log level.");

aslmsg m = asl_new(ASL_TYPE_MSG);
if (m != NULL) {
    if (asl_set(m, ASL_KEY_LEVEL, level_strings[aslLogLevel]) == 0 &&
        asl_set(m, ASL_KEY_MSG, msg) == 0 &&
        asl_set(m, ASL_KEY_READ_UID, readUIDString) == 0 &&
        asl_set(m, kDDASLKeyDDLog, kDDASLDDLogValue) == 0) {
        asl_send(_client, m);
    }
    asl_free(m);
}
```



## DDOSLogger

苹果的新一代 logging system [os_log](https://developer.apple.com/documentation/os/logging)，官方提供了比较完整的概述和说明。正是它取代了 ASL，manual 如下：

> The unified logging system provides a single, efficient, high performance set of APIs for capturing log messages across all levels of the system.  This unified system centralizes the storage of log data in memory and in a data store on disk.

它提供了日志记录的中心化存储。同时 API 也十分简洁，关于 os_log 有机会在展开。

### Init

首先，OSLogger 需要持有一个 log object：

```objective-c
os_log_t os_log_create(const char *subsystem, const char *category);
```

**subsystem**

> An identifier string, in reverse DNS notation, that represents the subsystem that’s performing logging, for example, `com.your_company.your_subsystem_name`. The subsystem is used for categorization and filtering of related log messages, as well as for grouping related logging settings.

**category**

> A category within the specified subsystem. The system uses the category to categorize and filter related log messages, as well as to group related logging settings within the subsystem’s settings. A category’s logging settings override those of the parent subsystem.

顺便说一下，os_log 的官方文档是只提供了 Swift 说明，OSLog.Category [详细点此](https://developer.apple.com/documentation/os/oslog/category)。



### LogMessage

同样是过滤 filename 为 `DDASLLogCapture` 的 log message 和对 log message 的 formatter。os_log 所提供的 API 则十分友好简洁，每种 [os_log_type_t](https://developer.apple.com/documentation/kernel/os_log_type_t?language=objc) 都提供了对应的方法，使用如下：

```objective-c
__auto_type logger = [self logger];
switch (logMessage->_flag) {
    case DDLogFlagError  :
        os_log_error(logger, "%{public}s", msg);
        break;
    case DDLogFlagWarning:
    case DDLogFlagInfo   :
        os_log_info(logger, "%{public}s", msg);
        break;
    case DDLogFlagDebug  :
    case DDLogFlagVerbose:
    default              :
        os_log_debug(logger, "%{public}s", msg);
        break;
}
```



## DDTTYLogger

> This class provides a logger for Terminal output or Xcode console output, depending on where you are running your code.

通过它将日志定向到终端和 Xcode 终端，同时支持彩色。Xcode 支持需要添加 [XcodeColors 插件](https://github.com/robbiehanson/XcodeColors)。TTYLogger 内部的代码有上千行。不过所做的事情比较简单。根据不同终端类型所支持的颜色范围来将设置的颜色进行适配，最终输出出来。

关于颜色范围主要有三种类型：

- standard shell：仅支持 16 种颜色
- Terminal.app：可以支持到 256 种颜色
- xterm colors

具体见 [ANSI_escape_code](http://en.wikipedia.org/wiki/ANSI_escape_code)。



### LogMessage

TTYLogger 支持为每一种 logFlag 配置不同的颜色，然后将 color 与 flag 封装进 `DDTTYLoggerColorProfile` 类中，存储在 `_colorProfilesDict` 中。logMessage 主要分三步：

1. 通过 `logMessage->_tag` 取出 colorProfile；
2. 将 log message 转为 c string；
3. 将 color 写入 `iovec v[iovec_len]`，最终调用 `writev(STDERR_FILENO, v, iovec_len);` 输出。



## 未完待续

以上三种 logger 属于基本的终端输出，可用于替代 NSLog。限于篇幅的原因，还有 `DDFileLogger`、`DDAbstractDatabaseLogger` 以及各种扩展，如 `WebSocketLogger` 等，未在本篇出现。同时还有一整节的 `Formatters` 均放下一篇中。

本篇，通过 DDLog 类对 GCD 的使用，看到了 lumberjack 的作者充分利用了 GCD 的特性来达到安全高效的异步 logging。整个过程中并未使用锁来解决线程安全，算是对 GCD 的很好实践了。该作者还出品了 [CocoaAsyncSocket](https://github.com/robbiehanson/CocoaAsyncSocket) 、[XMPPFramework](https://github.com/robbiehanson/XMPPFramework)、[CocoaHTTPServer](https://github.com/robbiehanson/CocoaHTTPServer) 等知名的库。之后可以慢慢细品。

最后，贴一张整理的脑图，比较简单，不喜勿喷。

![CocoaLumberjack.png](http://ww1.sinaimg.cn/large/8157560cly1gdzcfyok9ij21ee12agqs.jpg)