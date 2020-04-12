---
title: "The Architecture of SDWebImage v5.6"
date: 2020-04-12T23:08:12+17:00
tags: ['SourceCode', 'iOS', 'cache', 'SourceCode']
categories: ['iOS', 'Objc', 'En']
author: "土土Edmond木"
---

This article is based on SDWebImage 5.6. Why i write this article, cause i found that SD's API is constantly iterating, and many of the structures are different from earlier versions. Here is to make a record. We will start from the top of the API's level list below, force on the entire framework's data flow.

![highlevel](https://raw.githubusercontent.com/SDWebImage/SDWebImage/master/Docs/Diagrams/SDWebImageHighLevelDiagram.jpeg)



## 5.0 Migration Guid

It is highly recommended to watch the official [migration document](https://github.com/SDWebImage/SDWebImage/wiki/5.0-Migration-guide), which mentioned the mainly features in version 5.0.

- Brand new Animated Image View (was `FLAnimatedImageView` in 4.0);
- Image Transform is provided to easy way to scale, rotate, rounded corner and other operations after the image was downloaded;
- Customization, you can customize [cache](https://github.com/SDWebImage/SDWebImage/wiki/Advanced-Usage#custom-cache-50), [loader](https://github.com/SDWebImage/SDWebImage/wiki/Advanced-Usage#custom-loader-50), [coder](https://github.com/SDWebImage/SDWebImage/wiki/Advanced-Usage#custom-coder-420), which are base on the protocol;
- Added View Indicator to identify the loading status of Image;

I could say that the protocolization for the core classes is the biggest change in the 5.x SD version, which means the image request, loading, decoding, caching and other operations are pluggable and replaceable as you want.

So, let's see the main part first:

| 4.x                               | 5.x                             |
| --------------------------------- | ------------------------------- |
| SDWebImageCacheSerializerBlock    | id\<SDWebImageCacheSerializer\> |
| SDWebImageCacheKeyFilterBlock     | id\<SDWebImageCacheKeyFilter\>  |
| SDWebImageDownloader              | id\<SDImageLoader\>             |
| SDImageCache                      | id\<SDImageCache\>              |
| SDWebImageDownloaderProgressBlock | id\<SDWebImageIndicator>        |
| FLAnimatedImageView               | id\<SDAnimatedImage\>           |



## View Category

All the view's convenience method for image operation are base on `UIView + WebCache`, including the following:

- UIImageView+HighlightedWebCache
- UIImageView+WebCache
- UIView+WebCacheOperation
- UIButton+WebCache
- NSButton+WebCache

Firstly, let ’s take a look at [SDWebImageCompat.h](https://github.com/SDWebImage/SDWebImage/blob/09f06159a3284f6981d5495728e5c3cb3dfb82fa/SDWebImage/Core/SDWebImageCompat.h) ,  which defines **SD_MAC, SD_UIKIT, SD_WATCH** macros are used to Simplify the definition of the system, and used to unify the differences platforms API, such as using `# define UIImage NSImage` to redefine NSImage to UIImage. Another thing you would like to know is:

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

different from the earler version:

```objective-c
#define dispatch_main_async_safe(block)\
    if ([NSThread isMainThread]) {\
        block();\
    } else {\
        dispatch_async(dispatch_get_main_queue(), block);\
    }
#endif
```

-  use `#ifndef` to prevent repeated definition of `dispatch_main_async_safe`;
-  Main thread detect change from `isMainThread` to `dispatch_queue_t` label

Abount the second point, here is a [Discussion of SD](https://github.com/SDWebImage/SDWebImage/pull/781), and another explanation [GCD's Main Queue vs. Main Thread](http://blog.benjamin-encz.de/post/main-queue-vs-main-thread/))


> Calling an API from a non-main queue that is executing on the main thread will lead to issues if the library (like VektorKit) relies on checking for execution on the main queue.

Cause **tasks in the main queue must be put into the main thread to execute**.



Compared to the category of UIImageView, UIButton needs to store images under different `UIControlState` and backgrounImage, and SD associate has an internal dictionary ` (NSMutableDictionary <NSString *, NSURL *> *) sd_imageURLStorage` to store the images.

All view category's `setImageUrl:` finally refer to the following method:

```objective-c
- (void)sd_internalSetImageWithURL:(nullable NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholder
                           options:(SDWebImageOptions)options
                           context:(nullable SDWebImageContext *)context
                     setImageBlock:(nullable SDSetImageBlock)setImageBlock
                          progress:(nullable SDImageLoaderProgressBlock)progressBlock
                         completed:(nullable SDInternalCompletionBlock)completedBlock;
```

This method's implementation is quite long, here is the briefly describes:

1. Copy and convert `SDWebImageContext` to immutable, get the value of ` validOperationKey` as the verification id, the default value is the class name of the current view;
2. Call `sd_cancelImageLoadOperationWithKey` to cancel the last task, which to ensure that there is no asynchronous download operation currently in progress and no conflict with the upcoming operation;
3. Set the placeholder image;
4. Initialize `SDWebImageManager` , ` SDImageLoaderProgressBlock` , reset `NSProgress`, ` SDWebImageIndicator`;
5. Start downloading, call `loadImageWithURL:` and save the returned `SDWebImageOperation` into ` sd_operationDictionary`, which key is `validOperationKey`;
6. After getting the picture, call `sd_setImage:` and add transition animation to the new image;
7. Stop the indicator after the animation ends.



A tips, the `SDWebImageOperation` is a **strong-weak** NSMapTable, which is also added by the associated value:

```objective-c
// key is strong, value is weak because operation instance is retained by SDWebImageManager's runningOperations property
// we should use lock to keep thread-safe because these method may not be acessed from main queue
typedef NSMapTable<NSString *, id<SDWebImageOperation>> SDOperationsDictionary;
```

Weak is used because the operation instance is stored in SDWebImageManager's runningOperations, and the reference here is saved to easy cancel the task.



### SDWebImageContext

> A SDWebImageContext object which hold the original context options from top-level API.

Image context runs through the entire workflow of image processing. It brings data into each processing task step by step. There are two types of ImageContext:

```objectivec
typedef NSString * SDWebImageContextOption NS_EXTENSIBLE_STRING_ENUM;
typedef NSDictionary<SDWebImageContextOption, id> SDWebImageContext;
typedef NSMutableDictionary<SDWebImageContextOption, id>SDWebImageMutableContext;
```

SDWebImageContextOption is an extensible String enumeration, there are currently 15 types. Basically, you can guess its function just by looking at the name, here is the [document](https://github.com/SDWebImage/SDWebImage/blob/5c3c40288f7e465ba94db9736e624f663831951a/SDWebImage/Core/SDWebImageDefine.h), summarized as follows:

![image context](http://ww1.sinaimg.cn/large/8157560cgy1gcbeto2gb6j20xj1whajv.jpg)



## ImagePrefetcher

Prefetcher has nothing to do with the entire processing stream of SD. It mainly uses imageManger for batch image download. Below is the core method:

```objective-c
- (nullable SDWebImagePrefetchToken *)prefetchURLs:(nullable NSArray<NSURL *> *)urls
                                          progress:(nullable SDWebImagePrefetcherProgressBlock)progressBlock
                                         completed:(nullable SDWebImagePrefetcherCompletionBlock)completionBlock;
```

It stores the downloaded URLs as `transactions` in `SDWebImagePrefetchToken`,  which do not cancel previous request and it separate different prefetching process. When you call `prefetchURLs` for different url lists, you can get callback for different completion block.

Each download task is in the autoreleasesepool, and will use `SDAsyncBlockOperation` to wrap the real download task to achieve the cancelable operation of the task:

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

Finally, the task is stored in prefetchQueue, which limit the maximum number of downloads to 3 by default. The real task of URLs downloading is in `token.loadOperations`:

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

`loadOperations` and `prefetchOperations` All use **NSPointerArray**, which uses its [NSPointerFunctionsWeakMemory](apple-reference-documentation: // hcx77yk4jV) feature and can store ` Null` values, although its performance is not very good, see: [basic collection Class](https://objccn.io/issue-7-1/)

Another important thing is that PrefetchToken use the [c++11 memory_order_relaxed](https://zhuanlan.zhihu.com/p/45566448) to ensure the thread-safe。

```c++
atomic_ulong _skippedCount;
atomic_ulong _finishedCount;
atomic_flag  _isAllFinished;
    
unsigned long _totalCount;
```

Simply, it use memory order and atomic operations to achieve lock-free concurrency and improving efficiency.



## ImageLoader

ImageLoader is the default implementation of the `SDImageLoader` protocol, which provides HTTP / HTTPS / FTP or local URL NSURLSession source image acquisition capabilities. And it also maximizes the configurability of the entire download process. Main interface as fellow:

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

the **downloaderConfig** supports the NSCopy protocol, below is the main configurations provided:

```objective-c
/// The maximum number of concurrent downloads.
@property (nonatomic, assign) NSInteger maxConcurrentDownloads;
/// The timeout value (in seconds) for each download operation.
@property (nonatomic, assign) NSTimeInterval downloadTimeout;
/// The session configuration, it's immutable after the downloader instance initialized. 
@property (nonatomic, strong, nullable) NSURLSessionConfiguration *sessionConfiguration;
/// Passing `NSOperation<SDWebImageDownloaderOperation>` to set as default. Passing `nil` will revert to `SDWebImageDownloaderOperation`.
@property (nonatomic, assign, nullable) Class operationClass;
/// The download operations execution order, default is FIFO
@property (nonatomic, assign) SDWebImageDownloaderExecutionOrder executionOrder;
```

the **requestModifier**, provide modification before download request, 

```objective-c
/// Modify the original URL request and return a new one instead. You can modify the HTTP header, cachePolicy, etc for this URL.
@protocol SDWebImageDownloaderRequestModifier <NSObject>
   
- (nullable NSURLRequest *)modifiedRequestWithRequest:(nonnull NSURLRequest *)request;

@end
```

Similarly, the **responseModifier** provides modification of the return value,

```objective-c
/// Modify the original URL response and return a new response. You can use this to check MIME-Type, mock server response, etc.

@protocol SDWebImageDownloaderResponseModifier <NSObject>

- (nullable NSURLResponse *)modifiedResponseWithResponse:(nonnull NSURLResponse *)response;

@end
```

The last **decryptor** is used for image decryption, which provides base64 conversion of imageData by default.

```objective-c
/// Decrypt the original download data and return a new data. You can use this to decrypt the data using your perfereed algorithm.
@protocol SDWebImageDownloaderDecryptor <NSObject>

- (nullable NSData *)decryptedDataWithData:(nonnull NSData *)data response:(nullable NSURLResponse *)response;

@end
```

Processing data through these protocolded objects origins the **[strategy pattern](https://www.wikiwand.com/en/Strategy_pattern)**. By obtaining the protocol object through configuration, the caller only needs to care about the method provided by the protocol object, and does not need to care about its internal implementation to achieve the purpose of decoupling.



###DownloadImageWithURL

Before downloading, check whether the URL exists. 

If not, directly throw an error and return. After getting the URL, try to reuse the operation generated before:

```objective-c
NSOperation<SDWebImageDownloaderOperation> *operation = [self.URLOperations objectForKey:url];
```

If operation exists, call

```objective-c
@synchronized (operation) {
    downloadOperationCancelToken = [operation addHandlersForProgress:progressBlock completed:completedBlock];
}
```

And set the queuePriority. Here the `@synchronized (operation)` is used to compare the `@synchronized (self)`, which is used inside the operation to ensure the thread safety of the operation between two different classes. Because the operation may be passed to the decoding or proxy queue. 

Then  `addHandlersForProgres` method will save progressBlock and completedBlock into `NSMutableDictionary <NSString *, id> SDCallbacksDictionary` and then return and save it into downloadOperationCancelToken.

In addition, operation in `addHandlersForProgress` method does not clear the previous stored callbacks. They are saved increamently, which means that all the callBacks will be executed in sequence after download completion.

If the operation is nil、isFinished or isCancelled will call `createDownloaderOperationWithUrl:options:context:` to create a new operation and store it in URLOperations and configure completionBlock. So that URLOperations can be cleared when the task is completed. Then call `addHandlersForProgress:completed:` to save progressBlock and completedBlock. At last submit operation to the downloadQueue.

The final operation, url, request, and downloadOperationCancelToken are packaged into **SDWebImageDownloadToken**, which the end of the download task.



###CreateDownloaderOperation

After downloading, let's talk about how the operation is created. The first is to generate a URLRequest:

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

It is mainly configured by obtaining parameters through SDWebImageDownloaderOptions. The timeout is determined by downloader's `config.downloadTimeout`, the default is 15s. 

Then remove `id <SDWebImageDownloaderRequestModifier> requestModifier` from imageContext to transform the request.

```objective-c
// Request Modifier
id<SDWebImageDownloaderRequestModifier> requestModifier;
if ([context valueForKey:SDWebImageContextDownloadRequestModifier]) {
    requestModifier = [context valueForKey:SDWebImageContextDownloadRequestModifier];
} else {
    requestModifier = self.requestModifier;
}
```

What you need to pay attention to is that the access to requestModifier has **priority**, and the priority obtained through imageContext is higher than the downloader. This kind of method not only satisfies the controllability of the caller, but also supports the global configuration, which is suitable for all ages. 

Similarly, `id <SDWebImageDownloaderResponseModifier> responseModifier` and` id <SDWebImageDownloaderDecryptor> decryptor` are also the same approach.

After that, the confirmed responseModifier and decryptor will be saved in imageContext again for later use.

Finally, remove operationClass from downloaderConfig to create operation:

```objective-c
Class operationClass = self.config.operationClass;
if (operationClass && [operationClass isSubclassOfClass:[NSOperation class]] && [operationClass conformsToProtocol:@protocol(SDWebImageDownloaderOperation)]) {
    // Custom operation class
} else {
    operationClass = [SDWebImageDownloaderOperation class];
}
NSOperation<SDWebImageDownloaderOperation> *operation = [[operationClass alloc] initWithRequest:request inSession:self.session options:options context:context];
```

Set the *credential, minimumProgressInterval, queuePriority, pendingOperation*.

By default, each task is added to the downloadQueue in FIFO order. If you set it as LIFO, the task priority will be modified before adding to the queue:

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



###Data Processing

SDWebImageDownloaderOperation is also a protocolization class, which confirm NSURLSessionTaskDelegate, NSURLSessionDataDelegate. It handles URL request data, supports background downloading, supports responseData modification (by responseModifier), and supports download ImageData decryption (by decryptor). The main internal properties are as follows:

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

There is nothing special about initialization. You should noted that the `nullable session` passed here is saved with unownedSessin, which is different from the **ownedSession** generated by default internally. If the session is empty during initialization, the ownedSession will be created at `start`.

Then the problem is coming, because we need to observe the various states of the session, we need to set up the delegate.

```objective-c
[NSURLSession sessionWithConfiguration:delegate:delegateQueue:];
```

The delegate of the ownedSession is undoubtedly inside the operation, while the delegate of unownedSessin is the downloader. It will retrieve the operation through taskID and forwarding of the callback through the operation's delegate. Here is the code:

```objective-c
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    
    // Identify the operation that runs this task and pass it the delegate method
    NSOperation<SDWebImageDownloaderOperation> *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) {
        [dataOperation URLSession:session task:task didCompleteWithError:error];
    }
}
```

Then, as a real consumer operation trigger the download task. The entire download process including start, end, and cancellation will send corresponding notifications.

1. In **didReceiveResponse**, `response.expectedContentLength` will be saved as expectedSize. Then call `modifiedResponseWithResponse:` to save the edited response.

2. Every time **didReceiveData** will append data to imageData: `[self.imageData appendData: data]`, update receivedSize`self.receivedSize = self.imageData.length`. Finally, when receivedSize bigger then expectedSize, which means the download task is completed,  and move to the next stage. If you support `SDWebImageDownloaderProgressiveLoad`, you will be able to decoding while downloading in coderQueue:

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

​		Otherwise, the decoding operation will be completed when **didCompleteWithError**: `SDImageLoaderDecodeImageData`, but you need to decrypt it before decoding:

```objective-c
if (imageData && self.decryptor) {
    imageData = [self.decryptor decryptedDataWithData:imageData response:self.response];
}
```

​	3. Handle the complete callback;

*We will talk about the logic of decode finally.*



## ImageCache

The design of Cache classes are consistent with the ImageLoader. There will be a **SDImageCacheConfig** to configure the cache expiration time, capacity, read and write permissions, and dynamically MemoryCache / DiskCache class.

The main properties of SDImageCacheConfig are as follows:

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

MemoryCache and DiskCache instantiation depends on SDImageCacheConfig:

```objective-c
/// SDMemoryCache
- (nonnull instancetype)initWithConfig:(nonnull SDImageCacheConfig *)config;
/// SDDiskCache
- (nullable instancetype)initWithCachePath:(nonnull NSString *)cachePath config:(nonnull SDImageCacheConfig *)config;
```

As a cache protocol, their interface declarations are basically the same, all of which are CURD for data. The difference is that MemoryCache Protocl operates on the **id** type (NSCache's limitation), and DiskCache is on NSData.

### SDMemoryCache

```objective-c
/**
 A memory cache which auto purge the cache on memory warning and support weak cache.
 */
@interface SDMemoryCache <KeyType, ObjectType> : NSCache <KeyType, ObjectType> <SDMemoryCache>

@property (nonatomic, strong, nonnull, readonly) SDImageCacheConfig *config;

@end
```

Internally, **NSCache** is the implementation for SDMemoryCache, and add **NSMapTable <KeyType, ObjectType> * weakCache** property, which use semaphore lock to ensure thread safety. The weak-cache is a feature added only on the *iOS / tvOS* platform, because on macOS, NSCache will not clear the corresponding cache, when receiving system memory warning. WeakCache uses strong-weak references without additional memory overhead and does not affect the life cycle of the object.

The role of weakCache is to restore the cache. It is controlled by the **shouldUseWeakMemoryCache** switch of CacheConfig. For details, you can check the [CacheConfig](https://github.com/SDWebImage/SDWebImage/blob/master/SDWebImage/Core/SDImageCacheConfig.h). 

First, look at how *objectForKey* is implemented:

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

Since NSCache follows  [`NSDiscardableContent`](apple-reference-documentation://hcnVx1bA-q) to store temporary objects. When the memory is tight, the cached objects may be cleaned up by the system. At this time, once the application accesses MemoryCache and the cache missing, which will be transferred to the diskCache query operation. And that may cause the image to flicker. And when shouldUseWeakMemoryCache is true, because weakCache holds the weak reference of the object (when the object is cleaned by NSCache but not released), we can get the cache by weakCache and stuff it into NSCache, which will reduces disk I/O.



### SDDiskCache

This is simpler, internally uses NSFileManager to manage the reading and writing of image data, and calls SDDiskCacheFileNameForKey to process the key MD5 as fileName and store it in the diskCachePath directory. The other is to clear the expired cache:

1. Sort by SDImageCacheConfigExpireType to get `NSDirectoryEnumerator * fileEnumerator` and start filtering;
2. Use `cacheConfig.maxDiskAage` to determine whether it is expired, and store the expired URL in urlsToDelete;
3. Call `[self.fileManager removeItemAtURL: fileURL error: nil];`
4. According to `cacheConfig.maxDiskSize` to delete the data cached on the disk, clean up to 1/2 of maxDiskSize.

By the way, SDDiskCache, like **[YYKVStorage](https://github.com/ibireme/YYCache/blob/master/YYCache/YYKVStorage.h)**, also supports adding extendData to UIImage to store additional information, for example, the zoom ratio of the picture, [URL rich link](https://sspai.com/post/55279), time And other data.

However, **YYKVStorage** store the extended_data field by the ***manifest*** table in the database. SDDiskCache solution is a different way, by use system API <sys/xattr.h> **setxattr**, **getxattr**, **listxattr** to save extendData, which is really amazing. One more thing, the corresponding key is *SDDiskCacheExtendedAttributeName*.



### SDImageCache

It is also a protocold class, which is responsible for scheduling SDMemoryCache and SDDiskCache, and its Properties are as follows:

```objective-c
@property (nonatomic, strong, readwrite, nonnull) id<SDMemoryCache> memoryCache;
@property (nonatomic, strong, readwrite, nonnull) id<SDDiskCache> diskCache;
@property (nonatomic, copy, readwrite, nonnull) SDImageCacheConfig *config;
@property (nonatomic, copy, readwrite, nonnull) NSString *diskCachePath;
@property (nonatomic, strong, nullable) dispatch_queue_t ioQueue;
```

> Note: The memoryCache and diskCache instances are generated according to the class defined in CacheConfig, and the defaults are SDMemoryCache and SDDiskCache.

Let's take a look at its core method:

```objective-c
- (void)storeImage:(nullable UIImage *)image
         imageData:(nullable NSData *)imageData
            forKey:(nullable NSString *)key
          toMemory:(BOOL)toMemory
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock;
```

1. Make sure that image and key exist;

2. When **shouldCacheImagesInMemory** is YES, it calls `[self.memoryCache setObject:image forKey:key cost:cost]` to write memoryCache;

3. Write diskCache, put the operation logic into ioQueue and autoreleasepool.

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



Another important method is image query, which is defined in the SDImageCache protocol:

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

**queryImageForKey** converts SDWebImageOptions to SDImageCacheOptions, then call `queryCacheOperationForKey:`, which logic is as follows:

First, First, if the query key exists, the transformer will be obtained from the imageContext and the query key will be converted:

```objective-c
key = SDTransformedKeyForKey(key, transformerKey);
```

Try to get the image from the memory cache, if it exists:

1. If SDImageCacheDecodeFirstFrameOnly is satisfied and comforts to SDAnimatedImage protocol, CGImage will be taken out for conversion

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

2. If SDImageCacheMatchAnimatedImageClass is satisfied, it will be forced to check whether the image type matches, otherwise the data will be nil:

   ```objective-c
   // Check image class matching
   Class animatedImageClass = image.class;
   Class desiredImageClass = context[SDWebImageContextAnimatedImageClass];
   if (desiredImageClass && ![animatedImageClass isSubclassOfClass:desiredImageClass]) {
       image = nil;
   }
   ```

When the image can be obtained from the memory cache and is SDImageCacheQueryMemoryData, return directly, otherwise continue;

Start reading diskCache, and use shouldQueryDiskSync to specify query cache sync/async behavior.

```objective-c
// Check whether we need to synchronously query disk
// 1. in-memory cache hit & memoryDataSync
// 2. in-memory cache miss & diskDataSync
BOOL shouldQueryDiskSync = ((image && options & SDImageCacheQueryMemoryDataSync) ||
                            (!image && options & SDImageCacheQueryDiskDataSync));
```

The entire diskQuery is stored in queryDiskBlock and wrapped with autorelease:

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

For large amounts of temporary memory operations, SD will put it into autoreleasepool to ensure that the memory can be released in time.

**Special emphasis**, once the code is executed here, there must be disk querying operations, so if you don't have to get imageData, you can use **SDImageCacheQueryMemoryData** to improve query efficiency.

One more thing, the conversion logic of `SDTransformedKeyForKey` is the transformerKey of **SDImageTransformer**, which is spliced behind the image key in order. E.g:

```objective-c
'image.png' |> flip(YES,NO) |> rotate(pi/4,YES)  => 
'image-SDImageFlippingTransformer(1,0)-SDImageRotationTransformer(0.78539816339,1).png'
```



## SDImageManaer

SDImageManger serves as the dispatch center of the entire library, who is the master of the above various logics. It connects the components in series, from View > Downloading > Decodering > Cache. The only core method it exposes is **loadImage**:

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



Let's briefly talk about the three left APIs cacheKeyFilter, cacheSerializer and optionsProcessor, the rest of which have been mentioned above.

**SDWebImageCacheKeyFilter**

By default, the `URL.absoluteString` is used as cacheKey, and if fileter is set, cacheKey will be replaced by `cacheKeyForURL:`;

**SDWebImageCacheSerializer**

By default, ImageCache will directly cache downloadData, and when we use other image formats for transmission, such as WEBP format, then the data with WEBP format will be storaged to the disk directly. This will cause a problem, every time when we query the image from the disk, we have to repeat the decoding operation. The CacheSerializer can directly convert downloadData to JPEG / PNG format NSData cache, thereby improving access efficiency.

**SDWebImageOptionsProcessor**

Used to control the global parameters in SDWebImageOptions and SDWebImageContext. E.g::

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

The first parameter of the method,  the **url**, which serves as the connection core of SD, was designed to be nullable. This design may be for the convenience of users. Internally through the nil judgment of the url and the compatibility with the NSString type (forced conversion to NSURL) to ensure the subsequent process, otherwise the call ends. 

After the download started, it was split into the following 6 methods:

- callCacheProcessForOperation
- callDownloadProcessForOperation
- callStoreCacheProcessForOperation
- callTransformProcessForOperation
- callCompletionBlockForOperation
- safelyRemoveOperationFromRunning

They are cache query, download, storage, conversion, execution callback, and cleanup callback. You can find that each method is delivered through the operation, which will be ready when the loadImage is loaded, then trigger the cache query.

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

The implementation of **loadImage** is relatively simple, and the core is to generate an operation then transfer it to a chache querey. 

After the operation is initialized, it will checks whether failedURLs contains the current url:

- If yes, and options is SDWebImageRetryFailed, directly return operation and retun;
- If pass, the operation will be stored in `runningOperations`. Enclose options and imageContext in **SDWebImageOptionsResult**.

then will update imageContext, mainly store the transformer, cacheKeyFilter, cacheSerializer as the global default setting, and then call **optionsProcessor** to fulfill user's custom options to modify imageContext again. 

If you see here from the front,  you should have an impression of this routine. The priority logic of requestModifer in the previous ImageLoader is similar to this, but the implementation is somewhat different. Finally, transfer to CacheProcess.

The operation of **loadImage** is a combineOperation, which is a combination of cache and loader operation tasks, so that it can clean up the cache query and download tasks in one step. The statement is as follows:

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

The cancel method provided by it will gradually check two types of opration and then call the cancel operation one by one.



####CallCacheProcessForOperation

First check the value of  **SDWebImageFromLoaderOnly** to determine whether need to start the download task directly. 

If yes, forward to downloadProcess.

Otherwise, create a query task through `imageCache` and save it to combineOperation's cacheOperation:

```objective-c
operation.cacheOperation = [self.imageCache queryImageForKey:key options:options context:context completion:^(UIImage * _Nullable cachedImage, NSData * _Nullable cachedData, SDImageCacheType cacheType) {
   if (!operation || operation.isCancelled) {
    	/// 1  
   }
  	/// 2
}];
```

There are two situations that need to be handled for the results of the cache query:

1. When the operation is executing in the queue and operaton was marked as canceled, will end the donwload task;
2. Otherwise, forward to downloadProcess.



####CallDownloadProcessForOperation

The most complex of the 6 methods. First, We need to decide whether we need to create a new download task, which is controlled by three variables:

```objective-c
BOOL shouldDownload = !SD_OPTIONS_CONTAINS(options, SDWebImageFromCacheOnly);
    shouldDownload &= (!cachedImage || options & SDWebImageRefreshCached);
    shouldDownload &= (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url]);
    shouldDownload &= [self.imageLoader canRequestImageForURL:url];
```

- check options value is set as SDWebImageFromCacheOnly or SDWebImageRefreshCached;
- check the delegate method **shouldDownloadImageForURL** value;
- check whether the imageLoader **canRequestImageForURL**;

1. If shouldDownload is NO, close the download task. And perform **callCompletionBlockForOperation** and**safelyRemoveOperationFromRunning**. By the way, if cacheImage exists, it will be returned with completionBlock.
2. If shouldDownload is YES, create a new download task and save it in combineOperation's loaderOperation. Before creating a new task, if cacheImage exist and SDWebImageRefreshCached is set, the cacheImage will be stored in imageContext (if not will create a imageContext).
3. After downloading, return to callBack, there are several situations to deal with:
   - If the operation is canceled, the downloaded image and data will be discarded. And call the completion block and close the download task ;
   - Error caused by reqeust is cacneled, call the completion block and close the download task ;
   - Image refresh hit the NSURLCache cache, do not call the completion block;
   - errro, **callCompletionBlockForOperation** and add url to failedURLs;
   - None of the above conditions, if successful by retry, will remove the url from failedURLs first, call **storeCacheProcess**;

    Finally, call the **safelyRemoveOperation** for operation which marked as finished;

   

####CallStoreCacheProcessForOperation

Pour out storeCacheType、originalStoreCacheType、transformer、cacheSerializer from imageContext. 

Check if it is necessary to store the converted image data, original data, and wait for the end of the cache storage:

```objective-c
BOOL shouldTransformImage = downloadedImage && (!downloadedImage.sd_isAnimated || (options & SDWebImageTransformAnimatedImage)) && transformer;
BOOL shouldCacheOriginal = downloadedImage && finished;
BOOL waitStoreCache = SD_OPTIONS_CONTAINS(options, SDWebImageWaitStoreCache);
```

If shouldCacheOriginal is NO, directly transfer to **transformProcess**. Otherwise, first confirm whether the storage type is the original data:

```objective-c
// normally use the store cache type, but if target image is transformed, use original store cache type instead
SDImageCacheType targetStoreCacheType = shouldTransformImage ? originalStoreCacheType : storeCacheType;
```

If cacheSerializer exists during storage, it will first convert the data format, and finally call `[self stroageImage: ...]`

When the storage is over, go to the last step, **transformProcess**.



####CallTransformProcessForOperation

Before the conversion starts, it will routinely judge whether it needs to be converted.

```objective-c
id<SDImageTransformer> transformer = context[SDWebImageContextImageTransformer];
id<SDWebImageCacheSerializer> cacheSerializer = context[SDWebImageContextCacheSerializer];
BOOL shouldTransformImage = originalImage && (!originalImage.sd_isAnimated || (options & SDWebImageTransformAnimatedImage)) && transformer;
BOOL waitStoreCache = SD_OPTIONS_CONTAINS(options, SDWebImageWaitStoreCache);
```

If conversion is required, it will enter the global queue to start processing:

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

After the conversion is successful, the image will be stored according to

```objective-c
cacheData = [cacheSerializer cacheDataWithImage: originalData: imageURL:];
```

After storing, call completion block. The end.



## The End

I am honored that you can reach here. I hope you can get a general understanding of the work-flow of SD, as well as some details of processing and thinking. In SD 5.x, the most personal feeling is that the design of its architecture is worth learning.

- How to design a stable and extensible API that can safely support dynamic parameter addition?
- How to design a decoupled and dynamically pluggable architecture?

Finally, this article actually lacks **SDImageCoder**, which will be left for the next SDWebImage plugin and its extension.

