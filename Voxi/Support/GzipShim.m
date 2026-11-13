#import "GzipShim.h"
#import <zlib.h>
#include <string.h>

static NSData * _Nullable InflateWithWindowBits(NSData *input, int windowBits) {
    if (input.length == 0) {
        return [NSData data];
    }
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, windowBits) != Z_OK) {
        return nil;
    }
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;

    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[64 * 1024];
    int status = Z_OK;
    while (status != Z_STREAM_END) {
        stream.next_out = buffer;
        stream.avail_out = (uInt)sizeof(buffer);
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) {
            inflateEnd(&stream);
            return nil;
        }
        NSUInteger produced = sizeof(buffer) - stream.avail_out;
        if (produced > 0) {
            [output appendBytes:buffer length:produced];
        }
        if (status != Z_STREAM_END && stream.avail_in == 0 && produced == 0) {
            // 输入被截断，无法继续
            inflateEnd(&stream);
            return nil;
        }
    }
    inflateEnd(&stream);
    return output;
}

NSData * _Nullable VoxiGzipDecompress(NSData *input) {
    // 16 + MAX_WBITS 表示 gzip 容器
    return InflateWithWindowBits(input, 16 + MAX_WBITS);
}

NSData * _Nullable VoxiZlibDecompress(NSData *input) {
    return InflateWithWindowBits(input, MAX_WBITS);
}

NSData * _Nullable VoxiGzipCompress(NSData *input) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (deflateInit2(&stream,
                     Z_DEFAULT_COMPRESSION,
                     Z_DEFLATED,
                     16 + MAX_WBITS,
                     8,
                     Z_DEFAULT_STRATEGY) != Z_OK) {
        return nil;
    }
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;

    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[64 * 1024];
    int status = Z_OK;
    do {
        stream.next_out = buffer;
        stream.avail_out = (uInt)sizeof(buffer);
        status = deflate(&stream, Z_FINISH);
        if (status != Z_OK && status != Z_STREAM_END) {
            deflateEnd(&stream);
            return nil;
        }
        NSUInteger produced = sizeof(buffer) - stream.avail_out;
        if (produced > 0) {
            [output appendBytes:buffer length:produced];
        }
    } while (status != Z_STREAM_END);
    deflateEnd(&stream);
    return output;
}
