#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Gzip（RFC 1952）压缩/解压，基于系统 zlib。
FOUNDATION_EXPORT NSData * _Nullable VoxiGzipCompress(NSData *input);
FOUNDATION_EXPORT NSData * _Nullable VoxiGzipDecompress(NSData *input);
/// 兼容 zlib（RFC 1950）数据。
FOUNDATION_EXPORT NSData * _Nullable VoxiZlibDecompress(NSData *input);

NS_ASSUME_NONNULL_END
