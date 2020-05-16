---
title: "浅析 - CocoaLumberjack 3.6 之 FileLogger"
date: 2020-05-08T23:20:00+08:00
tags: ['Source Code', 'iOS', 'Logger']
categories: ['iOS']
draft: false
author: "土土Edmond木"
---



# DDFileLogger

继续上一篇：[CocoaLumberjack 之 DDLog](https://juejin.im/post/5eafe0796fb9a0438c2550e3#heading-20)，重点介绍了 lumberjack 的核心管理类 DDLog 以及两个核心协议 [DDLogger](https://juejin.im/post/5eafe0796fb9a0438c2550e3#heading-7) 和 [DDLogFormatter](https://juejin.im/post/5eafe0796fb9a0438c2550e3#heading-8)。还涉及了基于 DDLogger 协议的抽象类 [DDAbstractLogger](https://juejin.im/post/5eafe0796fb9a0438c2550e3#heading-15)，以及基于 DDAbstractLogger 派生的分别针对系统日志 API **[ASL](https://opensource.apple.com/source/Libc/Libc-583/include/asl.h.auto.html)** 和 **[os_log](https://developer.apple.com/documentation/os/logging)** 的封装类 [DDASLLogger](https://juejin.im/post/5eafe0796fb9a0438c2550e3#heading-18) 与 [DDOSLogger](https://juejin.im/post/5eafe0796fb9a0438c2550e3#heading-20)。

本文将会继续介绍基于 DDLogger 的应用类 **DDFileLogger**。 



## Log File

关于日志文件，这里贴一下 wiki 描述：

> In [computing](https://www.wikiwand.com/en/Computing), a **log file** is a file that records either [events](https://www.wikiwand.com/en/Event_(computing)) that occur in an [operating system](https://www.wikiwand.com/en/Operating_system) or other [software](https://www.wikiwand.com/en/Software) runs,[[1\]](https://www.wikiwand.com/en/Log_file#citenote1) or messages between different users of a [communication software](https://www.wikiwand.com/en/Internet_chat).

可能部分新手同学对日志文件的重要性没有很强的认识，尤其是移动端。毕竟，我们大部分的时间 force 在 crash log、console log 和 event log 中，而这些 log 基本上是以日志文件来存储。除此之外，我们可能也会主动添加一些关键节点的日志，以方便定位和解决问题。因此，如何保证日志文件的的完整性和准确性就非常重要了。

对于 logging file 简单能联想到的有两点：

1. log message 的文件写入，以及何时进行滚动地记录文件；
2. 日志文件管理，当日志写入结束后需要考虑文件压缩以节约磁盘，以及日志上传。

刚好分别对应了 `DDFileLogger` 主要涉及文件写入，`DDLogFileManager` 负责文件管理。



## Init

先看初始化方式：

```objective-c
- (instancetype)initWithLogFileManager:(id <DDLogFileManager>)logFileManager
                       completionQueue:(nullable dispatch_queue_t)dispatchQueue;
```

作为 NS_DESIGNATED_INITIALIZER，logFileManager 是必须要提供的，如果直接通过 `- (**instancetype**)init` 初始化会主动 new 出 `DDLogFileManagerDefault` 当作默认值。completionQueue 默认为 DEFAULT 优先级，完整实现如下：

```objc
_completionQueue = dispatchQueue ?: dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

_maximumFileSize = kDDDefaultLogMaxFileSize;
_rollingFrequency = kDDDefaultLogRollingFrequency;
_automaticallyAppendNewlineForCustomFormatters = YES;

_logFileManager = aLogFileManager;
_logFormatter = [DDLogFileFormatterDefault new];
```



## [File Rolling](https://www.wikiwand.com/en/Log_rotation)

也称为 log rotation，wiki 解释：

> In [information technology](https://www.wikiwand.com/en/Information_technology), **log rotation** is an automated process used in [system administration](https://www.wikiwand.com/en/System_administration) in which [log files](https://www.wikiwand.com/en/Computer_data_logging) are compressed, moved ([archived](https://www.wikiwand.com/en/Archive)), renamed or deleted once they are too old or too big (there can be other metrics that can apply here). New incoming log data is directed into a new fresh file (at the same location)[[1\]](https://www.wikiwand.com/en/Log_rotation#citenote1).

日志轮替算是系统级别的常规操作策略，在 Linux 中是有专门的命令 [logrotate](https://linux.die.net/man/8/logrotate) 来实现，macOS 上对应的则是 [newsyslog](https://man.freebsd.org/newsyslog.conf/5)。根据 mac manual 文档说明，log 文件的轮替归档需要满足三个条件：

1.   It is larger than the configured size (in kilobytes).
2.   A configured number of hours have elapsed since the log was last archived.
3.   This is the specific configured hour for rotation of the log.

对应 DDFileLogger 中刚好两个属性：

```objective-c
@property (readwrite, assign) unsigned long long maximumFileSize;

@property (readwrite, assign) NSTimeInterval rollingFrequency;
```

lumberjack 中轮替相关的默认值如下：

```objc
/// 默认日志文件 size 上限
unsigned long long const kDDDefaultLogMaxFileSize      = 1024 * 1024; // 1 MB
/// 默认日志文件分割间隔（执行轮替的间隔）
NSTimeInterval     const kDDDefaultLogRollingFrequency = 60 * 60 * 24; // 24 Hours
/// 默认最大日志文件分割数量
NSUInteger         const kDDDefaultLogMaxNumLogFiles   = 5; // 5 Files
/// 默认日志文件整体磁盘配额
unsigned long long const kDDDefaultLogFilesDiskQuota   = 20 * 1024 * 1024; // 20 MB
/// 日志文件滚动计时器更新频率
NSTimeInterval     const kDDRollingLeeway              = 1.0; // 1s
```

对于 `maximumFileSize` 与 `rollingFrequency` ，它们两个条件只要满足一者就会触发 log rolling。需要注意的是，一旦触发 rolling 后，会重置这两个状态。例如：`rollingFrequency` 默认为 24 h，但是 log file 仅在 20 h 的时候就超过了 `maximumFileSize` 限制，那么就会触发 rolling，并重启一个 24 h 的 timer。

如果希望仅按照 `rollingFrequency` 作为控制条件，可以设置 `maximumFileSize` 为 zero。同理，可以设置  `rollingFrequency` 为 zero 来达到 disable 的作用。

另外，rolling 中还提供了 `doNotReuseLogFiles` 来控制，是否允许复用上一次运行时写入的 log file。默认为

 NO，如果设置为 YES，则每启动都会新生成一次 log file。



### lt_maybeRollLogFileDueToSize

先来看看 `rollLogFile by size ` 的情况。当修改 `maximumFileSize` 时会触发 `lt_maybeRollLogFileDueToSize`，`setMaximumFileSize:` 实现如下：

```objective-c
dispatch_block_t block = ^{
    @autoreleasepool {
        self->_maximumFileSize = newMaximumFileSize;
        [self lt_maybeRollLogFileDueToSize];
    }
};
NSAssert(![self isOnGlobalLoggingQueue], @"Core architecture requirement failure");
NSAssert(![self isOnInternalLoggerQueue], @"MUST access ivar directly, NOT via self.* syntax.");

dispatch_queue_t globalLoggingQueue = [DDLog loggingQueue];

dispatch_async(globalLoggingQueue, ^{
    dispatch_async(self.loggerQueue, block);
});
```

最终会在 loggerQueue 中调用 block 以触发 `lt_maybeRollLogFileDueToSize`。上述代码为何要通过两层的 queue 的嵌套以及 loggingQueue 和 loggerQueue 的说明都在上一篇又详细的解释。来看 `lt_maybeRollLogFileDueToSize` 实现：

```objc
NSAssert([self isOnInternalLoggerQueue], @"lt_ methods should be on logger queue.");
if (_maximumFileSize > 0) {
    unsigned long long fileSize = [_currentLogFileHandle offsetInFile];

    if (fileSize >= _maximumFileSize) {
        NSLogVerbose(@"DDFileLogger: Rolling log file due to size (%qu)...", fileSize);

        [self lt_rollLogFileNow];
    }
}
```

1. 首页是断言对 loggerQueue 的环境检查；
2. 作者通过对 `_maximumFileSize > 0` 来控制是否开启 log 大小检查。\_currentLogFileHandle 是当前所写入 log file 的文件操作符（之后简称为 **fd** ：file descriptor）为 `NSFileHandle` 类；
3. 当文件超限时，执行 `lt_rollLogFileNow` ；



### lt_maybeRollLogFileDueToAge

同 `setMaximumFileSize:` 类似，修改 `rollingFrequency` 会在 block 中触发 `lt_maybeRollLogFileDueToAge`：

```objc
NSAssert([self isOnInternalLoggerQueue], @"lt_ methods should be on logger queue.");

if (_rollingFrequency > 0.0 && (_currentLogFileInfo.age + kDDRollingLeeway) >= _rollingFrequency) {
    NSLogVerbose(@"DDFileLogger: Rolling log file due to age...");
    [self lt_rollLogFileNow];
} else {
    [self lt_scheduleTimerToRollLogFileDueToAge];
}
```

同样是检查环境，检查 `_rollingFrequency > 0.0` 以及 log file 的创建时间是否超限。如果轮替时间超限则开始轮替。否则会重置 rollingTimer 下一次轮替的 delay 时间。



### lt_scheduleTimerToRollLogFileDueToAge

这里的定时器使用的是 `  dispatch_source_t` 。首先将当前 timer invalid 然后检查 _currentLogFileInfo 和 _rollingFrequency：

```objc
if (_rollingTimer) {
    dispatch_source_cancel(_rollingTimer);
    _rollingTimer = NULL;
}
if (_currentLogFileInfo == nil || _rollingFrequency <= 0.0) {
    return;
}
```

然后是重新生成 timer 并设置 event handler：

1. 获取文件创建时间，计算下一次轮替的触发时间 logFileRollingDate；

   ```objective-c
   NSDate *logFileCreationDate = [_currentLogFileInfo creationDate];
   NSTimeInterval frequency = MIN(_rollingFrequency, DBL_MAX - [logFileCreationDate timeIntervalSinceReferenceDate]);
   NSDate *logFileRollingDate = [logFileCreationDate dateByAddingTimeInterval:frequency];
   ```

2. 依据 logFileRollingDate 和当前时间计算dely，初始化 _rollingTimer 并设置 evenhandler；

   ```objective-c
   _rollingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _loggerQueue);
   __weak __auto_type weakSelf = self;
   dispatch_source_set_event_handler(_rollingTimer, ^{ @autoreleasepool {
       [weakSelf lt_maybeRollLogFileDueToAge];
   } });
   //... 兼容 MRC，设置 dispatch_source_t release 回调
   ```

3. 设置 kDDRollingLeeway 作为定时器刷新间隔，delay 为触发时间，开始计时；

   ```objc
   static NSTimeInterval const kDDMaxTimerDelay = LLONG_MAX / NSEC_PER_SEC;
   int64_t delay = (int64_t)(MIN([logFileRollingDate timeIntervalSinceNow], kDDMaxTimerDelay) * (NSTimeInterval) NSEC_PER_SEC);
   dispatch_time_t fireTime = dispatch_time(DISPATCH_TIME_NOW, delay);
   
   dispatch_source_set_timer(_rollingTimer, fireTime, DISPATCH_TIME_FOREVER, (uint64_t)kDDRollingLeeway * NSEC_PER_SEC);
   
   if (@available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *))
       dispatch_activate(_rollingTimer);
   else
       dispatch_resume(_rollingTimer);
   ```



### lt_rollLogFileNow

整个 fileLogger 的文件写入操作均基于 fd，而 fd 的获取是通过 lazy 的方式。如果 fd 为空， rollLogFile will do nothing。而日志轮替做的事情也比较清晰：

1. 同步并关闭 fd，同时将文件标记为 **Archived**;
2. 向 fileManger 发送日志轮替通知；
3. 清理 log file 文件变更状态监听，invalid rollingTime；

```objc
if (_currentLogFileHandle == nil) { return; }

[_currentLogFileHandle synchronizeFile];
[_currentLogFileHandle closeFile];
_currentLogFileHandle = nil;

_currentLogFileInfo.isArchived = YES;
BOOL logFileManagerRespondsToSelector = [_logFileManager respondsToSelector:@selector(didRollAndArchiveLogFile:)];
NSString *archivedFilePath = (logFileManagerRespondsToSelector) ? [_currentLogFileInfo.filePath copy] : nil;
_currentLogFileInfo = nil;

if (logFileManagerRespondsToSelector) {
    dispatch_async(_completionQueue, ^{
        [self->_logFileManager didRollAndArchiveLogFile:archivedFilePath];
    });
}

if (_currentLogFileVnode) {
    dispatch_source_cancel(_currentLogFileVnode);
    _currentLogFileVnode = nil;
}

if (_rollingTimer) {
    dispatch_source_cancel(_rollingTimer);
    _rollingTimer = nil;
}
```

 **isArchived** 在 fileInfo 中是如何保存这个状态的呢？

这里利用系统 API [<sys/xattr.h>](https://opensource.apple.com/source/xnu/xnu-1504.15.3/bsd/sys/xattr.h.auto.html) 的 **setxattr**方法将该 flag 直接保存在文件描述中，**getxattr** 用来获取 flag，**removexattr** 用于删除 flag。这个在年初的文章 [《浅析 SDWebImage 5.6》](https://juejin.im/post/5e63d5a9f265da5729789ac3#heading-8) 中也提到过，SD 也是用它来存储额外信息的。



## DDLogFileInfo

前面的代码中已经接触过部分 fileInfo 的 property 了，正式介绍一下：

> A simple class that provides access to various file attributes. It provides good performance as it only fetches the information if requested, and it caches the information to prevent duplicate fetches.

可以说 fileInfo 是保存了 log file 的首次访问时的快照，它追求的是性能而非时时性。最关键的属性是 fileAttributes

```objc
@property (strong, nonatomic, readonly) NSDictionary<NSFileAttributeKey, id> *fileAttributes;
```

像 `creationDate`、`modificationDate`、`fileSize`、`age` 均通过 **NSFileAttributeKey** 从它这获取的。既然是 lazy 又不更新，fileLogger 又是通过什么方式来准确获取真正的 fileSize 和增量更新 log file 呢？答案是 **file descriptor**：

| method |desc |
| --------------- | --------------- |
| offsetInFile    | 获取文件大小 |
| synchronizeFile | 内存数据写入磁盘 |
| closeFile       |关闭文件 |
| seekToEndOfFile |将文件指针移动的末尾 |

可见 fileLogger 始终通过唯一的 **fd** 来操作文件，从而提高读写效率。当然，还有更快的就是使用 mmap，像美团的 logan 和微信的 xlog。

最后，对于 **setxattr**、**getxattr**、**removexattr** 操作 fileInfo 提高了 convene method：

```objc
- (BOOL)hasExtendedAttributeWithName:(NSString *)attrName;
- (void)addExtendedAttributeWithName:(NSString *)attrName;
- (void)removeExtendedAttributeWithName:(NSString *)attrName;
```



## DDLogger Protocol

### logMessage:

将 log message 写入文件，经过 `lt_dataForMessage` 将 log mesage 转化为 NSData，最终调用 `lt_logData:`。



### flush

先经过 loggingQueue 和 loggerQueue 最终调用 block 内部的 `lt_flush`，而 `lt_flush` 就一行代码：

```objc
[_currentLogFileHandle synchronizeFile];
```



### lt_logData

将 log message 转化过的 NSData 写入 file，代码如下：

```objective-c
@try {
    NSFileHandle *handle = [self lt_currentLogFileHandle];
    [handle seekToEndOfFile];
    [handle writeData:data];
} @catch (NSException *exception) {
    exception_count++;
    if (exception_count <= 10) {
        NSLogError(@"DDFileLogger.logMessage: %@", exception);
        if (exception_count == 10) {
            NSLogError(@"DDFileLogger.logMessage: Too many exceptions -- will not log any more of them.");
        }
    }
}
```

核心代码就三行，但是可以看到 lumberjack 的容错做的真心好，当异常数过多，就不停止输出了。

剩下的代码是对 deprecated 的 API 的兼容，算是目前看过对 deprecated API 十分友好的 lib 了。

首先对旧的 `willLogMessage` 和 `didLogMessage` 而言，新提供的 API 是增加了 fileInfo 作为返回值。然后用 `dispatch_once_t` 来避免多次响应者查询，以优化代码，毕竟 logMessage 可是一个高频调用的 API。

```objc
static BOOL implementsDeprecatedWillLog = NO;

static dispatch_once_t onceToken;
dispatch_once(&onceToken, ^{
implementsDeprecatedWillLog = [self respondsToSelector:@selector(willLogMessage)];
});

if (implementsDeprecatedWillLog) {
    [self willLogMessage];
} else {
    [self willLogMessage:_currentLogFileInfo];
}
```

同时还利用消息转发，将过期方法转移至 dummyMethod 避免 `unrecognized selector sent to instance` crash

```objective-c
- (void)dummyMethod {}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    if (aSelector == @selector(willLogMessage) || aSelector == @selector(didLogMessage)) {
        // Ignore calls to deprecated methods.
        return [self methodSignatureForSelector:@selector(dummyMethod)];
    }
    return [super methodSignatureForSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    if (anInvocation.selector != @selector(dummyMethod)) {
        [super forwardInvocation:anInvocation];
    }
}
```



## File Logging

整个 file logging 相关方法是对 fileHandle 和 fileInfo 的各种状态判断以及更新。

### lt_currentLogFileHandle

_currentLogFileHandle 通过 layze 方式获取。当 `lt_rollLogFileNow` 成功后会将 _currentLogFileHandle 置 nil。创建逻辑如下：

```objective-c
NSString *logFilePath = [[self lt_currentLogFileInfo] filePath];
_currentLogFileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
[_currentLogFileHandle seekToEndOfFile];

if (_currentLogFileHandle) {
    [self lt_scheduleTimerToRollLogFileDueToAge];
    [self lt_monitorCurrentLogFileForExternalChanges];
}
```

1. 通过 `lt_currentLogFileInfo` 获取 filePath 生成 _currentLogFileHandle 并将文件指针置文章末尾；
2. 创建成功后重置 rolling 定时器，并开启 GCD 监听 _currentLogFileHandle； 



### lt_monitorCurrentLogFileForExternalChanges

 先是 _currentLogFileHandle 是否为空的断言，接着是设置 `dispatch_source_vnode_flags_t` 添加 event handler 回调：

```objc
dispatch_source_vnode_flags_t flags = DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE;
_currentLogFileVnode = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)[_currentLogFileHandle fileDescriptor], flags, _loggerQueue);

__weak __auto_type weakSelf = self;
dispatch_source_set_event_handler(_currentLogFileVnode, ^{ @autoreleasepool {
    NSLogInfo(@"DDFileLogger: Current logfile was moved. Rolling it and creating a new one");
    [weakSelf lt_rollLogFileNow];
} });
//... 兼容 MRC，设置 dispatch_source_t release 回调

if (@available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *))
    dispatch_activate(_currentLogFileVnode);
else
    dispatch_resume(_currentLogFileVnode);
```



### lt_currentLogFileInfo

获取当前是否存在可用的 fileInfo。检查条件如下：

1. 取出 `logsDirectory` 中的 log 文件列表，并转化为 DDLogFileInfo。文件需要满足以 `.log` 结尾；
2. 对转化后的 fileInfo 进行排序，取出最近时间的做为 `newCurrentLogFile`；
3. 如果 `newCurrentLogFile` 存在，检查其可用性。如不可用则会通过 fileManger 创建新的 fileInfo；

实现这里就不贴出了，接着来看检查条件。



### lt_shouldUseLogFile: isResuming

isResuming 是从对上一步 `newCurrentLogFile` 可用性的判断中传入的参数：

```objc
// Check if we're resuming and if so, get the first of the sorted log file infos.
BOOL isResuming = newCurrentLogFile == nil;
```

1. 先判定文件是否为已归档文件，已归档则不可用；

2. 如果 `isResuming` 为 YES，即 fileInfo 是从磁盘文件中复用的，需要检查两个状态：

   1. `_doNotReuseLogFiles` 是否允许复用上次运行的 log file；
   2. 通过 `lt_shouldLogFileBeArchived` 检查检查文件归档状态；

   一旦，_doNotReuseLogFiles 为 YES 或 文件已满足归档条件，则设置 `logFileInfo.isArchived = YES`，并通知 fileManager。

3. 满足条件返回 YES；



### lt_shouldLogFileBeArchived

```objective-c
if (mostRecentLogFileInfo.isArchived) {
    return NO;
} else if ([self shouldArchiveRecentLogFileInfo:mostRecentLogFileInfo]) {
    return YES;
} else if (_maximumFileSize > 0 && mostRecentLogFileInfo.fileSize >= _maximumFileSize) {
    return YES;
} else if (_rollingFrequency > 0.0 && mostRecentLogFileInfo.age >= _rollingFrequency) {
    return YES;
}
#if TARGET_OS_IPHONE
    if (doesAppRunInBackground()) {
        NSFileProtectionType key = mostRecentLogFileInfo.fileAttributes[NSFileProtectionKey];
        BOOL isUntilFirstAuth = [key isEqualToString:NSFileProtectionCompleteUntilFirstUserAuthentication];
        BOOL isNone = [key isEqualToString:NSFileProtectionNone];

        if (key != nil && !isUntilFirstAuth && !isNone) {
            return YES;
        }
    }
#endif
return NO;
```

当 mostRecentLogFileInfo 不满足前四步检查，需要判断 App 是否在后台运行，并根据 NSFileProtectionKey 确认 log file 的读写权限。`doesAppRunInBackground` 通过 mainBundle 的 `UIBackgroundModes` 来获取。

为何要加这个判定条件呢？这就需要关注 log file 生成时说起。创建 log file 时会设置 logFileProtection。

```objc
- (NSFileProtectionType)logFileProtection {
    if (_defaultFileProtectionLevel.length > 0) {
        return _defaultFileProtectionLevel;
    } else if (doesAppRunInBackground()) {
        return NSFileProtectionCompleteUntilFirstUserAuthentication;
    } else {
        return NSFileProtectionCompleteUnlessOpen;
    }
}
```

**NSFileProtectionCompleteUnlessOpen** 

当设备被锁定时，各文件仍然能够进行创建，而已经打开的文件则可继续接受访问。利用这一机制，我们可以在后台完成各类相关任务——例如保存新数据或者更新数据库。

 **NSFileProtectionCompleteUntilFirstUserAuthentication**

当设备引导完成后，对应文件可在用户输入密码后随时接受访问——即使是在设备被锁定的情况下。利用这种方式，您可以随时读取运行在后台的文件。

也就是说，App 运行在前台时，通过 NSFileProtectionCompleteUnlessOpen 来获取更多权限，而在后台则需要使用 NSFileProtectionCompleteUntilFirstUserAuthentication 来修饰。因此，当我们在后台的情况下从磁盘中恢复的 log file 却是 App 在前台的时候所生成的话，由于权限不同，我们只能将其 Archive 来重新生成新的 log file。



# DDLogFileManager

fileManger 有对应一个的 protocol

```objective-c
@protocol DDLogFileManager <NSObject>
@required

@property (readwrite, assign, atomic) NSUInteger maximumNumberOfLogFiles;
@property (readwrite, assign, atomic) unsigned long long logFilesDiskQuota;
@property (nonatomic, readonly, copy) NSString *logsDirectory;
@property (nonatomic, readonly, strong) NSArray<NSString *> *unsortedLogFilePaths;
@property (nonatomic, readonly, strong) NSArray<NSString *> *unsortedLogFileNames;
@property (nonatomic, readonly, strong) NSArray<DDLogFileInfo *> *unsortedLogFileInfos;
@property (nonatomic, readonly, strong) NSArray<NSString *> *sortedLogFilePaths;
@property (nonatomic, readonly, strong) NSArray<NSString *> *sortedLogFileNames;
@property (nonatomic, readonly, strong) NSArray<DDLogFileInfo *> *sortedLogFileInfos;

- (nullable NSString *)createNewLogFileWithError:(NSError **)error;

@optional
- (void)didArchiveLogFile:(NSString *)logFilePath NS_SWIFT_NAME(didArchiveLogFile(atPath:));
- (void)didRollAndArchiveLogFile:(NSString *)logFilePath NS_SWIFT_NAME(didRollAndArchiveLogFile(atPath:));

@end
```

其默认实现类为 DDLogFileManagerDefault。



## DDLogFileManagerDefault

所有创建的 logFile 都存储在 `logsDirectory` 目录下，文件名称格式为 **\<bundle identifier> \<date> \<time>.log** ，例如:  `com.organization.myapp 2020-05-09 17-14.log` ，目录在 Mac 上为 `~/Library/Logs/<Application Name>`。iPhone 上为  `~/Library/Caches/Logs`。

managerDefault 基本围绕着 `_logsDirectory` 目录来管理文件。对其目录下的文件的基本操作等，这里不展开了。稍微提一点 `maximumNumberOfLogFiles`  和 `logFilesDiskQuota` 的控制是通过 KVO 来实现监听的。它们最终会触发 `deleteOldLogFiles` 。



### deleteOldLogFiles

由于是 I/O 操作，整个代码是放在 GCD 中以 `PRIORITY_DEFAULT` 执行的。基本逻辑如下：

1. 取出 log file 文件名中的 date 字符转为 date (转换失败则尝试从 fileAttributes 中获取)，然后进行排序。

2. 计算 `logsDirectory` 目录下的所有 log 文件 size，并标记首个超出限制的文件 index；

   ```objc
   unsigned long long used = 0;
   for (NSUInteger i = 0; i < sortedLogFileInfos.count; i++) {
      DDLogFileInfo *info = sortedLogFileInfos[i];
      used += info.fileSize;
   
      if (used > diskQuota) {
          firstIndexToDelete = i;
          break;
      }
   }
   ```

3. 对比 `maxNumLogFiles` 和 `firstIndexToDelete` 最终确定要删除的文件范围：

   ```objc
   if (maxNumLogFiles) {
        if (firstIndexToDelete == NSNotFound) {
            firstIndexToDelete = maxNumLogFiles;
        } else {
            firstIndexToDelete = MIN(firstIndexToDelete, maxNumLogFiles);
        }
    }
   ```

4. 如果 firstIndexToDelete 为第一个文件，仅仅删除第一个且未标记为 **isArchived** 的文件。

5. 最后遍历 `sortedLogFileInfos` 从 `firstIndexToDelete` 开始删除。



## DDLogFileFormatterDefault

fileLogger 中的 fileFormatter 仅仅是在每条 log message 前添加了 _timestamp 的前缀。




#  Buffering

lumberjack 为 DDFileLogger 提供了 buffer 的分类，通过 NSProxy 来实现的，用法也一如既往的简单：

```objc
[DDLog addLogger:[_logger wrapWithBuffer]];
```

通过 `wrapWithBuffer` 返回的是 `DDBufferedProxy` 类：

```objc
(DDFileLogger *)[[DDBufferedProxy alloc] initWithFileLogger:self];
```

接着利用 **Message Forwarding** 将 DDBufferedProxy 未代理的方法通通转发回 fileLogger 处理：

```objective-c
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [self.fileLogger methodSignatureForSelector:sel];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [self.fileLogger respondsToSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:self.fileLogger];
}
```

作为 buffer 声明了哪些属性呢？ 

```objective-c
@interface DDBufferedProxy : NSProxy

@property (nonatomic) DDFileLogger *fileLogger;
@property (nonatomic) NSOutputStream *buffer;
@property (nonatomic) NSUInteger maxBufferSizeBytes;
@property (nonatomic) NSUInteger currentBufferSizeBytes;

@end
```

是的，BufferProxy 正是通过 `NSOutputStream` 将 log message 优先写入 memory 的方式作为过渡。那这 buffer  的预设值是多少呢 ？

```objective-c
static const NSUInteger kDDDefaultBufferSize = 4096; // 4 kB, block f_bsize on iphone7
static const NSUInteger kDDMaxBufferSize = 1048576; // ~1 mB, f_iosize on iphone7
```

这两个默认值是基于 iPhone 7 上的 buffer size 来决定的。真实值取自 [<sys/mount.h>](https://github.com/mstg/iOS-full-sdk/blob/master/iPhoneOS9.3.sdk/usr/include/sys/mount.h) API：

```objective-c
static inline NSUInteger p_DDGetDefaultBufferSizeBytesMax(const BOOL max) {
    struct statfs *mountedFileSystems = NULL;
    int count = getmntinfo(&mountedFileSystems, 0);

    for (int i = 0; i < count; i++) {
        struct statfs mounted = mountedFileSystems[i];
        const char *name = mounted.f_mntonname;

        // We can use 2 as max here, since any length > 1 will fail the if-statement.
        if (strnlen(name, 2) == 1 && *name == '/') {
            return max ? (NSUInteger)mounted.f_iosize : (NSUInteger)mounted.f_bsize;
        }
    }

    return max ? kDDMaxBufferSize : kDDDefaultBufferSize;
}
```

核心是根据当前已挂载的文件系统的 **f_iosize** 和 **f_bsize**：

- f_iosize: 最佳传输 block 大小；
- f_bsize: 基础文件系统 block 大小；

读取不到的话就是基于 iPhone 7 提供的默认值作为 defaultBufferSize 和 maxBufferSize。

```objc
static NSUInteger DDGetMaxBufferSizeBytes() {
    static NSUInteger maxBufferSize = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        maxBufferSize = p_DDGetDefaultBufferSizeBytesMax(YES);
    });
    return maxBufferSize;
}

static NSUInteger DDGetDefaultBufferSizeBytes() {
    static NSUInteger defaultBufferSize = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultBufferSize = p_DDGetDefaultBufferSizeBytesMax(NO);
    });
    return defaultBufferSize;
}
```



## Life Cycle

### 初始化

```objc
_fileLogger = fileLogger;
_maxBufferSizeBytes = DDGetDefaultBufferSizeBytes();
[self flushBuffer];
```

初始化时，保存 fileLogger 引用，获取默认 bufferSize 以及刷新 outputStream。



### flushBuffer

```objc
[_buffer close];
_buffer = [NSOutputStream outputStreamToMemory];
[_buffer open];
_currentBufferSizeBytes = 0;
```

通过 `outputStreamToMemory` 创建一个直接将所写入的数据写到内存中。用 `_currentBufferSizeBytes` 记录当前所占用内存的大小。



### dealloc

为了保证数据完整性，在生命周期结束后会主动将数据写回 fileLogger 中，以期最终能写入 log file。

```objc
dispatch_block_t block = ^{
     [self lt_sendBufferedDataToFileLogger];
     self.fileLogger = nil;
 };

 if ([self->_fileLogger isOnInternalLoggerQueue]) {
     block();
 } else {
     dispatch_sync(self->_fileLogger.loggerQueue, block);
 }
```



### lt_sendBufferedDataToFileLogger

写回 fileLogger 则是将 buffer 中的 data 取出，然后调用 `lt_logData` 写入 fileLogger，最后 flushBuffer。

```objc
NSData *data = [_buffer propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
[_fileLogger lt_logData:data];
[self flushBuffer];
```



## Logging

bufferProxy 拦截了这两个方法 `logMessage` 和 `flush`，其余的都通过 message forwarding 转回 filgLogger了。

### logMessage

例行检查和 fileLogger 中的一样，而 logMessage 方法主要作用是将 log message 转化为 NSData 再调用 `lt_logData`。对 buffer 而言则是将 NSData 以 byteStream 的方式写入 outputStream。

```objc
[data enumerateByteRangesUsingBlock:^(const void * __nonnull bytes, NSRange byteRange, BOOL * __nonnull __unused stop) {
    NSUInteger bytesLength = byteRange.length;
#ifdef NS_BLOCK_ASSERTIONS
    __unused
#endif
    NSInteger written = [_buffer write:bytes maxLength:bytesLength];
    NSAssert(written > 0 && (NSUInteger)written == bytesLength, @"Failed to write to memory buffer.");

    _currentBufferSizeBytes += bytesLength;

    if (_currentBufferSizeBytes >= _maxBufferSizeBytes) {
        [self lt_sendBufferedDataToFileLogger];
    }
}];
```

会不断地将 data 写入 buffer，如果满了就写入 log file 并 flushBuffer。通过这种方式，有效的减小了文件写入的 I/O 操作。



### flush

flush 为了及时将 buffer 等缓存数据及时写入，防止应用被主动退出或 Crash 时数据丢失。作为 Public method 还是再强调一下，它在执行前依旧需要进行 loggingQueue 和 loggerQueue 的检查，之后才是核心代码。

```objc
dispatch_block_t block = ^{
adispatch_block_t block = ^{
    @autoreleasepool {
        [self lt_sendBufferedDataToFileLogger];
        [self.fileLogger flush];
    }
};
```



#  总结

通过对 DDFileLogger 源码的浅尝，能够强烈感受到作者扎实的基础能力。例如使用 NSFileHandle 来操作 file 的增量写入，使用 dispatch_source_t 来实现 timer 的 delay 功能，以及利用 dispatch_source_t 来监听 NSFileHandle 的 change 等都体现了作者对 GCD 的熟悉和掌控能力，包括上一篇中的 queue 的使用。除了这些实现细节之外，作者对 file rolling 等日志监控的相关概念的实现都有不错的理解。最后整个框架则对 deprecated API 有着较好的兼容，确实是名副其实的高性能。

总之，收获颇多。



### 未完待续

DDLogger 中至少还会有一篇的 blog 是关于 `DDAbstractDatabaseLogger` 分析。之后可能会有相关日志组件的横向对比，但是 lumberjack 是真的超乎我想象的优先开源实现。

