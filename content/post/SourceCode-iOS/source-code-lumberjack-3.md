---
title: "浅析 - CocoaLumberjack 3.6 之 DatabaseLogger"
date: 2020-05-16T00:00:00+08:00
tags: ['Source Code', 'iOS', 'Logger']
categories: ['iOS']
draft: false
author: "土土Edmond木"
---



## 前言
这是 DDLog 源码阅读的最后一篇。本篇重点介绍 DDLogger 对数据库存储的支持，原理应该和 FileLogger 一样，log 磁盘存储的频率，过期 log 的淘汰策略，以及 log 存储的缓存策略等。

开始之前，建议大家回顾前两篇文章，很多基本的概念本篇会直接忽略。

上篇：[《浅析 CocoaLumberjack 之 DDLog》](https://juejin.im/post/5eafe0796fb9a0438c2550e3)

中篇：[《浅析 CocoaLumberjack 之 FileLogger》](https://juejin.im/post/5eb6dc6bf265da7bf1691c13)



# DDAbstractDatabaseLogger

作为抽象类，你可以自由的根据项目所使用的数据库类型来提供具体的子类实现。DDLog 在 Demo 中提供了 FMDBLogger 和 CoreDataLogger 的实践，会在后面稍微介绍。 因此，dbLogger 主要是保证 log entify (message 对应的 SQL) 的读写策略。来看几个暴露 property 的声明，先来看第一组：

```objc
@property (assign, readwrite) NSUInteger saveThreshold; // 500
@property (assign, readwrite) NSTimeInterval saveInterval; // 60s
```

这两个是用于控制 entities 写入磁盘的频率。毕竟我们不能针对每一条 log 都执行 SQL 插入语句 (I/O 操作）。

- saveThreshold：当前未处理 entities 数量的阈值，默认 500 条；
- saveInterval：执行下一次写入的时间间隔；

我们可以通过将这两个的值归零的方式来表示🈲️止对应的控制。当然，这里不建议将两个值都置零。



另外三个主要用于控制已保存 entities 的清除频率，毕竟我们可不愿用户发现磁盘被我们给写满了。

```objc
@property (assign, readwrite) NSTimeInterval maxAge; // 7 day
@property (assign, readwrite) NSTimeInterval deleteInterval; // 5 min
@property (assign, readwrite) BOOL deleteOnEverySave; // NO
```

- maxAge：日志最多保留时长，默认为 7 天；
- deleteInterval：过期日志删除的频率，默认为 5 分钟；
- deleteOnEverySave：另外一个可选项，用于控制每次日志写入时，是否需要进行过期日志的清除。

同样，`maxAge` 和 `deleteInterval` 也可通过置零来 disable 其功能。



## Timer 的生命周期

既然是跟踪日志的写入和擦除，timer 是少不了的。dbLogger 分别针对 save 和 delete 操作都分配了一个 `dispatch_source_t`  作为 timer。对应的创建、更新、销毁的方法如下：

|           Save           |          Delete           |
| :----------------------: | :-----------------------: |
| createSuspendedSaveTimer | createAndStartDeleteTimer |
| updateAndResumeSaveTimer |     updateDeleteTimer     |
|     destroySaveTimer     |    destroyDeleteTimer     |



### createSuspendedSaveTimer

SaveTimer 在执行 log 写入操作的时候会先暂停，在写入结束后重新恢复计时。这里 DDLog 使用了 **_saveTimerSuspended** 作为标识 (为 NSInteger 类型) ，标记 timer 的状态。

```objc
if ((_saveTimer == NULL) && (_saveInterval > 0.0)) {
    _saveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.loggerQueue);

    dispatch_source_set_event_handler(_saveTimer, ^{ 
        @autoreleasepool { [self performSaveAndSuspendSaveTimer]; } 
    });
    _saveTimerSuspended = -1;
}
```

- `_saveInterval > 0.0` 表明开启了 ⏲️ 检查 log 写入任务；
- 为 timer 设置了定时回调 `performSaveAndSuspendSaveTimer` ；



**_saveTimerSuspended**  的值有三种类型，分别对应 dispatch_source_t 的三个状态：

| value |          description           |
| :---: | :----------------------------: |
|  -1   | 创建时的初始状态： inactivited |
|   0   | 被激活状态：actived / resumed  |
|   1   |     被挂起状态：suspended      |

所以 timer 被 create 时是处于未激活的暂停状态。



### updateAndResumeSaveTimer

激活或恢复 SaveTimer，恢复前会检查 **_unsavedTime** 是否大于 0，`_unsavedTime` 为每次执行 **logMessage** 时所记录的当前时间。`_unsavedTime` 也就是 timer 恢复的 startTime。

```objc
if ((_saveTimer != NULL) && (_saveInterval > 0.0) && (_unsavedTime > 0)) {
    uint64_t interval = (uint64_t)(_saveInterval * (NSTimeInterval) NSEC_PER_SEC);
    dispatch_time_t startTime = dispatch_time(_unsavedTime, (int64_t)interval);

    dispatch_source_set_timer(_saveTimer, startTime, interval, 1ull * NSEC_PER_SEC);
    //... 激活 timer
}
```

激活计时器会重置 timer 的 startTime 和 interval。

恢复 timer 的逻辑，这里对不同版本的 GCD API 做了兼容性的适配。在 **macOS 10.12, iOS 10.0** 之后，新出了 **dispatch_activate** API 区别于原有的 **dispatch_resume**。这里面有一个坑需要注意一下，先来看看这两个方法的文档描述：



**dispatch_activate**

> Suspends the invocation of blocks on a dispatch object.

新生成的 queue 或 source 默认为 inactive 状态，它们必须设置为 active 后其关联的 event handler 才可能被invoke。

对于未激活的 dispatch objc 我们可以通过 `dispatch_set_target_queue()` 来更新初始化时绑定的  queue，一旦为 active 话，这么做就可能导致 crash，坑点 1。另外，dispatch_activate 对已激活的 dispatch objc 是没有副作用的。



**dispatch_resume**

> Resumes the invocation of blocks on a dispatch object.

dispatch source 通过 `dispatch_suspend()` 时，会增加内部的 suspension count，resume 则是相反操作。当 suspension count 清空后，注册的 event handler 才能被再次触发。

为了向后兼容，对于 inactive 的 source 调用 dispatch_resume 的效果与 dispatch_active 一致。对于 inactive 的  source 建议使用 dispatch_activate 来激活。

如果对 suspension count 为 0 且为 inactive 状态的 source 执行 dispatch_resume，则会触发断言被强制退出。



激活 Timer 实现如下，所以下面这段代码对不同版本的 timer 的不同状态做了区分。

```objc
if (@available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)) {
    if (_saveTimerSuspended < 0) { /// inactive
        dispatch_activate(_saveTimer);
        _saveTimerSuspended = 0;
    } else if (_saveTimerSuspended > 0) { /// active
        dispatch_resume(_saveTimer);
        _saveTimerSuspended = 0;
    }
} else {
    if (_saveTimerSuspended != 0) { /// inactive
        dispatch_resume(_saveTimer);
        _saveTimerSuspended = 0;
    }
}
```



### destroySaveTimer

销毁 timer。首先执行 `dispatch_source_cancel` 将 timer 标记为 cacneled 以取消之后的 event handler 的执行。之后将 timer 状态标记为 actived，否则在 release inactive 的 source 会导致 crash。

```objc
if (@available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *)) {
    if (_saveTimerSuspended < 0) {
        dispatch_activate(_saveTimer);
    } else if (_saveTimerSuspended > 0) {
        dispatch_resume(_saveTimer);
    }
} else {
    if (_saveTimerSuspended != 0) {
        dispatch_resume(_saveTimer);
    }
}
```

最后释放：

```objc
#if !OS_OBJECT_USE_OBJC
dispatch_release(_saveTimer);
#endif
_saveTimer = NULL;
_saveTimerSuspended = 0;
```



### createAndStartDeleteTimer

Delete Timer 的逻辑就比较简单一些。由于 log 清除的逻辑不需要像写入一样，在每次 logMessage 的时候都重新更新 startTime 并恢复为 active 状态。同时 Delete Timer 在初始化的时候就保证了其为 active 状态。所以 Delete Timer 在 update 的时候，也不需要再确保状态为 active。

```objc
if ((_deleteTimer == NULL) && (_deleteInterval > 0.0) && (_maxAge > 0.0)) {
    _deleteTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.loggerQueue);

    if (_deleteTimer != NULL) {
        dispatch_source_set_event_handler(_deleteTimer, ^{ 
           @autoreleasepool { [self performDelete]; } 
        });

        [self updateDeleteTimer];

        if (@available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *))
            dispatch_activate(_deleteTimer);
        else
            dispatch_resume(_deleteTimer);
    }
}
```



### updateDeleteTimer

更新 Delete Timer 时，会检查是否执行过一次清除操作。如果有，会以上次清楚的时间戳作为 startTime。

```objc
if ((_deleteTimer != NULL) && (_deleteInterval > 0.0) && (_maxAge > 0.0)) {
    int64_t interval = (int64_t)(_deleteInterval * (NSTimeInterval) NSEC_PER_SEC);
    dispatch_time_t startTime;

    if (_lastDeleteTime > 0) {
        startTime = dispatch_time(_lastDeleteTime, interval);
    } else {
        startTime = dispatch_time(DISPATCH_TIME_NOW, interval);
    }

    dispatch_source_set_timer(_deleteTimer, startTime, (uint64_t)interval, 1ull * NSEC_PER_SEC);
}
```



### destroyDeleteTimer

```objc
if (_deleteTimer != NULL) {
    dispatch_source_cancel(_deleteTimer);
    #if !OS_OBJECT_USE_OBJC
    dispatch_release(_deleteTimer);
    #endif
    _deleteTimer = NULL;
}
```



## Configuration

dbLogger 对写入和清除操作控制策略的属性进行了重载。这几个 Access 方法的 getter 和 setter 都是线程安全的，它们都是在 loggingQueue 和  loggerQueue 中来执行操作的，具体可以看 [DDLog 上篇](https://juejin.im/post/5eafe0796fb9a0438c2550e3)。getter 只是取值，因此这里主要聊聊，其值更新时有哪些操作。



### setSaveThreshold

更新 saveThreshold 后，需要检查当前未写入的 entities 数是否超过新赋值的阈值。如果超出需要主动执行写入操作并更新 SaveTimer：

```objc
if ((self->_unsavedCount >= self->_saveThreshold) && (self->_saveThreshold > 0)) {
    [self performSaveAndSuspendSaveTimer];
}
```



### setSaveInterval

更新下一次执行 log entries 的时间间隔。**又出现新知识点了**，这里作者使用了 **[islessgreater](https://en.cppreference.com/w/c/numeric/math/islessgreater)** 宏来判断 saveInterval 是否有变化。这个 islessgreater 是 C99 标准中推荐的浮点数比较的宏:

> The built-in operator< and operator> for floating-point numbers may raise [FE_INVALID](https://en.cppreference.com/w/c/numeric/fenv/FE_exceptions) if one or both of the arguments is NaN. This function is a "quiet" version of the expression x < y || x > y. The macro does not evaluate x and y twice.

使用它能避免因为值为 NaN 而出现的异常。关于浮点数的对比，这里有一篇不错的文章：[comparison](https://floating-point-gui.de/errors/comparison/)。

由于 saveInterval 是否为 0 是用于控制定时写入功能，因此，更新后有三种情况需要处理：

```objc
if (self->_saveInterval > 0.0) {
    if (self->_saveTimer == NULL) {

        [self createSuspendedSaveTimer];
        [self updateAndResumeSaveTimer];
    } else {

        [self updateAndResumeSaveTimer];
    }
} else if (self->_saveTimer) {

    [self destroySaveTimer];
}
```

- 需要开启定时写入且 timer 为 NULL；需要创建 SaveTimer 并激活它；
- 需要开启定时写入且 timer 存在；激活并恢复 SaveTimer；
- 无需定时写入：销毁 Timer；



### setMaxAge

maxAge 的情况更多一些，有四种 case。在更新 maxAge 前，保留了旧值用于对比，同样用到了 islessgreater。

```objc
BOOL shouldDeleteNow = NO;

if (oldMaxAge > 0.0) {
    if (newMaxAge <= 0.0) { /// 1
        [self destroyDeleteTimer];
       
    } else if (oldMaxAge > newMaxAge) {
        shouldDeleteNow = YES; /// 4
    }
} else if (newMaxAge > 0.0) {
    shouldDeleteNow = YES; /// 2
}

if (shouldDeleteNow) {
    [self performDelete];

    if (self->_deleteTimer) {
        [self updateDeleteTimer];
    } else {
        [self createAndStartDeleteTimer];
    }
}
```

1. maxAge 检查从开启变为关闭状态，此时只需要销毁 Delete Timer；
2. maxAge 检查从关闭变为开启状态，需要立即清理过期日志，并初始化 Delete Timer 
3. 日志保留时长增加，do nothing；
4. 日志保留时长减少，需要立即清理；



### setDeleteInterval

deleteInterval 同 saveInterval 对 timer 的操作逻辑相同，就不展开了。



## Save & Delete

既然做为抽象类，肯定需要有几个方法暴露给子类去实现，要不就是通过 protocol 让 delegate 去实现。这里 ddLogger 预留了四个虚方法：

```objc
- (BOOL)db_log:(__unused DDLogMessage *)logMessage {
	// Return YES if an item was added to the buffer.
	// Return NO if the logMessage was ignored.
	return NO;
}
- (void)db_save {}
- (void)db_delete {}
- (void)db_saveAndDelete {}
```



### Public API

dbLogger 为用户主动执行写入和清除提供了两个方法 **savePendingLogEntries** 和 **deleteOldLogEntries**。

作为 logger 的公共方法，其执行必须在 loggerQueue 中，以 `savePendingLogEntries` 为例：

```objc
dispatch_block_t block = ^{
     @autoreleasepool {
         [self performSaveAndSuspendSaveTimer];
     }
 };

 if ([self isOnInternalLoggerQueue]) {
     block();
 } else {
     dispatch_async(self.loggerQueue, block);
 }
```

`performSaveAndSuspendSaveTimer` 则是其对应的 private method，同样的 `deleteOldLogEntries` 对应的 private method 为 `performDelete` 。



### performSaveAndSuspendSaveTimer

从方法名可知这里做了两件事：执行日志写入和挂起 SaveTimer。

写入前确保存在未写入日志，然后依据 _deleteOnEverySave 区分是否需要在每次写入的同时进行清楚操作：

```objc
if (_unsavedCount > 0) {
    if (_deleteOnEverySave) {
        [self db_saveAndDelete];
    } else {
        [self db_save];
    }
}
/// 写入结束重置状态；
_unsavedCount = 0;
_unsavedTime = 0;
```

接着将 timer 挂起，等待下一次的 logMessage 以刷新 timer：

```objc
if (_saveTimer != NULL && _saveTimerSuspended == 0) {
    dispatch_suspend(_saveTimer);
    _saveTimerSuspended = 1;
}
```

需要注意，这里使用 **_saveTimerSuspended** 作为标记，防止多次执行 **dispatch_suspend** 操作，同时也保证了 source 是处于 active 状态。前面在 dispatch source 的状态变更中提到，source 内部维护一个 suspension count，多次执行会导致 count 增大。这里算是一鱼多吃了，👍。



### performDelete

```objc
if (_maxAge > 0.0) {
    [self db_delete];

    _lastDeleteTime = dispatch_time(DISPATCH_TIME_NOW, 0);
}
```

开启清楚操作的话就执行 delete，结束后更新 `_lastDeleteTime`。



## DDLogger

在遵循 DDLogger 的方法中基本也是维护 timer 的状态，触发 save 操作。



### didAddLogger

```objc
[self createSuspendedSaveTimer];
[self createAndStartDeleteTimer];
```



### willRemoveLogger

```objc
[self performSaveAndSuspendSaveTimer];

[self destroySaveTimer];
[self destroyDeleteTimer];
```



### logMessage

```objc
if ([self db_log:logMessage]) { /* 更新 save timer */  }
```

logMessage 方法是用户产生 new log 所触发的，包含了关键的 log message。在 FileLogger 中时将 message 转换为 NSData 调用 `lt_logData` 来写入文件，而这里则会将 message 转换为 log entity 以期写入 DB 中。**db_log** 所做的真是和 `lt_logData` 一致的。

不过这里留了一个开关，就是 db_log 的返回值。如果返回 NO 则意味着改条 log 被丢弃，我们也不需要更新 timer 的 startTime 或者触发 save 操作。

更新逻辑如下：

```objc
BOOL firstUnsavedEntry = (++_unsavedCount == 1);
if ((_unsavedCount >= _saveThreshold) && (_saveThreshold > 0)) {
    [self performSaveAndSuspendSaveTimer];
} else if (firstUnsavedEntry) {
    _unsavedTime = dispatch_time(DISPATCH_TIME_NOW, 0);
    [self updateAndResumeSaveTimer];
}
```


### flush

```objc
[self performSaveAndSuspendSaveTimer];
```

该方法是当应用退出或崩溃时主动调用，以及时保存还在 pendding 状态的 log entities。



# FMDBLogger

简单介绍一下 FMDBLogger，它是通过 FMDB 提供的 API 将 log message 写入数据库。

这里每条 DDLogMessage 对应为 FMDBLogEntry，它简单存储了 context、flag、message、timestamp。数据库建表和校验就不说了，主要围绕重载的几个方法。



## db_log

```objc
FMDBLogEntry *logEntry = [[FMDBLogEntry alloc] initWithLogMessage:logMessage];
[pendingLogEntries addObject:logEntry];
```

这里并没有直接将 logEntry 插入 db，而是添加到缓冲列表中。我们真的需要这个缓冲区吗？

来看 SQLite 作者的回答：[**(19) INSERT is really slow - I can only do few dozen INSERTs per second**](https://www.sqlite.org/faq.html#q19)

> Actually, SQLite will easily do 50,000 or more [INSERT](https://www.sqlite.org/lang_insert.html) statements per second on an average desktop computer. But it will only do a few dozen transactions per second. Transaction speed is limited by the rotational speed of your disk drive. A transaction normally requires two complete rotations of the disk platter, which on a 7200RPM disk drive limits you to about 60 transactions per second.
>
> Transaction speed is limited by disk drive speed because (by default) SQLite actually waits until the data really is safely stored on the disk surface before the transaction is complete. That way, if you suddenly lose power or if your OS crashes, your data is still safe. For details, read about [atomic commit in SQLite.](https://www.sqlite.org/atomiccommit.html).
>
> By default, each INSERT statement is its own transaction. But if you surround multiple INSERT statements with [BEGIN](https://www.sqlite.org/lang_transaction.html)...[COMMIT](https://www.sqlite.org/lang_transaction.html) then all the inserts are grouped into a single transaction. The time needed to commit the transaction is amortized over all the enclosed insert statements and so the time per insert statement is greatly reduced.

也就是说，我们可以通过将多条插入语句用 `BEGIN ... COMMIT` 的方法包裹起来作为单独的事务来提交，效率将会有巨大的提升。



## db_save

最终尝试将 pendingLogEntries 作为事务执行的方法。会先检查 pendingLogEntries count 以及 database 是否正在执行事务，来判断是否需要使用  `BEGIN ... COMMIT` 。

```objc
BOOL saveOnlyTransaction = ![database inTransaction];

if (saveOnlyTransaction) {
    [database beginTransaction];
}

/* INSERT INTO logs & remove pendingLogEntries  */ 

if (saveOnlyTransaction) {
    [database commit];

    if ([database hadError]) {
        NSLog(@"%@: Error inserting log entries: code(%d): %@",
                [self class], [database lastErrorCode], [database lastErrorMessage]);
    }
}
```

可以看到这里的事务并非强制执行的，因此还是有优化空间的。比如通过串行队列来保证每次 save 都能在 transaction 中完成。

**db_delete** 与 **db_saveAndDelete** 就不展开了。



# The End

DDLog 所提供的 Demo 中还有 CoreDataLogger、WebSocketLogger 等自定义 logger 的扩展。比如，通过 WebSocketLogger 我们可以将日志直接输出到浏览器上来时时预览和校验日志或检查埋点数据等等。

通过这些 Demo 我们对 DDLog 的需求完全可以通过 Logger 的扩展来实现。比如，通过 mmap 来存储日志。这方面 Xlog 和 logan 目前就是这么实现的。而基于微信现有提供的 MMKV，我们用 Logger 简单扩展就能实现高效存储。

DDLog 中可以看到其对 dispatch source 的安全使用，包括 queue 和 timer 和多线程的处理；对 NSProxy 的巧妙使用来为 fileHandler 添加 buffer 支持；对系统的 log system 的了解，以及代码的健壮性，日志更新存储策略等等。非常值得一看。