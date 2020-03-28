---
title: "源码浅析 SDWebImage 5.5.2 - WebP Plugin"
date: 2020-03-11T23:08:12+08:00
tags: ['SourceCode', 'iOS', 'cache']
author: "土土Edmond木"
---

本文基于 SDWebImage 5.5.2。重读的原因也是由于发现它的 API 在不断迭代，许多结构已经不同与早期版本，同时也是为了做一个记录。整体分析可以查看上一篇文章：[源码浅析 SDWebImage 5.5.2](https://looseyi.github.io/post/SourceCode-sdweb/)。

本篇主要关于其插件系统，如何简单的通过插件来支持多样化的图片格式、支持系统图片加载，富文本 URL 加载，以及第三方插件的集成，比如 [Lottie](https://airbnb.design/lottie/)、[YYImage](https://github.com/ibireme/YYImage)、[YYCache](https://github.com/ibireme/YYCache)、[FLAnimatedImage](https://github.com/Flipboard/FLAnimatedImage)。目前支持的如下：

![plugins](http://ww1.sinaimg.cn/large/8157560cgy1gco39siml4j21n40lmgq0.jpg)

详细请看官方文档：[Documen Address](https://sdwebimage.github.io/)。



## Coder Plugins



我们先从 Coder 的 WebP 开始聊。上篇中只提过一嘴 Coder，这次会稍微具体展开介绍。[WebP](https://developers.google.com/speed/webp) 图片格式是由狗爹提出的一种图片压缩格式。SD 在2013.10 SD 就已经支持的了 ([Tag: 3.5](https://github.com/SDWebImage/SDWebImage/releases/tag/3.5)) ，当时的做法是通过 CocoaPods 提供的 subspec 的方式来实现的，这个方式一直延续到了4.x 的最后一个版本，也就是在5.x 协议化后去掉的。原来是这么做的：

```ruby
s.subspec 'WebP' do |webp|
    webp.source_files = 'SDWebImage/UIImage+WebP.{h,m}'
    webp.xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) SD_WEBP=1' }
    webp.dependency 'SDWebImage/Core'
    webp.dependency 'libwebp'
end
```

大家如果对 subspec 不太熟悉，可以看 [subspec 文档](https://guides.cocoapods.org/syntax/podspec.html#subspec)，你可以理解他是当前 Podspec 的一个子集，也可以定义自己的 source_files、dependency、resource_bundle 等，所支持的配置与 Podspec 差不多。

如果我们要开启 WebP 的话就是通过 `pod 'SDWebImage/WebP'` 或者 `pod 'SDWebImage', subspecs: ['WebP']` 来设置。可以看到它时通过修改 xcodefig 中预编译宏 `GCC_PREPROCESSOR_DEFINITIONS` 的 **SD_WEBP=1** 作为标记。然后内部通过 SD_WEBP 这个宏来达到条件编译的效果。

当我们仅需要支持一种图片格式时，是比较简单的，一旦有更多格式需要支持的话，用宏来控制就比较痛苦了：

- 类似 SD_WEBP 的宏满天飞，维护性差；
- 当需要支持新格式时，必须更改核心代码，稳定性差；
- 没有全局标识指明当前操作的图片格式，API 模糊不清，便利性差；

至此，迎来了 5.x 的 **SDImageCoder** 协议。

整个 pod **SDWebImageWebPCoder** 就两文件，其中的 `UIImage+WebP.h` 还仅是对 `+[SDImageWebPCoder decodedImageWithData]` 的包装。而 WebPCoder 声明如下：

```objective-c
@interface SDImageWebPCoder : NSObject <SDProgressiveImageCoder, SDAnimatedImageCoder>

@property (nonatomic, class, readonly, nonnull) SDImageWebPCoder *sharedCoder;

@end
```

够简单吧。不过，主要是看 **SDImageCoder** 和 **SDAnimatedImageCoder** 协议：

```objective-c
@protocol SDImageCoder <NSObject>

@required
#pragma mark - Decoding
- (BOOL)canDecodeFromData:(nullable NSData *)data;
/// 如果支持动图，可通过`+[SDImageCoderHelper animatedImageWithFrames:]` 来生成各帧的图片.
- (nullable UIImage *)decodedImageWithData:(nullable NSData *)data
                                   options:(nullable SDImageCoderOptions *)options;

#pragma mark - Encoding
- (BOOL)canEncodeToFormat:(SDImageFormat)format NS_SWIFT_NAME(canEncode(to:));

/// 如果支持动图，可通过 `+[SDImageCoderHelper framesFromAnimatedImage:]` 将各帧集合成动图.
- (nullable NSData *)encodedDataWithImage:(nullable UIImage *)image
                                   format:(SDImageFormat)format
                                  options:(nullable SDImageCoderOptions *)options;

@end


@protocol SDAnimatedImageCoder <SDImageCoder, SDAnimatedImageProvider>

@required
- (nullable instancetype)initWithAnimatedImageData:(nullable NSData *)data options:(nullable SDImageCoderOptions *)options;

@end
```

**SDProgressiveImageCoder** 协议就不列出来了，大同小异。So，内部实现就是围绕这几个方法来实现的。



#### **ImageContentType**

说实现之前，需要说明一个问题，**如何通过 image data 分辨出图片格式 ？** 我们需要回到 SD 的 `NSData+ImageContentType.h` 看看它所支持的图片格式：

```objective-c
typedef NSInteger SDImageFormat NS_TYPED_EXTENSIBLE_ENUM;
static const SDImageFormat SDImageFormatUndefined = -1;
static const SDImageFormat SDImageFormatJPEG      = 0;
static const SDImageFormat SDImageFormatPNG       = 1;
static const SDImageFormat SDImageFormatGIF       = 2;
static const SDImageFormat SDImageFormatTIFF      = 3;
static const SDImageFormat SDImageFormatWebP      = 4;
static const SDImageFormat SDImageFormatHEIC      = 5;
static const SDImageFormat SDImageFormatHEIF      = 6;
static const SDImageFormat SDImageFormatPDF       = 7;
static const SDImageFormat SDImageFormatSVG       = 8;
```

发现没，这里的枚举定义方式与我们熟知的 `typedef NS_ENUM(NSInteger, xxx) {};` 不太一样。新东西 **NS_TYPED_EXTENSIBLE_ENUM** 可能你会比较陌生，不过，系统的 UILayoutPriority 也是可扩展枚举：

```objective-c
typedef float UILayoutPriority NS_TYPED_EXTENSIBLE_ENUM;
static const UILayoutPriority UILayoutPriorityRequired API_AVAILABLE(ios(6.0)) = 1000; 
...
```

关于它的说明网上比较少，这里找到篇相关的文章：[Why NS_TYPED_ENUM is the future](https://medium.com/@derrickho_28266/why-ns-typed-enum-is-the-future-c67ed8affe03)。

extensible enum 使用时很简单，而且它是 **Swift 兼容的 API** ，特点就是可扩展。它的想象力在哪里呢？当它和协议化后的类结合后，简直可以 *一个打十个* 。你可以不需要修改 SD 的核心代码，就能支持你想要的编码格式，真正的做到无入侵。是不是有一点点 *[Protocol-Oriented Programming](https://developer.apple.com/videos/play/wwdc2015/408/)* 的感觉。

该文章中提到的另一个 **NS_STRING_ENUM** 在 SD 中也有用到：

```objective-c
typedef NSString * SDImageCoderOption NS_STRING_ENUM;
FOUNDATION_EXPORT SDImageCoderOption _Nonnull const SDImageCoderDecodeFirstFrameOnly;
FOUNDATION_EXPORT SDImageCoderOption _Nonnull const SDImageCoderDecodeScaleFactor;
...
```

回到我们的 `NSData+ImageContentType.h` ，有三个方法：

```objective-c
@interface NSData (ImageContentType)
/// 通过 data 获取 image format
+ (SDImageFormat)sd_imageFormatForImageData:(nullable NSData *)data;
/// 通过 image format 转换 UTType
+ (nonnull CFStringRef)sd_UTTypeFromImageFormat:(SDImageFormat)format CF_RETURNS_NOT_RETAINED NS_SWIFT_NAME(sd_UTType(from:));
/// 通过 UTType 转换为 image format
+ (SDImageFormat)sd_imageFormatFromUTType:(nonnull CFStringRef)uttype;

@end
```

稍微提一下这里的 [UTType (Uniform Type Identifiers)](https://www.wikiwand.com/en/Uniform_Type_Identifier) 统一类型标识符是苹果在 Mac OS 10.4 提出的，它包括文本、图片、音频、视频格式等。这个[网站](https://escapetech.eu/manuals/qdrop/uti.html)有详细的列出了它支持的格式，以及 UTType的作用，也可参照 wiki。而目前 UTType 是没用支持 WebP 和 SVG 的，但是它是可以提供扩展的，本质上 UTType 就是一个纯文本的字符串而已。WebP 和 SVG 在 SD 中的定义如下：

```objective-c
// Currently Image/IO does not support WebP
#define kSDUTTypeWebP ((__bridge CFStringRef)@"public.webp")
#define kSVGTagEnd @"</svg>"
```

可以回答前面的问题：**如何通过 image data 分辨出图片格式 ？** 就是：**[FILE SIGNATURES TABLE](https://www.garykessler.net/library/file_sigs.html)**

> In [computing](https://www.wikiwand.com/en/Computer), a **file signature** is data used to identify or verify the contents of a file. In particular, it may refer to:
>
> - [File magic number](https://www.wikiwand.com/en/File_format#Magic_number): bytes within a file used to identify the format of the file; generally a short sequence of bytes (most are 2-4 bytes long) placed at the beginning of the file; see [list of file signatures](https://www.wikiwand.com/en/List_of_file_signatures)
> - [File checksum](https://www.wikiwand.com/en/Checksum) or more generally the result of a [hash function](https://www.wikiwand.com/en/Hash_function) over the file contents: data used to verify the integrity of the file contents, generally against transmission errors or malicious attacks. The signature can be included at the end of the file or in a separate file.

我们知道 Image 有两种描述方式：矢量图形或光栅图形(或称位图)，屏幕显示的都是位图，包含大量像素点信息。而为了提高对图片的传输和存储效率，都会采用一定算法对像素信息进行压缩。上面列出的各种格式则是对不同压缩算法的表示。由于图片数据都是  binary files，因此，按十六进制描述  JPEG 文件 file header 的字节序为：`FF D8` ，而 WebP 的则是 `57 45`：

```objective-c
52 49 46 46 xx xx xx xx						RIFF ....   //xx xx xx xx 是表示文件大小
57 45 42 50	 									WEBP
```

这里需要介绍一下 [WebP](https://developers.google.com/speed/webp/docs/riff_container#color_profile) 构成：

> WebP is an image format that uses either (i) the VP8 key frame encoding to compress image data in a lossy way, or (ii) the WebP lossless encoding (and possibly other encodings in the future). These encoding schemes should make it more efficient than currently used formats. It is optimized for fast image transfer over the network (e.g., for websites). The WebP format has feature parity (color profile, metadata, animation etc) with other formats as well. This document describes the structure of a WebP file.

WebP 是可以由多种编码压缩方式 (无损压缩、有损压缩[VP8](https://www.wikiwand.com/en/VP8)) + 颜色描述文件 ([ICC](https://fileinfo.com/extension/icc)) + 元数据 (metaData) + 多帧图片(动图) 组合的一种图片描述格式。同时 WebP 的这种描述格式是基于 [RIFF File Format](https://www.wikiwand.com/en/Resource_Interchange_File_Format)，RIFF (resource interchange file forma) 是一种资源交换文件格式，或者说通用的容器文件格式。更多信息这里就不展开了。



## [SDWebImageWebPCoder](https://github.com/SDWebImage/SDWebImageWebPCoder)



先看一眼 WebPCoder 有那些主要私有变量：

```objective-c
@implementation SDImageWebPCoder {
    WebPIDecoder *_idec; // incremental decoding 增量解码器
    WebPDemuxer *_demux; // image data 分离器
    WebPData *_webpdata; // Copied for progressive animation demuxer
    NSData *_imageData;
    NSUInteger _loopCount; // 动画循环次数
    NSUInteger _frameCount; // 动画帧数
    NSArray<SDWebPCoderFrame *> *_frames; // 动画帧数据集合
    CGContextRef _canvas; // 图片画布
    CGColorSpaceRef _colorSpace; // 图片 icc 彩色空间
    BOOL _hasAlpha;
    CGFloat _canvasWidth; // 图片画布宽度
    CGFloat _canvasHeight; // 图片画布高度
    NSUInteger _currentBlendIndex; //动画的当前混合帧率
}
```

稍微说明一下 demux 这个词 (de multiplex [音视频中的概念](https://blog.csdn.net/haomcu/article/details/7072707)) ，表示真心不懂。

以上数据均通过解析 WebP 数据获取，还有部分是通过 SDImageCoderOptions 获取的：

```objective-c
BOOL decodeFirstFrame = [options[SDImageCoderDecodeFirstFrameOnly] boolValue];
NSNumber *scaleFactor = options[SDImageCoderDecodeScaleFactor];
NSValue *thumbnailSizeValue = options[SDImageCoderDecodeThumbnailPixelSize];
NSNumber *preserveAspectRatioValue = options[SDImageCoderDecodePreserveAspectRatio];
```



### DecodedImage

开始解码前先生成 WebPData、WebPDemuxer、WebPIterator、CGColorSpaceRef 以及从 coder options 获取配置信息，简化后如下：

```objective-c
WebPData webpData;
WebPDataInit(&webpData);
webpData.bytes = data.bytes;
webpData.size = data.length;
WebPDemuxer *demuxer = WebPDemux(&webpData);

uint32_t flags = WebPDemuxGetI(demuxer, WEBP_FF_FORMAT_FLAGS);
BOOL hasAnimation = flags & ANIMATION_FLAG;

// 获取 coder options 配置 scale、thumnailSize、preserveAspectRatio、decodeFirstFrame
// ...

// for animated webp image
WebPIterator iter;
// libwebp's index start with 1
if (!WebPDemuxGetFrame(demuxer, 1, &iter)) {
    WebPDemuxReleaseIterator(&iter);
    WebPDemuxDelete(demuxer);
    return nil;
}
CGColorSpaceRef colorSpace = [self sd_createColorSpaceWithDemuxer:demuxer];
```

这里的 colorSpace 是通过读取 WebP 中的 [ICC color profile](https://developers.google.com/speed/webp/docs/riff_container#color_profile) 来生成的，如果没有则使用 `[SDImageCoderHelper colorSpaceGetDeviceRGB];`

在获取缩略图尺寸后会与 WebP 的图片 canvas size 对比，检查是否需要使用缩略图：

```objective-c
int canvasWidth = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_WIDTH);
int canvasHeight = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_HEIGHT);
CGSize scaledSize = SDCalculateThumbnailSize(CGSizeMake(canvasWidth, canvasHeight), preserveAspectRatio, thumbnailSize);
```

**AnimatedImage**

SD 在 5.x 推出了 SDAnimatedImage（protocol too) 正是为动图设计的，而 WebP 是支持动图的，因此这里的解码会区分是否为动图。

如果是单张图片则使用 `[self sd_createWebpImageWithData: colorSpace: scaledSize:]`  生成 CGImageRef 最后生成 image 并设置 `sd_imageFormat = SDImageFormatWebP`。

如果为动图，先初始化 [CGBitmapInfo](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_images/dq_images.html#//apple_ref/doc/uid/TP30001066-CH212-CJBHEGIB) 来提供位图的布局信息：

```objective-c
BOOL hasAlpha = config.input.has_alpha;
CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
```

我们先说为什么是使用 *kCGBitmapByteOrder32Host* ，我们知道 iPhone 是小端序，应该使用 *kCGBitmapByteOrder32Little* 才对，不过 32Host 是系统提供的一个宏，帮我们屏蔽了大小端端问题，定义如下：

```objective-c
#ifdef __BIG_ENDIAN__
    #define kCGBitmapByteOrder16Host kCGBitmapByteOrder16Big
    #define kCGBitmapByteOrder32Host kCGBitmapByteOrder32Big
#else /* Little endian. */
    #define kCGBitmapByteOrder16Host kCGBitmapByteOrder16Little
    #define kCGBitmapByteOrder32Host kCGBitmapByteOrder32Little
#endif
```

简单来说 Apple 的 GPU 仅支持 32 bit 的颜色格式，if not 则会消耗 CPU 进行颜色格式转换。具体可以看 [WWDC 2014 Session 419](http://blog.leichunfeng.com/blog/2017/02/20/talking-about-the-decompression-of-the-image-in-ios/) 。

剩下一个 alpa 信息是由 CGImageAlphaInfo 来控制，其定义如下：

```objective-c
ypedef CF_ENUM(uint32_t, CGImageAlphaInfo) {
    kCGImageAlphaNone,               /* For example, RGB. */
    kCGImageAlphaPremultipliedLast,  /* For example, premultiplied RGBA */
    kCGImageAlphaPremultipliedFirst, /* For example, premultiplied ARGB */
    kCGImageAlphaLast,               /* For example, non-premultiplied RGBA */
    kCGImageAlphaFirst,              /* For example, non-premultiplied ARGB */
    kCGImageAlphaNoneSkipLast,       /* For example, RBGX. */
    kCGImageAlphaNoneSkipFirst,      /* For example, XRGB. */
    kCGImageAlphaOnly                /* No color data, alpha data only */
};
```

[这里](https://blog.csdn.net/mydreamremindme/article/details/50817294?depth_1-utm_source=distribute.pc_relevant.none-task&utm_source=distribute.pc_relevant.none-task) 有一个解释关于 premutipled 的作用的说明，还蛮不错的。AlphaInfo 提供了三方面的信息：

- 是否有 alpha 值；
- 如有 alpha 值，alpha 所处位置 first or last，like RGBA or ARGB；
- 如有 alpha 值，每个颜色的分量是否已乘上 alpha 值。好处是可以避免 3 次的乘法运算。

关于具体的使用这里有一个[讨论](https://stackoverflow.com/questions/23723564/which-cgimagealphainfo-should-we-use) ，结论就是不包含 alpha 时用 `kCGImageAlphaNoneSkipFirst` ，否则使用 `kCGImageAlphaPremultipliedFirst`。

紧接着就是生成 canvas 和 iterator 开始每一帧的绘制：

```objective-c
CGContextRef canvas = CGBitmapContextCreate(NULL, canvasWidth, canvasHeight, 8, 0, [SDImageCoderHelper colorSpaceGetDeviceRGB], bitmapInfo);
if (!canvas) {
    WebPDemuxDelete(demuxer);
    CGColorSpaceRelease(colorSpace);
    return nil;
}
NSMutableArray<SDImageFrame *> *frames = [NSMutableArray array];

do {
    @autoreleasepool {
        CGImageRef imageRef = [self sd_drawnWebpImageWithCanvas:canvas iterator:iter colorSpace:colorSpace scaledSize:scaledSize];
        if (!imageRef) {
            continue;
        }

#if SD_UIKIT || SD_WATCH
        UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
#else
        UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:kCGImagePropertyOrientationUp];
#endif
        CGImageRelease(imageRef);
        
        NSTimeInterval duration = [self sd_frameDurationWithIterator:iter];
        SDImageFrame *frame = [SDImageFrame frameWithImage:image duration:duration];
        [frames addObject:frame];
    }
    
} while (WebPDemuxNextFrame(&iter));
```

最后释放对应 iterator、demuer、canvas、colorSpace，生成 animatedImage，decode 结束：

```objective-c
UIImage *animatedImage = [SDImageCoderHelper animatedImageWithFrames:frames];
animatedImage.sd_imageLoopCount = loopCount;
animatedImage.sd_imageFormat = SDImageFormatWebP;
```



### DrawnWebpImage

drawnWebImage 方法是用于生成动图的每一帧图片的，内部通过 CreateWebpImage 生成当前帧的 image 然后在 canvas 上进行混合操作（基于 canvas size），最后根据 scale size 进行一定比例缩放。blend 代码如下：

```objective-c
BOOL shouldBlend = iter.blend_method == WEBP_MUX_BLEND;

// If not blend, cover the target image rect. (firstly clear then draw)
if (!shouldBlend) {
    CGContextClearRect(canvas, imageRect);
}
CGContextDrawImage(canvas, imageRect, imageRef);
CGImageRef newImageRef = CGBitmapContextCreateImage(canvas);

CGImageRelease(imageRef);

if (iter.dispose_method == WEBP_MUX_DISPOSE_BACKGROUND) {
    CGContextClearRect(canvas, imageRect);
}
```

blend_method 是当前帧指定的混合方式，如果无需混合会清理当地画布再进图像转换。

```objective-c
// Blend operation (animation only). Indicates how transparent pixels of the
// current frame are blended with those of the previous canvas.
typedef enum WebPMuxAnimBlend {
  WEBP_MUX_BLEND,              // Blend.
  WEBP_MUX_NO_BLEND            // Do not blend.
} WebPMuxAnimBlend;
```

同时当前帧渲染结束还有一个 dispose_method 决定是否在下一帧渲染前清除当前 context：

```objective-c
// Dispose method (animation only). Indicates how the area used by the current
// frame is to be treated before rendering the next frame on the canvas.
typedef enum WebPMuxAnimDispose {
  WEBP_MUX_DISPOSE_NONE,       // Do not dispose.
  WEBP_MUX_DISPOSE_BACKGROUND  // Dispose to background color.
} WebPMuxAnimDispose;
```



### CreateWebpImage

创建图片会初始化 WebPDecoderConfig 以及检查 webp 图片完整性：

```objective-c
WebPDecoderConfig config;
if (!WebPInitDecoderConfig(&config)) {
    return nil;
}
// 检查 webp 图片完整性
if (WebPGetFeatures(webpData.bytes, webpData.size, &config.input) != VP8_STATUS_OK) {
    return nil;
}
```

WebPDecoderConfig 声明如下：

```c++
// Main object storing the configuration for advanced decoding.
struct WebPDecoderConfig {
  WebPBitstreamFeatures input;  // Immutable bitstream features (optional)
  WebPDecBuffer output;         // Output buffer (can point to external mem)
  WebPDecoderOptions options;   // Decoding options
};
```

对 WebPBitstreamFeatures、WebPDecBuffer、WebPDecoderOptions 具体包含数据类型可查看：[WebP Doc](https://developers.google.com/speed/webp/docs/api) 。在 SD 中对 config 做了如下设置：

```objective-c
config.options.use_threads = 1; // 开启多线程解码；
config.output.colorspace = MODE_bgrA; // 颜色空间指定为 RGBA 顺序；
// Use scaling for thumbnail
if (scaledSize.width != 0 && scaledSize.height != 0) {
    config.options.use_scaling = 1;
    config.options.scaled_width = scaledSize.width;
    config.options.scaled_height = scaledSize.height;
}
```

这里的 `MODE_bgrA` 是属于 [WEBP_CSP_MODE](https://code.woboq.org/qt5/include/webp/decode.h.html) 对 colorspace 的定义，不熟悉的可以看[苹果文档](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_color/dq_color.html#//apple_ref/doc/uid/TP30001066-CH205-TPXREF101) 。

配置完 decode Config，还有就是 CGBitmapInfo。 这个与 decode image 中的逻辑一样就不多说了，直接解码生成 CGImageRef：

```objective-c
// Decode the WebP image data into a RGBA value array
if (WebPDecode(webpData.bytes, webpData.size, &config) != VP8_STATUS_OK) {
    return nil;
}
// Construct a UIImage from the decoded RGBA value array
CGDataProviderRef provider =
CGDataProviderCreateWithData(NULL, config.output.u.RGBA.rgba, config.output.u.RGBA.size, FreeImageData);
size_t bitsPerComponent = 8;
size_t bitsPerPixel = 32;
size_t bytesPerRow = config.output.u.RGBA.stride;
size_t width = config.output.width;
size_t height = config.output.height;
CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
CGImageRef imageRef = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, colorSpaceRef, bitmapInfo, provider, NULL, NO, renderingIntent);

CGDataProviderRelease(provider);
```

这里在第一步创建 dataProvider 的时候就传入了 FreeImageData 作为 callback，保证结束后及时清理 data：

```objective-c
static void FreeImageData(void *info, const void *data, size_t size) {
    free((void *)data);
}
```

这里的 info 信息其实是 [CGDataProviderCreateWithData](https://developer.apple.com/documentation/coregraphics/1408288-cgdataprovidercreatewithdata?language=objc) 调用时传入的 NULL 它也可以是任意类型。

至此，WebP decode 核心实现已经差不多了，剩下的 ProgressCoder 和 SDAnimatedImageCoder 中的 decode 逻辑也都大同小异。稍微不同的，在于 AnimatedImage 内部会将 WebPIterator 增量的帧迭代器中的各帧数据存储到 SDWebPCoderFrame 中，可以说 SDWebPCoderFrame 就是 WebPIterator 的翻版。

```objective-c
@interface SDWebPCoderFrame : NSObject

@property (nonatomic, assign) NSUInteger index; // Frame index (zero based)
@property (nonatomic, assign) NSTimeInterval duration; // Frame duration in seconds
@property (nonatomic, assign) NSUInteger width; // Frame width
@property (nonatomic, assign) NSUInteger height; // Frame height
@property (nonatomic, assign) NSUInteger offsetX; // Frame origin.x in canvas (left-bottom based)
@property (nonatomic, assign) NSUInteger offsetY; // Frame origin.y in canvas (left-bottom based)
@property (nonatomic, assign) BOOL hasAlpha; // Whether frame contains alpha
@property (nonatomic, assign) BOOL isFullSize; // Whether frame size is equal to canvas size
@property (nonatomic, assign) BOOL shouldBlend; // Frame dispose method
@property (nonatomic, assign) BOOL shouldDispose; // Frame blend operation
@property (nonatomic, assign) NSUInteger blendFromIndex; // The nearest previous frame index which blend mode is WEBP_MUX_BLEND

@end
```

WebPIterator 可参照 [WebP 文档](https://developers.google.com/speed/webp/docs/container-api) 。



### EncodedImage

decode 逻辑与 encode 也基本是相反操作，细节先不表了。





## 总结

这篇，主要描述了 SD 的 Coder 插件是如何运行的，SD 当前所支持的 image 格式。以及如何为其添加新类型的图片格式并融入整个 SD 的处理流中。 重点介绍 WebP 解码的实现和相关 API，并未涉及太多 WebP 内部实现。





