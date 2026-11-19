// SPDX-License-Identifier: GPL-2.0-or-later
// gow3 (M1): Pure Objective-C++ ARC bridge for Apple MetalFX Spatial (kept separate from Vulkan-Hpp).

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace Vulkan::HostPasses::MetalFXBridge {

void* RetainObject(void* raw) {
    if (!raw) {
        return nullptr;
    }
    return (__bridge_retained void*)(__bridge id)raw;
}

void ReleaseObject(void* retained) {
    if (retained) {
        id obj = (__bridge_transfer id)retained;
        (void)obj;
    }
}

bool SupportsDevice(void* mtl_device, char* name_buf, std::size_t name_size) {
    if (!mtl_device) {
        return false;
    }
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)mtl_device;
        if (name_buf && name_size > 0) {
            const char* utf8 = [[dev name] UTF8String];
            std::snprintf(name_buf, name_size, "%s", utf8 ? utf8 : "Apple GPU");
        }
        return [MTLFXSpatialScalerDescriptor supportsDevice:dev] ? true : false;
    }
}

void* CreateScaler(void* mtl_device, std::uint32_t in_w, std::uint32_t in_h,
                   std::uint32_t out_w, std::uint32_t out_h, bool perceptual_srgb) {
    if (!mtl_device || in_w == 0 || in_h == 0 || out_w == 0 || out_h == 0) {
        return nullptr;
    }
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)mtl_device;
        MTLFXSpatialScalerDescriptor* desc = [[MTLFXSpatialScalerDescriptor alloc] init];
        desc.inputWidth = in_w;
        desc.inputHeight = in_h;
        desc.outputWidth = out_w;
        desc.outputHeight = out_h;
        desc.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
        desc.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
        desc.colorProcessingMode = perceptual_srgb
                                       ? MTLFXSpatialScalerColorProcessingModePerceptual
                                       : MTLFXSpatialScalerColorProcessingModeLinear;
        id<MTLFXSpatialScaler> scaler = [desc newSpatialScalerWithDevice:dev];
        return scaler ? (__bridge_retained void*)scaler : nullptr;
    }
}

bool Encode(void* mtl_queue, void* scaler_ptr, void* src_tex, void* dst_tex,
            std::uint32_t in_w, std::uint32_t in_h) {
    if (!mtl_queue || !scaler_ptr || !src_tex || !dst_tex) {
        return false;
    }
    @autoreleasepool {
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)mtl_queue;
        id<MTLFXSpatialScaler> scaler = (__bridge id<MTLFXSpatialScaler>)scaler_ptr;
        id<MTLTexture> src = (__bridge id<MTLTexture>)src_tex;
        id<MTLTexture> dst = (__bridge id<MTLTexture>)dst_tex;
        id<MTLCommandBuffer> cmd = [queue commandBuffer];
        if (!cmd) {
            return false;
        }
        scaler.colorTexture = src;
        scaler.outputTexture = dst;
        scaler.inputContentWidth = in_w;
        scaler.inputContentHeight = in_h;
        [scaler encodeToCommandBuffer:cmd];
        [cmd commit];
        return true;
    }
}

} // namespace Vulkan::HostPasses::MetalFXBridge
