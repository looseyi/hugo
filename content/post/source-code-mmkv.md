---
title: "源码浅析 - MMKV iOS"
date: 2020-02-08T23:23:47+08:00
tags: ['source-code', 'iOS', 'cache']
author: "土土Edmond木"
---

## **MMKV（官方介绍）**

>*MMKV 是基于 mmap 内存映射的 key-value 组件，底层序列化/反序列化使用 protobuf 实现，性能高，稳定性强。从 2015 年中至今在微信上使用，其性能和稳定性经过了时间的验证。近期也已移植到 Android / macOS / Windows 平台，一并开源。[github]( https://github.com/tencent/mmkv)*

官方文档中有详细的使用说明和性能对比。我们知道 *[NSUserDedefaults](https://developer.apple.com/documentation/foundation/nsuserdefaults)* 不过是一份简单的 XML 文件，连苹果提供的对 objc 对象进行 NSKeyArchive 的序列化方式也不过是 XML 文件的翻版。 因此，MMKV 不仅线程安全而且性能完爆 *NSUserdefaults*；



## **阅读须知**

本文主要以 iOS 源码解析为重点，不过开始之前需要了解三个概念 [*mmap*](https://www.wikiwand.com/en/Mmap)、[*Protobuf*](https://www.wikiwand.com/en/Protocol_Buffers)、[CRC校验](https://www.wikiwand.com/en/Cyclic_redundancy_check)。

#### **mmap wiki**

> *In computing, mmap(2) is a POSIX-compliant Unix system call that maps files or devices into memory. It is a method of memory-mapped file I/O. It implements demand paging, because file contents are not read from disk initially and do not use physical RAM at all. The actual reads from disk are performed in a “lazy” manner, after a specific location is accessed.*

有一篇[文章](https://www.cnblogs.com/huxiao-tee/p/4660352.html)解释的比较详细：

> *mmap是一种内存映射文件的方法，即将一个文件或者其它对象映射到进程的地址空间，实现文件磁盘地址和进程虚拟地址空间中一段虚拟地址的一一对映关系。实现这样的映射关系后，进程就可以采用指针的方式读写操作这一段内存，而系统会自动回写脏页面到对应的文件磁盘上，即完成了对文件的操作而不必再调用read,write等系统调用函数。相反，内核空间对这段区域的修改也直接反映用户空间，从而可以实现不同进程间的文件共享。*

简单来说，read/write 文件操作，需要页缓存作为内核和应用层的中转，因此一次文件操作需要两次数据拷贝（内核到页缓存，页缓存到应用层），而 mmap 实现了用户空间和内核空间的数据直接交互而省去了页缓存。 mmap 也正式由于直接映射内存，其使用场景则有所限制。如[苹果文档所说](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemAdvancedPT/MappingFilesIntoMemory/MappingFilesIntoMemory.html) ：

>File mapping is effective when:
>
>- You have a large file whose contents you want to access randomly one or more times.
>- You have a small file whose contents you want to read into memory all at once and access frequently. This technique is best for files that are no more than a few virtual memory pages in size.
>- You want to cache specific portions of a file in memory. File mapping eliminates the need to cache the data at all, which leaves more room in the system disk caches for other data.

因此，当我们需要高频率的访问某一较大文件中的一小部分内容的时候，mmap 的效率是最高的。

其实不光是 MMKV 包括微信的 XLog 和 美团的 Logan 日志工具，还有 SQLight 都使用 mmap 来提升高频更新场景下的文件访问效率。



#### **Protocol Buffer wiki**

> **Protocol Buffers** (**Protobuf**) is a method of [serializing](https://www.wikiwand.com/en/Serialization) structured data. It is useful in developing programs to communicate with each other over a wire or for storing data. The method involves an [interface description language](https://www.wikiwand.com/en/Interface_description_language) that describes the structure of some data and a program that generates source code from that description for generating or parsing a stream of bytes that represents the structured data.

Protobuf 是一种将结构化数据进行序列化的方法。它最初是为了解决服务器端新旧协议(高低版本)兼容性问题而诞生的。因此，称为“协议缓冲区”，只不过后期慢慢发展成用于传输数据和存储等。

MMKV 正式考虑到了 protobuf 在性能和空间上的不错表现，采用了简化版 protobuf 作为序列化方案，还扩展了 protobuf 的增量更新的能力，将增量 kv 对象序列化后，直接 append 到内存末尾进行序列化。

那 Protobuf 是如何实现高效编码？

1. 以 Tag - Value (Tag - Length - Value)的编码方式的实现，减少了分隔符的使用，数据存储更加紧凑。
2. 利用 base 128 varint (变长编码）原理压缩数据以后，二进制数据非常紧凑，pb 体积更小。不过 pb 并没有压缩到极限，float、double 浮点型都没有压缩。
3. 相比  JSON 和 XML 少了 {、}、: 这些符号，体积也减少一些。再加上 varint 压缩，gzip 压缩以后体积更小！



#### **CRC 校验**

> 循环冗余校验（英语：Cyclic redundancy check，通称“CRC”）是一种根据网络数据包或计算机文件等数据产生简短固定位数校验码的一种散列函数，主要用来检测或校验数据传输或者保存后可能出现的错误。生成的数字在传输或者存储之前计算出来并且附加到数据后面，然后接收方进行检验确定数据是否发生变化。

考虑到文件系统、操作系统都有一定的不稳定性，MMKV 增加了 CRC 校验，对无效数据进行甄别。在 iOS 微信现网环境上，有平均约 70万日次的数据校验不通过。



## **Implement**

开始之前先瞅一眼文件构成：

![class_name](http://ww1.sinaimg.cn/large/8157560cly1gbrnrhw7yvj20rs0ikgzw.jpg)

正如官方介绍所说的，确实比较轻量。除了AES 加密所需引入的 openssl 之外，protobuf 也是 mini 版的。其余的类就是 MMKV 实现的主要构成。



### **MMKV**



#### **+[MMKV initialize]**

```objective-c
+ (void)initialize {
	if (self == MMKV.class) {
		g_instanceDic = [NSMutableDictionary dictionary];
		g_instanceLock = [[NSRecursiveLock alloc] init];

		DEFAULT_MMAP_SIZE = getpagesize();
		MMKVInfo(@"pagesize:%d", DEFAULT_MMAP_SIZE);

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
		auto appState = [UIApplication sharedApplication].applicationState;
		g_isInBackground = (appState == UIApplicationStateBackground);
		MMKVInfo(@"g_isInBackground:%d, appState:%ld", g_isInBackground, appState);

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
#endif
	}
}
```

在 initialize 中初始化全局的 `g_instanceDic` ，并为其配了递归锁来保证线程安全。⚠️注意这里的 `g_instanceDic` 的初始化并未使用 `dispatch_once` 来保证唯一性，看了commit history 原先是有使用的，不过后来被当成冗余代码优化掉了。这里应该是考虑了cxx 的特性，其 static 变量在全局访问是安全的 (有知道原因的，求告知)。

接着会获取当前系统的 page size 赋值给 DEFAULT_MMAP_SIZE，作为是否需要进行内存整理和文件回写的限制，因为 mmap 所 mach 的内存大小受到 pageSize 的约束。

最后如果是 iphone 会接受通知来更新 `g_isInBackground` 的状态保证不同线程中的读写。



#### **+[MMKV mmkvWithID: cryptKey: relativePath:]**

```objective-c
+ (instancetype)mmkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey relativePath:(nullable NSString *)relativePath {
	if (mmapID.length <= 0) {
		return nil;
	}
	/// id + relativePath 生成 kvKey
	NSString *kvKey = [MMKV mmapKeyWithMMapID:mmapID relativePath:relativePath];
   /// 全局递归锁保证 g_instanceDic 的安全
	CScopedLock lock(g_instanceLock);

	MMKV *kv = [g_instanceDic objectForKey:kvKey];
	if (kv == nil) {
		NSString *kvPath = [MMKV mappedKVPathWithID:mmapID relativePath:relativePath];
		if (!isFileExist(kvPath)) {
			if (!createFile(kvPath)) {
				MMKVError(@"fail to create file at %@", kvPath);
				return nil;
			}
		}
		kv = [[MMKV alloc] initWithMMapID:kvKey cryptKey:cryptKey path:kvPath];
		[g_instanceDic setObject:kv forKey:kvKey];
	}
	return kv;
}
```

该方法通过对应 ID 来获取 MMKV 实例，所有实例都会以 (ID + relativePath) md5 后作为 key 存储在 `g_instanceDic`, 同时每个实例序列化后会经过 protobuf encode 后存在各自对应的文件中，文件名就是 ID。为了保证数据的可靠性，每个文件会有一份对应的 CRC 校验文件。

在数据安全方面，用户可以通过传入的 cryptKey 来进行 AES 加密，MMKV 是内嵌了 openssl 作为 AES 加密的基础。

所有的 MMKV 文件都是存储在同一个根目录中，可以通过 `-[initializeMMKV:]` 或者 `setMMKVBasePath` 在所有 MMKV 实例初始化前进行设置，而这里的 relativePath 则都是相对 `mmkvBasePath` 来配置的。

类似 `NSUserDefaults standerUserDefault` MMKV 提供了 defaultMMKV ，其 DEFAULT_MMAP_ID 为 @"mmkv.default"。MMKV 还提供了` -[migrateFromUserDefaults:]` 来方便迁移数据；

#### **mmkv instance**

```objc
NSRecursiveLock *m_lock; /// 递归锁，保证 m_dic 线程安全
NSMutableDictionary *m_dic; /// kv 容器，保存真正的键值对
NSString *m_path; // mmkv 的文件路径
NSString *m_crcPath; // mmkv 的 crc 校验文件路径
NSString *m_mmapID; // 唯一id，由 （mmkvID + relativePath）md5 后生成；
int m_fd; // 文件操作符
char *m_ptr; // 当前 kv 的文件操作指针 
size_t m_size; // mmap 所映射的文件 size
size_t m_actualSize; //当前 kv 占用内存大小
MiniCodedOutputData *m_output; // 映射内存所剩余空间
AESCrypt *m_cryptor; /// 加密器，文件内容更新后会重新计算加密值
MMKVMetaInfo m_metaInfo; // 保存了 crc 文件 digest

...
```

这里列了一部分 mmkv 的实例变量，在 mmkv init 时会根据参数优先初始化以下几个参数并调用 `loadFromFile` 将文件序列化到 m_dict 中。

> m_lock = [[NSRecursiveLock alloc] init];
>
> m_mmapID = kvKey;
>
> m_path = path;
>
> m_crcPath = [MMKV crcPathWithMappedKVPath:m_path];
>
> m_cryptor = AESCrypt((**const** **unsigned** **char** *) cryptKey.bytes, cryptKey.length);



#### **+[MMKV loadFromFile]**

loadFromFile 可以算是 mmkv 核心方法之一了。文件很长不过实现思路比较清晰；

```objective-c
- (void)loadFromFile {
	/// 1. 获取 crc 文件摘要，存入 m_metaInfo
	[self prepareMetaFile];
	if (m_metaFilePtr != nullptr && m_metaFilePtr != MAP_FAILED) {
		m_metaInfo.read(m_metaFilePtr);
	}
	if (m_cryptor) {
		if (m_metaInfo.m_version >= 2) {
			m_cryptor->reset(m_metaInfo.m_vector, sizeof(m_metaInfo.m_vector));
		}
	}
    /// 2. 获取 fild descriptor
	m_fd = open(m_path.UTF8String, O_RDWR | O_CREAT, S_IRWXU);
	if (m_fd < 0) {
		MMKVError(@"fail to open:%@, %s", m_path, strerror(errno));
	} else {
		/// 3. 依据文件 fd size 以及系统 pagesize（DEFAULT_MMAP_SIZE）进行取整计算文件 m_size;
		m_size = 0;
		struct stat st = {};
		if (fstat(m_fd, &st) != -1) {
			m_size = (size_t) st.st_size;
		}
		// round up to (n * pagesize)
		if (m_size < DEFAULT_MMAP_SIZE || (m_size % DEFAULT_MMAP_SIZE != 0)) {
			m_size = ((m_size / DEFAULT_MMAP_SIZE) + 1) * DEFAULT_MMAP_SIZE;
			if (ftruncate(m_fd, m_size) != 0) {
				MMKVError(@"fail to truncate [%@] to size %zu, %s", m_mmapID, m_size, strerror(errno));
				m_size = (size_t) st.st_size;
				return;
			}
		}
		/// 4。进行内存映射，通过 mmap 获取映射内存对应的文件的起始位置的地址
		m_ptr = (char *) mmap(nullptr, m_size, PROT_READ | PROT_WRITE, MAP_SHARED, m_fd, 0);
		if (m_ptr == MAP_FAILED) {
			MMKVError(@"fail to mmap [%@], %s", m_mmapID, strerror(errno));
		} else {
			/// 5. 通过 m_ptr 读取文件头部固定 4 字节长度数据 lenbuffer；
			///    利用 MiniCodedInputData 从 lenbuffer 中获取文件中真实存储数据的大小即 m_actualSize；
			const int offset = pbFixed32Size(0);
			NSData *lenBuffer = [NSData dataWithBytesNoCopy:m_ptr length:offset freeWhenDone:NO];
			@try {
				m_actualSize = MiniCodedInputData(lenBuffer).readFixed32();
			} @catch (NSException *exception) {
				MMKVError(@"%@", exception);
			}
			MMKVInfo(@"loading [%@] with %zu size in total, file size is %zu", m_mmapID, m_actualSize, m_size);
			if (m_actualSize > 0) {
				/// 6. 检查文件 m_actualSize 的正确性，失败则执行 `onMMKVFileLengthError` callback
				///    当检查失败且 error code 为 MMKVOnErrorRecover，则尝试数据回滚；
				bool loadFromFile, needFullWriteback = false;
				if (m_actualSize < m_size && m_actualSize + offset <= m_size) {
					if ([self checkFileCRCValid] == YES) {
						loadFromFile = true;
					} else {
						/// 7. 检查文件 CRC，确保文件无损，失败则执行 `onMMKVCRCCheckFail` callback
						loadFromFile = false;
						if (g_callbackHandler && [g_callbackHandler respondsToSelector:@selector(onMMKVCRCCheckFail:)]) {
							auto strategic = [g_callbackHandler onMMKVCRCCheckFail:m_mmapID];
							if (strategic == MMKVOnErrorRecover) {
								loadFromFile = true;
								needFullWriteback = true;
							}
						}
					}
				} else {
					MMKVError(@"load [%@] error: %zu size in total, file size is %zu", m_mmapID, m_actualSize, m_size);
					loadFromFile = false;
					if (g_callbackHandler && [g_callbackHandler respondsToSelector:@selector(onMMKVFileLengthError:)]) {
						auto strategic = [g_callbackHandler onMMKVFileLengthError:m_mmapID];
						if (strategic == MMKVOnErrorRecover) {
							loadFromFile = true;
							needFullWriteback = true;
							[self writeActualSize:m_size - offset];
						}
					}
				}
				/// 8. 检查文件 m_actualSize 的正确且文件无损开始读取文件内容，长度为 m_actualSize
				///    1. 进行 AES 解密；
				///    2. 进行 protobuf 解码, 赋值给 m_dic, 同时将文件剩余字节保存在 m_output 为之后存入数据准备；
				if (loadFromFile) {
					MMKVInfo(@"loading [%@] with crc %u sequence %u", m_mmapID, m_metaInfo.m_crcDigest, m_metaInfo.m_sequence);
					NSData *inputBuffer = [NSData dataWithBytesNoCopy:m_ptr + offset length:m_actualSize freeWhenDone:NO];
					if (m_cryptor) {
						inputBuffer = decryptBuffer(*m_cryptor, inputBuffer);
					}
					m_dic = [MiniPBCoder decodeContainerOfClass:NSMutableDictionary.class withValueClass:NSData.class fromData:inputBuffer];
					m_output = new MiniCodedOutputData(m_ptr + offset + m_actualSize, m_size - offset - m_actualSize);
					if (needFullWriteback) {
						[self fullWriteBack];
					}
				} else {
					[self writeActualSize:0];
					m_output = new MiniCodedOutputData(m_ptr + offset, m_size - offset);
					[self recaculateCRCDigest];
				}
			} else {
				m_output = new MiniCodedOutputData(m_ptr + offset, m_size - offset);
				[self recaculateCRCDigest];
			}
			MMKVInfo(@"loaded [%@] with %zu values", m_mmapID, (unsigned long) m_dic.count);
		}
	}
	if (m_dic == nil) {
		m_dic = [NSMutableDictionary dictionary];
	}

	if (![self isFileValid]) {
		MMKVWarning(@"[%@] file not valid", m_mmapID);
	}

	tryResetFileProtection(m_path);
	tryResetFileProtection(m_crcPath);
	m_needLoadFromFile = NO;
}
```



简单整理一下：

 1. 获取 crc 文件摘要，存入 m_metaInfo，保存 m_metaFd crc 的 file descriptor；
 2. 获取 mmkv fild descriptor；
  3. 依据文件 fd size 以及系统 pagesize（DEFAULT_MMAP_SIZE）进行取整计算文件 m_size;
  4. 进行内存映射，通过 mmap 获取映射内存对应的文件的起始位置的地址 m_ptr；
  5. 通过 m_ptr 读取文件头部固定 4 字节长度数据 lenbuffer，
    利用 MiniCodedInputData 从 lenbuffer 中获取文件中真实存储数据的大小即 m_actualSize；
  6. 检查文件 m_actualSize 的正确性，失败则执行 `onMMKVFileLengthError` callback，
    当检查失败且 error code 为 MMKVOnErrorRecover，则尝试数据回滚；
  7. 检查文件 CRC，确保文件无损，失败则执行 `onMMKVCRCCheckFail` callback；
  8. 检查文件 m_actualSize 的正确且文件无损开始读取文件内容，长度为 m_actualSize；
    1. 进行 AES 解密；
    2. 进行 protobuf 解码, 赋值给 m_dic, 同时将文件剩余字节保存在 m_output 为之后存入数据准备；
 9. tryResetFileProtection 保证文件的读写权限；



### **Setter**

我们先看一眼 MMKV 的赋值方法：

```objective-c
- (BOOL)setObject:(nullable NSObject<NSCoding> *)object forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setBool:(BOOL)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setInt32:(int32_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setUInt32:(uint32_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setInt64:(int64_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setUInt64:(uint64_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setFloat:(float)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setDouble:(double)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setString:(NSString *)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setDate:(NSDate *)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));

- (BOOL)setData:(NSData *)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
```

其接口的声明与 *NSUserDefaults* 基本一致，也支持 Swift 式 API。不同的是 MMKV 在更新对应的 value 后，不再需要手动调用 sync / async , 其内部会在取值的过程中进行 `-[MMKV checkLoadData]` 来检查数据并将数据同步写回 output。我们来看看具体实现：

```objective-c
/// ojbc 对象类型
- (BOOL)setObject:(nullable NSObject<NSCoding> *)object forKey:(NSString *)key {
	if (key.length <= 0) {
		return NO;
	}
	if (object == nil) {
		[self removeValueForKey:key];
		return YES;
	}

	NSData *data;
	if ([MiniPBCoder isMiniPBCoderCompatibleObject:object]) {
		data = [MiniPBCoder encodeDataWithObject:object];
	} else {
		/*if ([object conformsToProtocol:@protocol(NSCoding)])*/ {
			data = [NSKeyedArchiver archivedDataWithRootObject:object];
		}
	}

	return [self setRawData:data forKey:key];
}

/// 基本数据类型
- (BOOL)setBool:(BOOL)value forKey:(NSString *)key {
	if (key.length <= 0) {
		return NO;
	}
	size_t size = pbBoolSize(value);
	NSMutableData *data = [NSMutableData dataWithLength:size];
	MiniCodedOutputData output(data);
	output.writeBool(value);

	return [self setRawData:data forKey:key];
}
```

可以看出基本数据类型和 objc 对象类型最终都转换成 NSData 后统一调用 `-[MMKV setRawData: forKey:]`。不过这里的 data 都经过了 MiniCodedOutputData 的处理，进行了数据对齐。

我们先以 BOOL 为例，先获取 protobuffer 编码 bool 所需的 size 长度来初始化 `NSMutableData *data` 然后以 data 作为参数 new 了一个 `MiniCodedOutputData output(data)` 并将对应的 bool value 写入 output。这里的 writeBool 是按照 `MiniCodedOutputData` 中的字节序将 bool value 写入到 data 中来完成数据的对齐。最后调用 `-[setRawData: forKey:]`。



而 objc 对象在写入前需要进行 protobuf 的类型检查，对支持的数据类型直接进行序列化 `[MiniPBCoder encodeDataWithObject:]` ，不支持的则调用系统的 `[NSKeyedArchiver archivedDataWithRootObject:]`。MiniPBCoder 支持序列化的 objc 类型有：

> 	- NSString
> 	- NSData
> 	- NSDate

这里不太理解的地方在于，其内部实现是支持对 Dictionary 容器的编码的，但是在 `-[isMiniPBCoderCompatibleObject:]`中仅这三类返回为 YES。

#### **-[MiniPBCoder getEncodeData]**

`+[MiniPBCoder encodeDataWithObject:]` 以传入的 objc 作为参数初始化了 MiniPBCoder 对象，并调用 `getEncodeData` 以返回序列化后的数据。getEncodeData 实现如下：

```objective-c
- (NSData *)getEncodeData {
	if (m_outputBuffer != nil) {
		return m_outputBuffer;
	}

	m_encodeItems = new std::vector<MiniPBEncodeItem>();
	size_t index = [self prepareObjectForEncode:m_obj];
	MiniPBEncodeItem *oItem = (index < m_encodeItems->size()) ? &(*m_encodeItems)[index] : nullptr;
	if (oItem && oItem->compiledSize > 0) {
		// non-protobuf object(NSString/NSArray, etc) need to to write SIZE as well as DATA,
		// so compiledSize is used,
		m_outputBuffer = [NSMutableData dataWithLength:oItem->compiledSize];
		m_outputData = new MiniCodedOutputData(m_outputBuffer);

		[self writeRootObject];

		return m_outputBuffer;
	}

	return nil;
}
```

这里的核心是通过 `-[MiniPBCoder prepareObjectForEncode:]` 将 encode 对象转换为 `MiniPBEncodeItem` 后存入 `std::vector<MiniPBEncodeItem> *m_encodeItems` 这里使用 cxx 的 vector 是由于 encode 对象可能是 NSDictionary 字典类型，当是 NSDictionary 对象时则会递归调用 prepareObjectForEncode 将其 key、value 都转成 MiniPBEncodeItem 存入 m_encodeItems 中。

在获取到 m_encodeItems 后根据其 compiledSize 初始化 m_outputBuffer，同基础数据类型一样，m_encodeItems 最终也是转化成 `MiniCodedOutputData` 并调用 `-[MiniPBCoder writeRootObject]` 进行字节对齐。`writeRootObject`内部实现比较简单，就是依据 encodeItem 的类型，对齐进行 protobuf 的 Varint 变长编码，并将数据写入 m_outputBuffer；

MiniPBEncodeItemType 支持的类型有：

```objective-c
enum MiniPBEncodeItemType {
  PBEncodeItemType_None,
  PBEncodeItemType_NSString,
  PBEncodeItemType_NSData,
  PBEncodeItemType_NSDate,
  PBEncodeItemType_NSContainer,
};
```

这里特意说一点，encodeItem 中的 compiledSize 字段是记录着是所 encode 对象的 valueSize 以 protobuf 的 Varint 变长编码所后需要的 size 大小，有兴趣的可以继续深挖实现。



#### **-[MMKV appendData: forKey:]**

setter API 的所有方法最后都走到 `-[MMKV setRawData: forKey:]` ，其内部核心是调用了 appendData 以写入数据。

```objective-c
- (BOOL)appendData:(NSData *)data forKey:(NSString *)key {
   /// 1. 分别获取 key length 和 data.length 计算写入数据的 size
	size_t keyLength = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	auto size = keyLength + pbRawVarint32Size((int32_t) keyLength); // size needed to encode the key
	size += data.length + pbRawVarint32Size((int32_t) data.length); // size needed to encode the value
	/// 2. 检查文件大小，空间不够时则进行文件重整，key 排重，或扩大文件操作
	BOOL hasEnoughSize = [self ensureMemorySize:size];
	if (hasEnoughSize == NO || [self isFileValid] == NO) {
		return NO;
	}
	/// 3. 写入 m_actualSize
	BOOL ret = [self writeActualSize:m_actualSize + size];
	if (ret) {
      /// 4. 写入 m_output
		ret = [self protectFromBackgroundWriting:size
		                              writeBlock:^(MiniCodedOutputData *output) {
			                              output->writeString(key);
			                              output->writeData(data); // note: write size of data
		                              }];
		if (ret) {
			static const int offset = pbFixed32Size(0);
			auto ptr = (uint8_t *) m_ptr + offset + m_actualSize - size;
			if (m_cryptor) {
				m_cryptor->encrypt(ptr, ptr, size);
			}
			[self updateCRCDigest:ptr withSize:size increaseSequence:KeepSequence];
		}
	}
	return ret;
}
```

每个 data 进行写入前都会进行 m_lock 的加锁，然后将 data.length + key lenght 的 protobuf Varint 编码后的长度通过 `-[MMKV writeActualSize:]` 写入 m_actualSize，写入成功后再调用 `-[MMKV protectFromBackgroundWriting: writeBlock:]` 来完成 data 写入。最终 data 是以追加到到 `m_output`末尾的方式更新的，追加成功后才会进行 m_dic 的更新。

根据官方说明，以 append 方式直接追加新数据是为了**写入优化**。

> *标准 protobuf 不提供增量更新的能力，每次写入都必须全量写入。考虑到主要使用场景是频繁地进行写入更新，我们需要有增量更新的能力：将增量 kv 对象序列化后，直接 append 到内存末尾；这样同一个 key 会有新旧若干份数据，最新的数据在最后；那么只需在程序启动第一次打开 mmkv 时，不断用后读入的 value 替换之前的值，就可以保证数据是最新有效的。*

而这种直接追加 data 到 `m_output`末尾的方式会带来的问题就是空间快速增长，导致文件大小不可控。因此，在数据写入前会调用 `-[MMKV ensureMemorySize:]`进行文件重整。官方说明：

> 使用 append 实现增量更新带来了一个新的问题，就是不断 append 的话，文件大小会增长得不可控。例如同一个 key 不断更新的话，是可能耗尽几百 M 甚至上 G 空间，而事实上整个 kv 文件就这一个 key，不到 1k 空间就存得下。这明显是不可取的。我们需要在性能和空间上做个折中：以内存 pagesize 为单位申请空间，在空间用尽之前都是 append 模式；当 append 到文件末尾时，进行文件重整、key 排重，尝试序列化保存排重结果；排重后空间还是不够用的话，将文件扩大一倍，直到空间足够。

我们来看看是如何实现的：

```objective-c

// since we use append mode, when -[setData: forKey:] many times, space may not be enough
// try a full rewrite to make space
- (BOOL)ensureMemorySize:(size_t)newSize {
	[self checkLoadData];
	/// 1. 文件的合法性, m_fd, m_size, m_output, m_ptr 都已成功初始化
	if (![self isFileValid]) {
		MMKVWarning(@"[%@] file not valid", m_mmapID);
		return NO;
	}

	// make some room for placeholder
	constexpr uint32_t /*ItemSizeHolder = 0x00ffffff,*/ ItemSizeHolderSize = 4;
	if (m_dic.count == 0) {
		newSize += ItemSizeHolderSize;
	}
    /// 2. 当剩余空间不够存储 new_size 或者 m_dic 为空，尝试文件重整,
    ///    将 m_dic 中存储的数据进行序列化，作为重整后数据写入 m_output。
	if (newSize >= m_output->spaceLeft() || m_dic.count == 0) {
		// try a full rewrite to make space
		static const int offset = pbFixed32Size(0);
		NSData *data = [MiniPBCoder encodeDataWithObject:m_dic];
		size_t lenNeeded = data.length + offset + newSize;
		size_t avgItemSize = lenNeeded / std::max<size_t>(1, m_dic.count);
		size_t futureUsage = avgItemSize * std::max<size_t>(8, m_dic.count / 2);
        ///    3. 在内存不足的情况下，执行 do-while 循环，不断将 m_size 乘 2，直到空间足够进行完全数据回写或者预留空间够大，以避免频繁扩容。
		// 1. no space for a full rewrite, double it
		// 2. or space is not large enough for future usage, double it to avoid frequently full rewrite
		if (lenNeeded >= m_size || (lenNeeded + futureUsage) >= m_size) {  
			size_t oldSize = m_size;
			do {
				m_size *= 2;
			} while (lenNeeded + futureUsage >= m_size);
			MMKVInfo(@"extending [%@] file size from %zu to %zu, incoming size:%zu, future usage:%zu",
			         m_mmapID, oldSize, m_size, newSize, futureUsage);

            ///  4. 清空文件，为数据写入准备
			// if we can't extend size, rollback to old state
			if (ftruncate(m_fd, m_size) != 0) {
				MMKVError(@"fail to truncate [%@] to size %zu, %s", m_mmapID, m_size, strerror(errno));
				m_size = oldSize;
				return NO;
			}
            ///  5. 移除旧内存映射
			if (munmap(m_ptr, oldSize) != 0) {
				MMKVError(@"fail to munmap [%@], %s", m_mmapID, strerror(errno));
			}
            ///  6. 按新 m_size 重新进行内存映射，更新 m_prt 指针
			m_ptr = (char *) mmap(m_ptr, m_size, PROT_READ | PROT_WRITE, MAP_SHARED, m_fd, 0);
			if (m_ptr == MAP_FAILED) {
				MMKVError(@"fail to mmap [%@], %s", m_mmapID, strerror(errno));
			}

			// check if we fail to make more space
			if (![self isFileValid]) {
				MMKVWarning(@"[%@] file not valid", m_mmapID);
				return NO;
			}
            ///  7. 重新生成 m_output, 同时重置数据大小对偏移量。
			// keep m_output consistent with m_ptr -- writeAcutalSize: may fail
			delete m_output;
			m_output = new MiniCodedOutputData(m_ptr + offset, m_size - offset);
			m_output->seek(m_actualSize);
		}

        /// 8. 对重整后数据重新加密
		if (m_cryptor) {
			[self updateIVAndIncreaseSequence:KeepSequence];
			m_cryptor->reset(m_metaInfo.m_vector, sizeof(m_metaInfo.m_vector));
			auto ptr = (unsigned char *) data.bytes;
			m_cryptor->encrypt(ptr, ptr, data.length);
		}
        
        ///  9. 将真实数据大小 m_actualSize 写入 m_prt 头部对应的内存区
		if ([self writeActualSize:data.length] == NO) {
			return NO;
		}
        ///  10. 重新写入重整后数据
		delete m_output;
		m_output = new MiniCodedOutputData(m_ptr + offset, m_size - offset);
		BOOL ret = [self protectFromBackgroundWriting:m_actualSize
		                                   writeBlock:^(MiniCodedOutputData *output) {
			                                   output->writeRawData(data);
		                                   }];
		if (ret) {
			[self recaculateCRCDigest];
		}
		return ret;
	}
	return YES;
}
```



1. 检查文件的合法性, m_fd, m_size, m_output, m_ptr 都已成功初始化；

2. 当剩余空间不够存储 new_size 或者 m_dic 为空，尝试文件重整；

​       将 m_dic 中存储的数据进行序列化，作为重整后数据写入 m_output；

3. 在内存不足的情况下，执行 do-while 循环，不断将 m_size 乘 2，直到空间足够进行完全数据回写或者预留空间够大，以避免频繁扩容。
   1. no space for a full rewrite, double it
   2. or space is not large enough for future usage, double it to avoid frequently full rewrite

4. 清空文件，为数据写入准备；

5. 移除旧内存映射；

6. 按新 m_size 重新进行内存映射，更新 m_prt 指针；

7. 重新生成 m_output, 同时重置数据大小对偏移量。

8. 对重整后数据重新加密

9. 将真实数据大小 m_actualSize 写入 m_prt 头部对应的内存区

10. 重新写入重整后数据



### **Getter**

```objective-c
- (id)getObjectOfClass:(Class)cls forKey:(NSString *)key {
	if (key.length <= 0) {
		return nil;
	}
	NSData *data = [self getRawDataForKey:key];
	if (data.length > 0) {

		if ([MiniPBCoder isMiniPBCoderCompatibleType:cls]) {
			return [MiniPBCoder decodeObjectOfClass:cls fromData:data];
		} else {
			if ([cls conformsToProtocol:@protocol(NSCoding)]) {
				return [NSKeyedUnarchiver unarchiveObjectWithData:data];
			}
		}
	}
	return nil;
}

- (BOOL)getBoolForKey:(NSString *)key {
	return [self getBoolForKey:key defaultValue:FALSE];
}
- (BOOL)getBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
	if (key.length <= 0) {
		return defaultValue;
	}
	NSData *data = [self getRawDataForKey:key];
	if (data.length > 0) {
		@try {
			MiniCodedInputData input(data);
			return input.readBool();
		} @catch (NSException *exception) {
			MMKVError(@"%@", exception);
		}
	}
	return defaultValue;
}
```

同 setter 类似，基础数据类型和 objc 类型都会先调用 `-[MMKV getRawDataForKey:]`获取 data。getRawData 只是直接通过 m_dict 返回对应 data 并检查了文件状态 `-[MMKV checkLoadData]`.

基础数据类型直接通过 `MiniCodedInputData intput(data)` 进行解码读出对应 value 返回。objc 则是会对支持 protobuf 编码的类型调用其解码器进行解码。反之，调用系统的 `+[NSKeyedUnarchiver unarchiveObjectWithData:]`。

protobuf 的解码实现比较简单，核心实现为：

```objc
- (id)decodeOneObject:(id)obj ofClass:(Class)cls {
	if (!cls && !obj) {
		return nil;
	}
	if (!cls) {
		cls = [(NSObject *) obj class];
	}

	if (cls == [NSString class]) {
		return m_inputData->readString();
	} else if (cls == [NSMutableString class]) {
		return [NSMutableString stringWithString:m_inputData->readString()];
	} else if (cls == [NSData class]) {
		return m_inputData->readData();
	} else if (cls == [NSMutableData class]) {
		return [NSMutableData dataWithData:m_inputData->readData()];
	} else if (cls == [NSDate class]) {
		return [NSDate dateWithTimeIntervalSince1970:m_inputData->readDouble()];
	} else {
		MMKVError(@"%@ does not respond -[getValueTypeTable] and no basic type, can't handle", NSStringFromClass(cls));
	}

	return nil;
}
```

我们执行`+[MiniPBCoder decodeObjectOfClass:cls fromData:]` 进行解码时，该方法内部就是创建了 MiniPBCoder 对象，并将 data 转化为 `MiniCodedInputData *m_inputData` 在 decodeOneObject 时根据不同类型对象，读取所存 data 并初始化返回。



### **Delete**

MMKV 的删除操作是通过 `-[MMKV removeValueForKey:]`

```objective-c
- (void)removeValueForKey:(NSString *)key {
	if (key.length <= 0) {
		return;
	}
	CScopedLock lock(m_lock);
	[self checkLoadData];

	if ([m_dic objectForKey:key] == nil) {
		return;
	}
	[m_dic removeObjectForKey:key];
	m_hasFullWriteBack = NO;

	static NSData *data = [NSData data];
	[self appendData:data forKey:key];
}
```

和 setter 很像，只是删除 m_dict key 对应的 value 时，会调用 appendData 写入一个空的 data 到 m_output 中。最后在内存重整时，更新写入文件。



## **总结**

MMKV 是一种基于 mmap 的 K-V 存储库，与 NSUerDefaults 类似，但其效率提高了近百倍。

它通过 mmkvWithID 方法获取 mmapID 对应的 MMKV 对象的，通过 mmap 获取文件的 m_prt 和 m_output，并将序列化后数据写入 m_dict。

在写入数据时通过  **MiniCodedOutData** 作为中间 buffer 以字节形式存放。由于 mmap 的特性写入数据时会将数据同时写入文件，由于 protobuf 协议无法做到增量更新，因此其实是通过不断向文件后 append 新的 value 来实现的。**当写入空间不足时，会进行内存重排**，先将文件按 double 方式的扩容后，将 m_dict 中的 k-v 重新序列化一次。

在查询数据时，会从 map 中取出 Buffer，再将 Buffer 中的数据转换为对应的真实类型并返回。

在删除数据时，会找到对应的 key 并从 map 中删除，之后将 key 在文件中对应的 value 置为 0。