---
title: "源码浅析 SDWebImage 5.6"
date: 2020-02-22T23:08:12+08:00
tags: ['SourceCode', 'iOS', 'cache', 'SourceCode']
categories: ['iOS', 'Objc']
author: "土土Edmond木"
---

本文基于 SDWebImage 5.6。重读的原因也是由于发现它的 API 在不断迭代，许多结构已经不同与早期版本，同时也是为了做一个记录。阅读顺序也会依据 API 执行顺序进行，不会太拘泥于细节，更多是了解整个框架是如何运行的。

![highlevel](https://raw.githubusercontent.com/SDWebImage/SDWebImage/master/Docs/Diagrams/SDWebImageHighLevelDiagram.jpeg)



## 5.x Migration Guid

如果大家有兴趣的，强烈推荐观看官方的推荐的[迁移文档](https://github.com/SDWebImage/SDWebImage/wiki/5.0-Migration-guide)，提到了5.x 版本的需要新特性，里面详细介绍其新特性和变化动机，主要 features：

- 全新的 Animated Image View  (4.0 为 `FLAnimatedImageView`)；
- 提供了 Image Transform 方便用户在下载图片后增加 scale, rotate, rounded corner 等操作；
- Customization，可以说一切皆协议，可以 custom [cache](https://github.com/SDWebImage/SDWebImage/wiki/Advanced-Usage#custom-cache-50)、[loader](https://github.com/SDWebImage/SDWebImage/wiki/Advanced-Usage#custom-loader-50)、[coder](https://github.com/SDWebImage/SDWebImage/wiki/Advanced-Usage#custom-coder-420)；
- 新增 View Indicator 来标识 Image 的 loading 状态；

可以说，5.x 的变化在于将整个 SDWebImage 中的核心类进行了协议化，同时将图片的请求、加载、解码、缓存等操作尽可能的进行了插件化处理，达到方便扩展、可替换。

协议化的类型很多，这里仅列出一小部分：

| 4.4                               | 5.x                             |
| --------------------------------- | ------------------------------- |
| SDWebImageCacheSerializerBlock    | id\<SDWebImageCacheSerializer\> |
| SDWebImageCacheKeyFilterBlock     | id\<SDWebImageCacheKeyFilter\>  |
| SDWebImageDownloader              | id\<SDImageLoader\>             |
| SDImageCache                      | id\<SDImageCache\>              |
| SDWebImageDownloaderProgressBlock | id\<SDWebImageIndicator>        |
| FLAnimatedImageView               | id\<SDAnimatedImage\>           |



## View Category

作为上层 API 调用是通过在 `UIView + WebCache` 之上提供便利方法实现的，包含以下几个 ：

- UIImageView+HighlightedWebCache
- UIImageView+WebCache
- UIView+WebCacheOperation
- UIButton+WebCache
- NSButton+WebCache

开始前，先来看看 [SDWebImageCompat.h](https://github.com/SDWebImage/SDWebImage/blob/09f06159a3284f6981d5495728e5c3cb3dfb82fa/SDWebImage/Core/SDWebImageCompat.h) 它定义了**SD_MAC、SD_UIKIT、SD_WATCH** 这三个宏用来区分不同系统的 API 来满足条件编译，同时还利用其来抹除 API 在不同平台的差异，比如利用 `#define UIImage NSImage` 将 mac 上的 NSImage 统一为 UIImage。另外值得注意的一点就是：

```objective-c
#ifndef dispatch_main_async_safe
#define dispatch_main_async_safe(block)\
    if (dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL) == dispatch_queue_get_label(dispatch_get_main_queue())) {\
        block();\
    } else {\
        dispatch_async(dispatch_get_main_queue(), block);\
    }
#endif
```

区别于早起版本的实现：

```objective-c
#define dispatch_main_async_safe(block)\
    if ([NSThread isMainThread]) {\
        block();\
    } else {\
        dispatch_async(dispatch_get_main_queue(), block);\
    }
#endif
```

-  `#ifndef` 提高了代码的严谨度，防止重复定义 `dispatch_main_async_safe`
- 判断条件由 isMainThread 改为了 dispatch_queue_t label 是否相等

关于第二点，有一篇 [SD 的讨论](https://github.com/SDWebImage/SDWebImage/pull/781)，以及另一篇说明 [GCD's Main Queue vs. Main Thread](http://blog.benjamin-encz.de/post/main-queue-vs-main-thread/)


> Calling an API from a non-main queue that is executing on the main thread will lead to issues if the library (like VektorKit) relies on checking for execution on the main queue.

区别就是从判断**是否在主线程执行**改为**是否在主队列上调度**。因为 **在主队列中的任务，一定会放到主线程执行**。

相比 UIImageView 的分类，UIButton 需要存储不同 `UIControlState` 和 backgrounImage 下的 image，Associate 了一个内部字典 `(NSMutableDictionary<NSString *, NSURL *> *)sd_imageURLStorage` 来保存图片。

所有 View Category 的 `setImageUrl:` 最终收口到下面这个方法:

```objective-c
- (void)sd_internalSetImageWithURL:(nullable NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholder
                           options:(SDWebImageOptions)options
                           context:(nullable SDWebImageContext *)context
                     setImageBlock:(nullable SDSetImageBlock)setImageBlock
                          progress:(nullable SDImageLoaderProgressBlock)progressBlock
                         completed:(nullable SDInternalCompletionBlock)completedBlock;
```

这个方法实现很长，简单说明流程：

1. 将 `SDWebImageContext`  复制并转换为 immutable，获取其中的 `validOperationKey` 值作为校验 id，默认值为当前 view 的类名；
2. 执行 `sd_cancelImageLoadOperationWithKey` 取消上一次任务，保证没有当前正在进行的异步下载操作, 不会与即将进行的操作发生冲突；
3. 设置占位图；
4. 初始化 `SDWebImageManager` 、`SDImageLoaderProgressBlock` , 重置 `NSProgress`、`SDWebImageIndicator`;
5. 开启下载`loadImageWithURL:` 并将返回的 `SDWebImageOperation` 存入 `sd_operationDictionary`，key 为 `validOperationKey`;
6. 取到图片后，调用 `sd_setImage:` 同时为新的 image 添加 Transition 过渡动画；
7. 动画结束后停止 indicator。



稍微说明的是 `SDWebImageOperation`它是一个 **strong - weak **的 NSMapTable，也是通过关联值添加的：

```objective-c
// key is strong, value is weak because operation instance is retained by SDWebImageManager's runningOperations property
// we should use lock to keep thread-safe because these method may not be acessed from main queue
typedef NSMapTable<NSString *, id<SDWebImageOperation>> SDOperationsDictionary;
```

用 weak 是因为 operation 实例是保存在 SDWebImageManager 的 runningOperations，这里只是保存了引用，以方便 cancel 。



### SDWebImageContext

> A SDWebImageContext object which hold the original context options from top-level API.

image context 贯穿图片处理的整个流程，它将数据逐级带入各个处理任务中，存在两种类型的 ImageContext:

```objectivec
typedef NSString * SDWebImageContextOption NS_EXTENSIBLE_STRING_ENUM;
typedef NSDictionary<SDWebImageContextOption, id> SDWebImageContext;
typedef NSMutableDictionary<SDWebImageContextOption, id>SDWebImageMutableContext;
```

SDWebImageContextOption 是一个可扩展的 String 枚举，目前有 15 种类型。基本上，你只需看名字也能猜出个大概，[文档](https://github.com/SDWebImage/SDWebImage/blob/5c3c40288f7e465ba94db9736e624f663831951a/SDWebImage/Core/SDWebImageDefine.h)，简单做了如下分类：

![image context](http://ww1.sinaimg.cn/large/8157560cgy1gcbeto2gb6j20xj1whajv.jpg)



从其参与度来看，可见其重要性。



## ImagePrefetcher

Prefetcher 它与 SD 整个处理流关系不大，主要用 imageManger 进行图片批量下载，核心方法如下：

```objective-c
- (nullable SDWebImagePrefetchToken *)prefetchURLs:(nullable NSArray<NSURL *> *)urls
                                          progress:(nullable SDWebImagePrefetcherProgressBlock)progressBlock
                                         completed:(nullable SDWebImagePrefetcherCompletionBlock)completionBlock;
```

它将下载的 URLs 作为 `事务` 存入 `SDWebImagePrefetchToken` 中，避免之前版本在每次 `prefetchURLs:` 时将上一次的 fetching 操作 cancel 的问题。

每个下载任务都是在 autoreleasesepool 环境下，且会用 `SDAsyncBlockOperation` 来包装真正的下载任务，来达到任务的可取消操作：

```objective-c
@autoreleasepool {
    @weakify(self);
    SDAsyncBlockOperation *prefetchOperation = [SDAsyncBlockOperation blockOperationWithBlock:^(SDAsyncBlockOperation * _Nonnull asyncOperation) {
        @strongify(self);
        if (!self || asyncOperation.isCancelled) {
            return;
        }
        /// load Image ...
    }];
    @synchronized (token) {
        [token.prefetchOperations addPointer:(__bridge void *)prefetchOperation];
    }
    [self.prefetchQueue addOperation:prefetchOperation];
}
```

最后将任务存入 prefetchQueue，其最大限制下载数默认为 3 。而 URLs 下载的真正任务是放在 `token.loadOperations`:

```objective-c
NSPointerArray *operations = token.loadOperations;
id<SDWebImageOperation> operation = [self.manager loadImageWithURL:url options:self.options context:self.context progress:nil completed:^(UIImage * _Nullable image, NSData * _Nullable data, NSError * _Nullable error, SDImageCacheType cacheType, BOOL finished, NSURL * _Nullable imageURL) {
    /// progress handler    
}];
NSAssert(operation != nil, @"Operation should not be nil, [SDWebImageManager loadImageWithURL:options:context:progress:completed:] break prefetch logic");
@synchronized (token) {
    [operations addPointer:(__bridge void *)operation];
}
```

`loadOperations` 与 `prefetchOperations` 均使用 **NSPointerArray** ，这里用到了其 [`NSPointerFunctionsWeakMemory`](apple-reference-documentation://hcx77yk4jV) 特性以及可以存储 `Null` 值，尽管其性能并不是很好，参见：[基础集合类](https://objccn.io/issue-7-1/)

另外一个值得注意的是 PrefetchToken 对下载状态的线程安全管理，使用了 [c++11 memory_order_relaxed](https://zhuanlan.zhihu.com/p/45566448) 。

```c++
atomic_ulong _skippedCount;
atomic_ulong _finishedCount;
atomic_flag  _isAllFinished;
    
unsigned long _totalCount;
```

即通过内存顺序和原子操作做到无锁并发，从而提高效率。具体原理感兴趣的同学可以自行查阅资料。



## ImageLoader

SDWebImageDownloader 是 \<SDImageLoader> 协议在 SD 内部的默认实现。它提供了 HTTP/HTTPS/FTP 或者 local URL 的 NSURLSession 来源的图片获取能力。同时它最大程度的开放整个下载过程的的可配置性。主要 properties ：

```objective-c
@interface SDWebImageDownloader : NSObject

@property (nonatomic, copy, readonly, nonnull) SDWebImageDownloaderConfig *config;
@property (nonatomic, strong, nullable) id<SDWebImageDownloaderRequestModifier> requestModifier;
@property (nonatomic, strong, nullable) id<SDWebImageDownloaderResponseModifier> responseModifier;
@property (nonatomic, strong, nullable) id<SDWebImageDownloaderDecryptor> decryptor;
/* ... */

-(nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
    options:(SDWebImageDownloaderOptions)options
    context:(nullable SDWebImageContext *)context
   progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
  completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;

@end
```

其中 downloaderConfig 是支持 NSCopy 协议的，提供的主要配置如下：

```objective-c
/// Defaults to 6.
@property (nonatomic, assign) NSInteger maxConcurrentDownloads;
/// Defaults to 15.0s.
@property (nonatomic, assign) NSTimeInterval downloadTimeout;
/// custom session configuration，不支持在使用过程中动态替换类型； 
@property (nonatomic, strong, nullable) NSURLSessionConfiguration *sessionConfiguration;
/// 动态扩展类，需要遵循 `NSOperation<SDWebImageDownloaderOperation>` 以实现 SDImageLoader 定制
@property (nonatomic, assign, nullable) Class operationClass;
/// 图片下载顺序，默认 FIFO
@property (nonatomic, assign) SDWebImageDownloaderExecutionOrder executionOrder;
```

request modifier，提供在下载前修改 request，

```objective-c
/// Modify the original URL request and return a new one instead. You can modify the HTTP header, cachePolicy, etc for this URL.

@protocol SDWebImageDownloaderRequestModifier <NSObject>
   
- (nullable NSURLRequest *)modifiedRequestWithRequest:(nonnull NSURLRequest *)request;

@end
```

同样，response modifier 则提供对返回值的修改，

```objective-c
/// Modify the original URL response and return a new response. You can use this to check MIME-Type, mock server response, etc.

@protocol SDWebImageDownloaderResponseModifier <NSObject>

- (nullable NSURLResponse *)modifiedResponseWithResponse:(nonnull NSURLResponse *)response;

@end
```

最后一个 decryptor 用于图片解密，默认提供了对 imageData 的 base64 转换，

```objective-c
/// Decrypt the original download data and return a new data. You can use this to decrypt the data using your perfereed algorithm.
@protocol SDWebImageDownloaderDecryptor <NSObject>

- (nullable NSData *)decryptedDataWithData:(nonnull NSData *)data response:(nullable NSURLResponse *)response;

@end
```

通过这个协议化后的对象来处理数据，可以说是利用了设计模式中的 **策略模式** 或者 **依赖注入**。通过配置的方式获取到协议对象，调用方仅需关心协议对象提供的方法，无需在意其内部实现，达到解耦的目的。



###DownloadImageWithURL

下载前先检查 URL 是否存在，没有则直接抛错返回。取到 URL 后尝试复用之前生成的 operation：

```objective-c
NSOperation<SDWebImageDownloaderOperation> *operation = [self.URLOperations objectForKey:url];
```

如果 operation 存在，调用

```objective-c
@synchronized (operation) {
    downloadOperationCancelToken = [operation addHandlersForProgress:progressBlock completed:completedBlock];
}
```

并设置  queuePriority。这里用了 @synchronized(operation) ，同时 Operation 内部则会用 @synchronized(self)，以保证两个不同类间 operation 的线程安全，因为 operation 有可能被传递到解码或代理的队列中。这里 `addHandlersForProgress：` 会将 progressBlock 与 completedBlock 一起存入 `NSMutableDictionary<NSString *, id> SDCallbacksDictionary` 然后返回保存在 downloadOperationCancelToken 中。

另外，Operation 在 `addHandlersForProgress:` 时并不会清除之前存储的 callbacks 是增量保存的，也就是说多次调用的 callBack 在完成后都会被依次执行。

如果 operation 不存在、任务被取消、任务已完成，调用 `createDownloaderOperationWithUrl:options:context:` 创建出新的 operation 并存储在 URLOperations 中 。同时会配置 completionBlock，使得任务完成后可以及时清理 URLOperations。保存 progressBlock 和 completedBlock；提交 operation 到 downloadQueue。

最终 operation、url、request、downloadOperationCancelToken 一起被打包进 SDWebImageDownloadToken， 下载方法结束。



###CreateDownloaderOperation

下载结束，我们来聊聊 operation 是如何创建的。首先是生成 URLRequest：

```objective-c
// In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
NSURLRequestCachePolicy cachePolicy = options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
NSMutableURLRequest *mutableRequest = [[NSMutableURLRequest alloc] initWithURL:url cachePolicy:cachePolicy timeoutInterval:timeoutInterval];
mutableRequest.HTTPShouldHandleCookies = SD_OPTIONS_CONTAINS(options, SDWebImageDownloaderHandleCookies);
mutableRequest.HTTPShouldUsePipelining = YES;
SD_LOCK(self.HTTPHeadersLock);
mutableRequest.allHTTPHeaderFields = self.HTTPHeaders;
SD_UNLOCK(self.HTTPHeadersLock);
```

主要通过 SDWebImageDownloaderOptions 获取参数来配置， timeout 是由 downloader 的 config.downloadTimeout 决定，默认为 15s。然后从 imageContext 中取出 `id<SDWebImageDownloaderRequestModifier> requestModifier` 对 request 进行改造。

```objective-c
// Request Modifier
id<SDWebImageDownloaderRequestModifier> requestModifier;
if ([context valueForKey:SDWebImageContextDownloadRequestModifier]) {
    requestModifier = [context valueForKey:SDWebImageContextDownloadRequestModifier];
} else {
    requestModifier = self.requestModifier;
}
```

值得注意的是 requestModifier 的获取是有**优先级**的，通过 imageContext 得到的优先级高于 downloader 所拥有的。通过这种方既满足了接口调用方可控，又能支持全局配置，可谓老少皆宜。同理，`id<SDWebImageDownloaderResponseModifier> responseModifier` 、`id<SDWebImageDownloaderDecryptor> decryptor` 也是如此。

之后会将确认过的 responseModifier 和 decryptor 再次保存到 imageContext 中为之后使用。

最后，从 downloaderConfig 中取出 operationClass 创建 operation：

```objective-c
Class operationClass = self.config.operationClass;
if (operationClass && [operationClass isSubclassOfClass:[NSOperation class]] && [operationClass conformsToProtocol:@protocol(SDWebImageDownloaderOperation)]) {
    // Custom operation class
} else {
    operationClass = [SDWebImageDownloaderOperation class];
}
NSOperation<SDWebImageDownloaderOperation> *operation = [[operationClass alloc] initWithRequest:request inSession:self.session options:options context:context];
```

设置其 credential、minimumProgressInterval、queuePriority、pendingOperation。

默认情况下，每个任务是按照 FIFO 顺序添加到 downloadQueue 中，如果用户设置的是 LIFO 时，添加进队列前会修改队列中现有任务的优先级来达到效果：

```objective-c
if (self.config.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
    // Emulate LIFO execution order by systematically, each previous adding operation can dependency the new operation
    // This can gurantee the new operation to be execulated firstly, even if when some operations finished, meanwhile you appending new operations
    // Just make last added operation dependents new operation can not solve this problem. See test case #test15DownloaderLIFOExecutionOrder
    for (NSOperation *pendingOperation in self.downloadQueue.operations) {
        [pendingOperation addDependency:operation];
    }
}
```

通过遍历队列，将新任务修改为当前队列中所有任务的依赖以反转优先级。



### 数据处理

SDWebImageDownloaderOperation 也是协议化后的类型，协议本身遵循 NSURLSessionTaskDelegate, NSURLSessionDataDelegate，它是真正处理 URL 请求数据的类，支持后台下载，支持对 responseData 修改(by responseModifier)，支持对 download ImageData 进行解密 (by decryptor)。其主要内部 properties 如下：

```objective-c
@property (assign, nonatomic, readwrite) SDWebImageDownloaderOptions options;
@property (copy, nonatomic, readwrite, nullable) SDWebImageContext *context;
@property (strong, nonatomic, nonnull) NSMutableArray<SDCallbacksDictionary *> *callbackBlocks;

@property (strong, nonatomic, nullable) NSMutableData *imageData;
@property (copy, nonatomic, nullable) NSData *cachedData; // for `SDWebImageDownloaderIgnoreCachedResponse`
@property (assign, nonatomic) NSUInteger expectedSize; // may be 0
@property (assign, nonatomic) NSUInteger receivedSize;

@property (strong, nonatomic, nullable) id<SDWebImageDownloaderResponseModifier> responseModifier; // modifiy original URLResponse
@property (strong, nonatomic, nullable) id<SDWebImageDownloaderDecryptor> decryptor; // decrypt image data
// This is weak because it is injected by whoever manages this session. If this gets nil-ed out, we won't be able to run
// the task associated with this operation
@property (weak, nonatomic, nullable) NSURLSession *unownedSession;
// This is set if we're using not using an injected NSURLSession. We're responsible of invalidating this one
@property (strong, nonatomic, nullable) NSURLSession *ownedSession;

@property (strong, nonatomic, nonnull) dispatch_queue_t coderQueue; // the queue to do image decoding
#if SD_UIKIT
@property (assign, nonatomic) UIBackgroundTaskIdentifier backgroundTaskId;

- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options
                                context:(nullable SDWebImageContext *)context;
```

初始化没有什么特别的，需要注意的是这里传入的 `nullable session` 是以 unownedSessin 保存，区别于内部默认生成的 **ownedSession**。如果初始化时 session 为空，会在 `start` 时创建 ownedSession。

那么问题来了，由于我们需观察 session 的各个状态，需要设置 delegate 来完成，

```objective-c
[NSURLSession sessionWithConfiguration:delegate:delegateQueue:];
```

ownedSession 的 delegate 毋庸置疑就在 operation 内部，而初始化传入 session 的 delegate 则是 downloader 。它会通过 taskID 取出 operation 调用对应实现来完成回调的统一处理和转发，例如：

```objective-c
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    
    // Identify the operation that runs this task and pass it the delegate method
    NSOperation<SDWebImageDownloaderOperation> *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) {
        [dataOperation URLSession:session task:task didCompleteWithError:error];
    }
}
```

接着作为真正的消费者 operation 开始下载任务，整个下载过程包括开始、结束、取消都会发送对应通知。

1. 在 **didReceiveResponse** 时，会保存 response.expectedContentLength 作为 expectedSize。然后调用 `modifiedResponseWithResponse:` 保存编辑后的 reponse。 

2. 每次 **didReceiveData** 会将 data 追加到 imageData：`[self.imageData appendData:data]` ，更新 receivedSize`self.receivedSize = self.imageData.length` 。最终，当 receivedSize > expectedSize 判定下载完成，执行后续处理。如果你支持了 `SDWebImageDownloaderProgressiveLoad`，每当收到数据时，将会进入 coderQueue 进行边下载边解码:

```objective-c
// progressive decode the image in coder queue
dispatch_async(self.coderQueue, ^{
    @autoreleasepool {
        UIImage *image = SDImageLoaderDecodeProgressiveImageData(imageData, self.request.URL, finished, self, [[self class] imageOptionsFromDownloaderOptions:self.options], self.context);
        if (image) {
            // We do not keep the progressive decoding image even when `finished`=YES. Because they are for view rendering but not take full function from downloader options. And some coders implementation may not keep consistent between progressive decoding and normal decoding.
            
            [self callCompletionBlocksWithImage:image imageData:nil error:nil finished:NO];
        }
    }
});
```

​		否则，会在 **didCompleteWithError** 时完成解码操作：`SDImageLoaderDecodeImageData` ，不过在解码前需要先解密:

```objective-c
if (imageData && self.decryptor) {
    imageData = [self.decryptor decryptedDataWithData:imageData response:self.response];
}
```

​	3. 处理 complete 回调；

关于 decode 的逻辑我们最后聊。



## ImageCache

基本上 Cache 相关类的设计思路与 ImageLoader 一致，会有一份 **SDImageCacheConfig** 以配置缓存的过期时间，容量大小，读写权限，以及动态可扩展的 MemoryCache/DiskCache。

SDImageCacheConfig 主要属性如下:

```objective-c
@property (assign, nonatomic) BOOL shouldDisableiCloud;
@property (assign, nonatomic) BOOL shouldCacheImagesInMemory;
@property (assign, nonatomic) BOOL shouldUseWeakMemoryCache;
@property (assign, nonatomic) BOOL shouldRemoveExpiredDataWhenEnterBackground;
@property (assign, nonatomic) NSDataReadingOptions diskCacheReadingOptions;
@property (assign, nonatomic) NSDataWritingOptions diskCacheWritingOptions;
@property (assign, nonatomic) NSTimeInterval maxDiskAge;
@property (assign, nonatomic) NSUInteger maxDiskSize;
@property (assign, nonatomic) NSUInteger maxMemoryCost;
@property (assign, nonatomic) NSUInteger maxMemoryCount;
@property (assign, nonatomic) SDImageCacheConfigExpireType diskCacheExpireType;
/// Defaults to built-in `SDMemoryCache` class.
@property (assign, nonatomic, nonnull) Class memoryCacheClass;
/// Defaults to built-in `SDDiskCache` class.
@property (assign ,nonatomic, nonnull) Class diskCacheClass;
```

MemoryCache、DiskCache 的实例化都需要 SDImageCacheConfig 的传入：

```objective-c
/// SDMemoryCache
- (nonnull instancetype)initWithConfig:(nonnull SDImageCacheConfig *)config;
/// SDDiskCache
- (nullable instancetype)initWithCachePath:(nonnull NSString *)cachePath config:(nonnull SDImageCacheConfig *)config;
```

作为缓存协议，他们的接口声明基本一致，都是对数据的 CURD，区别在于 MemoryCache Protocl 操作的是 **id** 类型 (NSCache API 限制)，DiskCache 则是对 NSData。

我们来看看他们的默认实现吧。

### SDMemoryCache

```objective-c
/**
 A memory cache which auto purge the cache on memory warning and support weak cache.
 */
@interface SDMemoryCache <KeyType, ObjectType> : NSCache <KeyType, ObjectType> <SDMemoryCache>

@property (nonatomic, strong, nonnull, readonly) SDImageCacheConfig *config;

@end
```

内部就是将 **NSCache** 扩展为了 SDMemoryCache 协议，并加入了 **NSMapTable<KeyType, ObjectType> *weakCache** ，并为其添加了信号量锁来保证线程安全。这里的 weak-cache 是仅在 *iOS/tvOS* 平台添加的特性，因为在 macOS 上尽管收到系统内存警告，NSCache 也不会清理对应的缓存。weakCache 使用的是 strong-weak 引用不会有有额外的内存开销且不影响对象的生命周期。

weakCache 的作用在于恢复缓存，它通过 CacheConfig 的 **shouldUseWeakMemoryCache** 开关以控制，详细说明可以查看 [CacheConfig.h](https://github.com/SDWebImage/SDWebImage/blob/master/SDWebImage/Core/SDImageCacheConfig.h)。先看看其如何实现的：

```objective-c
- (id)objectForKey:(id)key {
    id obj = [super objectForKey:key];
    if (!self.config.shouldUseWeakMemoryCache) {
        return obj;
    }
    if (key && !obj) {
        // Check weak cache
        SD_LOCK(self.weakCacheLock);
        obj = [self.weakCache objectForKey:key];
        SD_UNLOCK(self.weakCacheLock);
        if (obj) {
            // Sync cache
            NSUInteger cost = 0;
            if ([obj isKindOfClass:[UIImage class]]) {
                cost = [(UIImage *)obj sd_memoryCost];
            }
            [super setObject:obj forKey:key cost:cost];
        }
    }
    return obj;
}
```

由于 NSCache 遵循  [`NSDiscardableContent`](apple-reference-documentation://hcnVx1bA-q)  策略来存储临时对象的，当内存紧张时，缓存对象有可能被系统清理掉。此时，如果应用访问 MemoryCache 时，缓存一旦未命中，则会转入 diskCache 的查询操作，可能导致 image 闪烁现象。而当开启 shouldUseWeakMemoryCache 时，因为 weakCache 保存着对象的弱引用 （在对象 被 NSCache 被清理且没有被释放的情况下)，我们可通过 weakCache 取到缓存，将其塞会 NSCache 中。从而减少磁盘 I/O。



### SDDiskCache

这个更简单，内部使用 NSFileManager 管理图片数据读写， 调用 SDDiskCacheFileNameForKey 将 key MD5 处理后作为 fileName，存放在 diskCachePath 目录下。另外就是过期缓存的清理：

1. 根据 SDImageCacheConfigExpireType 排序得到 `NSDirectoryEnumerator *fileEnumerator` ，开始过滤；
2. 以 cacheConfig.maxDiskAage 对比判断是否过期，将过期 URL 存入 urlsToDelete；
3. 调用 `[self.fileManager removeItemAtURL:fileURL error:nil];`
4. 根据 cacheConfig.maxDiskSize 来删除磁盘缓存的数据，清理到 maxDiskSize 的 1/2 为止。



另外一点就是 SDDiskCache 同 **[YYKVStorage](https://github.com/ibireme/YYCache/blob/master/YYCache/YYKVStorage.h)** 一样同样支持为 UIImage 添加 extendData 用以存储额外信息，例如，图片的缩放比例, [URL rich link](https://sspai.com/post/55279), 时间等其他数据。

不过 **YYKVStorage** 本身是用数据库中 ***manifest*** 表的 extended_data 字段来存储的。SDDiskCache 就另辟蹊径解决了。利用系统 API <sys/xattr.h> 的 **setxattr**、**getxattr**、**listxattr** 将 extendData 保存。可以说又涨姿势了。顺便说一下，它对应的 key 是用 *SDDiskCacheExtendedAttributeName*。



### SDImageCache

也是协议化后的类，负责调度 SDMemoryCache、SDDiskCache，其 Properties 如下：

```objective-c
@property (nonatomic, strong, readwrite, nonnull) id<SDMemoryCache> memoryCache;
@property (nonatomic, strong, readwrite, nonnull) id<SDDiskCache> diskCache;
@property (nonatomic, copy, readwrite, nonnull) SDImageCacheConfig *config;
@property (nonatomic, copy, readwrite, nonnull) NSString *diskCachePath;
@property (nonatomic, strong, nullable) dispatch_queue_t ioQueue;
```

> 说明：memoryCache 和  diskCache 实例是依据 CacheConfig 中定义的 class 来生成的，默认为 SDMemoryCache 和 SDDiskCache。

我们看看其核心方法：

```objective-c
- (void)storeImage:(nullable UIImage *)image
         imageData:(nullable NSData *)imageData
            forKey:(nullable NSString *)key
          toMemory:(BOOL)toMemory
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock;
```

1. 确保 image 和 key 存在；

2. 当 *shouldCacheImagesInMemory* 为 YES，则会调用 `[self.memoryCache setObject:image forKey:key cost:cost]` 进行 memoryCache 写入；

3. 进行 diskCache 写入，操作逻辑放入 ioQueue 和 autoreleasepool 中。

   ```objective-c
   dispatch_async(self.ioQueue, ^{
       @autoreleasepool {
           NSData *data = ... // 根据 SDImageFormat 对 image 进行编码获取
           /// data = [[SDImageCodersManager sharedManager] encodedDataWithImage:image format:format options:nil];
           [self _storeImageDataToDisk:data forKey:key];
           if (image) {
               // Check extended data
               id extendedObject = image.sd_extendedObject;
               // ... get extended data
               [self.diskCache setExtendedData:extendedData forKey:key];
           }
       }
       // call completionBlock in main queue
   });
   ```



另一个重要的方法就是 image query，定义在 SDImageCache 协议中：

```objective-c
- (id<SDWebImageOperation>)queryImageForKey:(NSString *)key options:(SDWebImageOptions)options context:(nullable SDWebImageContext *)context completion:(nullable SDImageCacheQueryCompletionBlock)completionBlock {
    SDImageCacheOptions cacheOptions = 0;
    if (options & SDWebImageQueryMemoryData) cacheOptions |= SDImageCacheQueryMemoryData;
    if (options & SDWebImageQueryMemoryDataSync) cacheOptions |= SDImageCacheQueryMemoryDataSync;
    if (options & SDWebImageQueryDiskDataSync) cacheOptions |= SDImageCacheQueryDiskDataSync;
    if (options & SDWebImageScaleDownLargeImages) cacheOptions |= SDImageCacheScaleDownLargeImages;
    if (options & SDWebImageAvoidDecodeImage) cacheOptions |= SDImageCacheAvoidDecodeImage;
    if (options & SDWebImageDecodeFirstFrameOnly) cacheOptions |= SDImageCacheDecodeFirstFrameOnly;
    if (options & SDWebImagePreloadAllFrames) cacheOptions |= SDImageCachePreloadAllFrames;
    if (options & SDWebImageMatchAnimatedImageClass) cacheOptions |= SDImageCacheMatchAnimatedImageClass;
    
    return [self queryCacheOperationForKey:key options:cacheOptions context:context done:completionBlock];
}
```

它只做了一件事情，将 SDWebImageOptions 转换为 SDImageCacheOptions，然后调用 `queryCacheOperationForKey:` ，其内部逻辑如下：

首先，如果 query key 存在，会从 imageContext 中获取 transformer，对 query key 进行转换:

```objective-c
key = SDTransformedKeyForKey(key, transformerKey);
```

尝试从 memory cache 获取 image，如果存在：

1. 满足 SDImageCacheDecodeFirstFrameOnly 且遵循 SDAnimatedImage 协议，则会取出 CGImage 进行转换

   ```objective-c
   // Ensure static image
   Class animatedImageClass = image.class;
   if (image.sd_isAnimated || ([animatedImageClass isSubclassOfClass:[UIImage class]] && [animatedImageClass conformsToProtocol:@protocol(SDAnimatedImage)])) {
   #if SD_MAC
       image = [[NSImage alloc] initWithCGImage:image.CGImage scale:image.scale orientation:kCGImagePropertyOrientationUp];
   #else
       image = [[UIImage alloc] initWithCGImage:image.CGImage scale:image.scale orientation:image.imageOrientation];
   #endif
   }
   ```

2. 满足 SDImageCacheMatchAnimatedImageClass ，则会强制检查 image 类型是否匹配，否则将数据至 nil:

   ```objective-c
   // Check image class matching
   Class animatedImageClass = image.class;
   Class desiredImageClass = context[SDWebImageContextAnimatedImageClass];
   if (desiredImageClass && ![animatedImageClass isSubclassOfClass:desiredImageClass]) {
       image = nil;
   }
   ```

当可以从 memory cache 获取到 image 且为 SDImageCacheQueryMemoryData，直接完成返回，否则继续；

开始 diskCache 读取，依据读取条件判定 I/O 操作是否为同步。

```objective-c
// Check whether we need to synchronously query disk
// 1. in-memory cache hit & memoryDataSync
// 2. in-memory cache miss & diskDataSync
BOOL shouldQueryDiskSync = ((image && options & SDImageCacheQueryMemoryDataSync) ||
                            (!image && options & SDImageCacheQueryDiskDataSync));
```

整个 diskQuery 存在 queryDiskBlock 中并用 autorelease 包裹：

```objective-c
void(^queryDiskBlock)(void) =  ^{
    if (operation.isCancelled) {
        // call doneBlock & return
    }
    @autoreleasepool {
        NSData *diskData = [self diskImageDataBySearchingAllPathsForKey:key];
        UIImage *diskImage;
        SDImageCacheType cacheType = SDImageCacheTypeNone;
        if (image) {
            // the image is from in-memory cache, but need image data
            diskImage = image;
            cacheType = SDImageCacheTypeMemory;
        } else if (diskData) {
            cacheType = SDImageCacheTypeDisk;
            // decode image data only if in-memory cache missed
            diskImage = [self diskImageForKey:key data:diskData options:options context:context];
            if (diskImage && self.config.shouldCacheImagesInMemory) {
                NSUInteger cost = diskImage.sd_memoryCost;
                [self.memoryCache setObject:diskImage forKey:key cost:cost];
            }
        }
        // call doneBlock
        if (doneBlock) {
            if (shouldQueryDiskSync) {
                doneBlock(diskImage, diskData, cacheType);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    doneBlock(diskImage, diskData, cacheType);
                });
            }
        }
    }
}
```

对于大量临时内存操作 SD 都会将其放入 autoreleasepool 以保证内存能及时被释放。

特别强调，代码如果执行到这，就一定会有磁盘读取到操作，因此，如果不是非要获取 imageData 可以通过 **SDImageCacheQueryMemoryData** 来提高查询效率；

最后，`SDTransformedKeyForKey` 的转换逻辑是以 **SDImageTransformer** 的 transformerKey 按顺序依次拼接在 image key 后面。例如：

```objective-c
'image.png' |> flip(YES,NO) |> rotate(pi/4,YES)  => 
'image-SDImageFlippingTransformer(1,0)-SDImageRotationTransformer(0.78539816339,1).png'
```



## SDImageManaer

SDImageManger 作为整个库的调度中心，上述各种逻辑的集大成者，它把各个组建串联，从视图 > 下载 > 解码器 > 缓存。而它暴露的核心方法就一个，就是 loadImage:

```objective-c
@property (strong, nonatomic, readonly, nonnull) id<SDImageCache> imageCache;
@property (strong, nonatomic, readonly, nonnull) id<SDImageLoader> imageLoader;
@property (strong, nonatomic, nullable) id<SDImageTransformer> transformer;
@property (nonatomic, strong, nullable) id<SDWebImageCacheKeyFilter> cacheKeyFilter;
@property (nonatomic, strong, nullable) id<SDWebImageCacheSerializer> cacheSerializer;
@property (nonatomic, strong, nullable) id<SDWebImageOptionsProcessor> optionsProcessor;

@property (nonatomic, class, nullable) id<SDImageCache> defaultImageCache;
@property (nonatomic, class, nullable) id<SDImageLoader> defaultImageLoader;

- (nullable SDWebImageCombinedOperation *)loadImageWithURL:(nullable NSURL *)url
                                                   options:(SDWebImageOptions)options
                                                   context:(nullable SDWebImageContext *)context
                                                  progress:(nullable SDImageLoaderProgressBlock)progressBlock
                                                 completed:(nonnull SDInternalCompletionBlock)completedBlock;
```



这里先简单说一下 cacheKeyFilter、cacheSerializer 和 optionsProcessor 这三个 API，其余的上面都提到过了。

**SDWebImageCacheKeyFilter**

默认情况下，是把 URL.absoluteString 作为 cacheKey ，而如果设置了 fileter 则会对通过 `cacheKeyForURL:` 对 cacheKey 拦截并进行修改；

**SDWebImageCacheSerializer**

默认情况下，ImageCache 会直接将 downloadData 进行缓存，而当我们使用其他图片格式进行传输时，例如 WEBP 格式的，那么磁盘中的存储则会按 WEBP 格式来。这会产生一个问题，每次当我们需要从磁盘读取 image 时都需要进行重复的解码操作。而通过 CacheSerializer 可以直接将 downloadData 转换为 JPEG/PNG 的格式的 NSData 缓存，从而提高访问效率。

**SDWebImageOptionsProcessor**

用于控制全局的 SDWebImageOptions 和 SDWebImageContext 中的参数。示例如下：

```objective-c
 SDWebImageManager.sharedManager.optionsProcessor = [SDWebImageOptionsProcessor optionsProcessorWithBlock:^SDWebImageOptionsResult * _Nullable(NSURL * _Nullable url, SDWebImageOptions options, SDWebImageContext * _Nullable context) {
     // Only do animation on `SDAnimatedImageView`
     if (!context[SDWebImageContextAnimatedImageClass]) {
        options |= SDWebImageDecodeFirstFrameOnly;
     }
     // Do not force decode for png url
     if ([url.lastPathComponent isEqualToString:@"png"]) {
        options |= SDWebImageAvoidDecodeImage;
     }
     // Always use screen scale factor
     SDWebImageMutableContext *mutableContext = [NSDictionary dictionaryWithDictionary:context];
     mutableContext[SDWebImageContextImageScaleFactor] = @(UIScreen.mainScreen.scale);
     context = [mutableContext copy];
 
     return [[SDWebImageOptionsResult alloc] initWithOptions:options context:context];
 }];
```



### LoadImage

接口的的第一个参数 url 作为整个框架的连接核心，却设计成 nullable 应该完全是方便调用方而设计的。内部通过对 url 的 nil 判断以及对 NSString 类型的兼容 (强制转成 NSURL) 以保证后续的流程，否则结束调用。下载开始后又拆分成了一下 6 个方法：

- callCacheProcessForOperation
- callDownloadProcessForOperation
- callStoreCacheProcessForOperation
- callTransformProcessForOperation
- callCompletionBlockForOperation
- safelyRemoveOperationFromRunning

分别是：缓存查询、下载、存储、转换、执行回调、清理回调。你可以发现每个方法都是针对 operation 的操作，operation 在 loadImage 时会准备好，然后开始缓存查询。

```objective-c
SDWebImageCombinedOperation *operation = [SDWebImagCombinedOperation new];
operation.manager = self;

///  1
BOOL isFailedUrl = NO;
if (url) {
    SD_LOCK(self.failedURLsLock);
    isFailedUrl = [self.failedURLs containsObject:url];
    SD_UNLOCK(self.failedURLsLock);
}

if (url.absoluteString.length == 0 || (!(options & SDWebImageRetryFailed) && isFailedUrl)) {
    [self callCompletionBlockForOperation:operation completion:completedBlock error:[NSError errorWithDomain:SDWebImageErrorDomain code:SDWebImageErrorInvalidURL userInfo:@{NSLocalizedDescriptionKey : @"Image url is nil"}] url:url];
    return operation;
}

SD_LOCK(self.runningOperationsLock);
[self.runningOperations addObject:operation];
SD_UNLOCK(self.runningOperationsLock);

// 2. Preprocess the options and context arg to decide the final the result for manager
SDWebImageOptionsResult *result = [self processedResultForURL:url options:options context:context];
```

**loadImage** 方法本身不复杂，核心是生成 operation 然后转入缓存查询。

在 operation 初始化后会检查  failedURLs 是否包含当前 url：

- 如果有且 options 为 SDWebImageRetryFailed，直接结束并返回 operation；
- 如果检查通过会将 operation 存入 `runningOperations` 中。并将 options 和 imageContext 封入 SDWebImageOptionsResult。

同时，会更新一波 imageContext，主要先将 transformer、cacheKeyFilter、cacheSerializer 存入 imageContext 做为全局默认设置，再调用 **optionsProcessor** 来提供用户的自定义 options 再次加工 imageContext 。这个套路大家应该有印象吧，前面的 ImageLoader 中的 requestModifer 的优先级逻辑与此类似，不过实现方式有些差异。最后转入 CacheProcess。

**loadImage** 过程是使用了 combineOperation，它是 combine 了 cache 和 loader 的操作任务，使其可以一步到位清理缓存查询和下载任务的作用。其声明如下：

```objective-c
@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>
/// imageCache queryImageForKey: 的 operation
@property (strong, nonatomic, nullable, readonly) id<SDWebImageOperation> cacheOperation;
/// imageLoader requestImageWithURL: 的 operation
@property (strong, nonatomic, nullable, readonly) id<SDWebImageOperation> loaderOperation;
/// Cancel the current operation, including cache and loader process
- (void)cancel;
@end
```

其提供的 cancel 方法会逐步检查两种类型 opration 然后逐一执行 cancel 操作。



####CallCacheProcessForOperation

先检查 **SDWebImageFromLoaderOnly** 值，判断是否为直接下载的任务，

是，则转到 downloadProcess。

否，则通过 imageCache 创建查询任务并将其保存到 combineOperation 的 cacheOperation ：

```objective-c
operation.cacheOperation = [self.imageCache queryImageForKey:key options:options context:context completion:^(UIImage * _Nullable cachedImage, NSData * _Nullable cachedData, SDImageCacheType cacheType) {
   if (!operation || operation.isCancelled) {
    	/// 1  
   }
  	/// 2
}];
```

对缓存查询的结果有两种情况需要处理：

1. 当队列执行到该任务时，如果 operaton 被标志为 canceled 状态则结束下载任务；
2. 否则转到 downloadProcess 。



####CallDownloadProcessForOperation

下载的实现比较复杂，首先需要决定是否需要新建下载任务，由三个变量控制：

```objective-c
BOOL shouldDownload = !SD_OPTIONS_CONTAINS(options, SDWebImageFromCacheOnly);
    shouldDownload &= (!cachedImage || options & SDWebImageRefreshCached);
    shouldDownload &= (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url]);
    shouldDownload &= [self.imageLoader canRequestImageForURL:url];
```

- 检查 options 值是否为 SDWebImageFromCacheOnly 或 SDWebImageRefreshCached 的
- 由代理决定是否需要新建下载任务
- 通过 imageLoader 控制能否支持下载任务

1. 如果 shouldDownload 为 NO，则结束下载并调用 **callCompletionBlockForOperation** 与 **safelyRemoveOperationFromRunning**。此时如果存在 cacheImage 则会随 completionBlock 一起返回。

2. 如果 shouldDownload 为 YES，新建下载任务并将其保存在 combineOperation 的 loaderOperation。在新建任务前，如有取到 cacheImage 且 SDWebImageRefreshCached 为 YES，会将其存入 imageContext (没有则创建 imageContext)。

3. 下载结束后回到 callBack，这里会先处理几种情况：

   - operation 被 cancel 则抛弃下载的 image、data ，callCompletionBlock 结束下载；
   - reqeust 被 cancel 导致的 error，callCompletionBlock 结束下载；
   - imageRefresh 后请求结果仍旧命中了 NSURLCache 缓存，则不会调用 callCompletionBlock；
   - errro 出错，callCompletionBlockForOperation 并将 url 添加至 failedURLs；
   - 均无以上情况，如果是通过 retry 成功的，会先将 url 从 failedURLs 中移除，调用 storeCacheProcess；

   最后会对标记为 finished 的执行 safelyRemoveOperation；

   

####CallStoreCacheProcessForOperation

先从 imageContext 中取出 storeCacheType、originalStoreCacheType、transformer、cacheSerializer，判断是否需要存储转换后图像数据、原始数据、等待缓存存储结束：

```objective-c
BOOL shouldTransformImage = downloadedImage && (!downloadedImage.sd_isAnimated || (options & SDWebImageTransformAnimatedImage)) && transformer;
BOOL shouldCacheOriginal = downloadedImage && finished;
BOOL waitStoreCache = SD_OPTIONS_CONTAINS(options, SDWebImageWaitStoreCache);
```

如果 shouldCacheOriginal 为 NO，直接转入 transformProcess。否则，先确认存储类型是否为原始数据：

```objective-c
// normally use the store cache type, but if target image is transformed, use original store cache type instead
SDImageCacheType targetStoreCacheType = shouldTransformImage ? originalStoreCacheType : storeCacheType;
```

存储时如果 cacheSerializer 存在则会先转换数据格式，最终都调用 `[self stroageImage: ...]` 。

当存储结束时，转入最后一步，transformProcess。



####CallTransformProcessForOperation

转换开始前会例行判断是否需要转换，为 false 则 callCompletionBlock 结束下载，判断如下：

```objective-c
id<SDImageTransformer> transformer = context[SDWebImageContextImageTransformer];
id<SDWebImageCacheSerializer> cacheSerializer = context[SDWebImageContextCacheSerializer];
BOOL shouldTransformImage = originalImage && (!originalImage.sd_isAnimated || (options & SDWebImageTransformAnimatedImage)) && transformer;
BOOL waitStoreCache = SD_OPTIONS_CONTAINS(options, SDWebImageWaitStoreCache);
```

如果需要转换，会进入全局队列开始处理：

```objective-c
dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    @autoreleasepool {
        UIImage *transformedImage = [transformer transformedImageWithImage:originalImage forKey:key];
        if (transformedImage && finished) {
				/// 1
        } else {
				callCompletionBlock
        }
    }
});        
```

转换成功后，会依据 `cacheData = [cacheSerializer cacheDataWithImage: originalData: imageURL:];`  进行 `[self storageImage: ...]`存储图片。存储结束后 callCompletionBlock。



## 总结

如果你能看到这里，还是很有耐心的。希望大家看完能够大概了解 SD 的 work-flow，以及一些细节上的处理和思考。在 SD 5.x 中，个人感受最多的是其架构的设计值得借鉴。

- 如何设计一个稳定可扩展的 API 又能安全地支持动态添加参数？
- 如果设计一个解耦又可动态插拔的架构？

最后，这篇其实还少了 SDImageCoder，这个留到下一篇的 SDWebImage 插件及其扩展上来说。

