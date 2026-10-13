#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include "Upstream/dylib/util/peicon.h"

static void append32(NSMutableData *data, uint32_t value) {
    value = CFSwapInt32HostToBig(value);
    [data appendBytes:&value length:4];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSData *input = [NSData dataWithContentsOfFile:@(argv[1])];
        if (input.length >= 2 && memcmp(input.bytes, "MZ", 2) == 0) {
            size_t size = 0;
            void *ico = np_pe_icon_ico(argv[1], &size);
            if (!ico) return 1;
            input = [NSData dataWithBytes:ico length:size];
            free(ico);
        }
        if (!input) return 1;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)input, NULL);
        if (!source) return 1;
        CGImageRef image = NULL;
        for (size_t index = 0; index < CGImageSourceGetCount(source); index++) {
            CGImageRef candidate = CGImageSourceCreateImageAtIndex(source, index, NULL);
            if (candidate && (!image || CGImageGetWidth(candidate) > CGImageGetWidth(image))) {
                if (image) CGImageRelease(image);
                image = candidate;
            } else if (candidate) CGImageRelease(candidate);
        }
        CFRelease(source);
        if (!image) return 1;
        NSMutableData *chunks = [NSMutableData data];
        const int sizes[] = {16, 32, 64, 128, 256, 512, 1024};
        const char *types[] = {"icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10"};
        for (int i = 0; i < 7; i++) {
            int size = sizes[i];
            CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context = CGBitmapContextCreate(NULL, size, size, 8, size * 4,
                colors, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
            CGColorSpaceRelease(colors);
            if (!context) { CGImageRelease(image); return 1; }
            double scale = MIN((double)size / CGImageGetWidth(image), (double)size / CGImageGetHeight(image));
            double width = CGImageGetWidth(image) * scale, height = CGImageGetHeight(image) * scale;
            CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
            CGContextDrawImage(context, CGRectMake((size-width)/2, (size-height)/2, width, height), image);
            CGImageRef resized = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
            NSMutableData *png = [NSMutableData data];
            CGImageDestinationRef destination = CGImageDestinationCreateWithData(
                (__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
            if (!destination || !resized) {
                if (destination) CFRelease(destination);
                if (resized) CGImageRelease(resized);
                CGImageRelease(image); return 1;
            }
            CGImageDestinationAddImage(destination, resized, NULL);
            BOOL ok = CGImageDestinationFinalize(destination);
            CFRelease(destination); CGImageRelease(resized);
            if (!ok) { CGImageRelease(image); return 1; }
            [chunks appendBytes:types[i] length:4]; append32(chunks, (uint32_t)png.length + 8);
            [chunks appendData:png];
        }
        CGImageRelease(image);
        NSMutableData *result = [NSMutableData dataWithBytes:"icns" length:4];
        append32(result, (uint32_t)chunks.length + 8); [result appendData:chunks];
        return [result writeToFile:@(argv[2]) options:NSDataWritingAtomic error:nil] ? 0 : 1;
    }
}
