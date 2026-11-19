// SPDX-License-Identifier: GPL-2.0-or-later
// gow3 (M1): Native iOS MetalFX Spatial upscaling pass bridged via VK_EXT_metal_objects.

#define VK_USE_PLATFORM_METAL_EXT
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <memory>
#include <mutex>
#include <vector>

#include "video_core/renderer_vulkan/host_passes/metalfx_pass.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_platform.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include <vk_mem_alloc.h>
#include <vulkan/vulkan_metal.h>

namespace Vulkan::HostPasses {

namespace {

bool CreateExportableImage(VmaAllocator allocator, u32 width, u32 height, VkImageUsageFlags usage,
                           VkImage& out_image, VmaAllocation& out_alloc) {
    VkExportMetalObjectCreateInfoEXT export_info{
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
        .pNext = nullptr,
        .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT,
    };
    const VkImageCreateInfo image_ci{
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &export_info,
        .flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {width, height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    const VmaAllocationCreateInfo alloc_ci{
        .usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
    };
    return vmaCreateImage(allocator, &image_ci, &alloc_ci, &out_image, &out_alloc, nullptr) ==
           VK_SUCCESS;
}

id<MTLTexture> ExportTexture(VkDevice device, PFN_vkExportMetalObjectsEXT export_fn,
                             VkImage image) {
    VkExportMetalTextureInfoEXT tex_info{
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT,
        .pNext = nullptr,
        .image = image,
        .imageView = VK_NULL_HANDLE,
        .bufferView = VK_NULL_HANDLE,
        .plane = VK_IMAGE_ASPECT_COLOR_BIT,
        .mtlTexture = nil,
    };
    VkExportMetalObjectsInfoEXT objs_info{
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
        .pNext = &tex_info,
    };
    export_fn(device, &objs_info);
    return tex_info.mtlTexture;
}

vk::ImageView CreateColorView(vk::Device device, vk::Image image, vk::Format format) {
    return Check<"metalfx dst image view">(device.createImageView({
        .image = image,
        .viewType = vk::ImageViewType::e2D,
        .format = format,
        .components =
            {
                vk::ComponentSwizzle::eIdentity,
                vk::ComponentSwizzle::eIdentity,
                vk::ComponentSwizzle::eIdentity,
                vk::ComponentSwizzle::eOne,
            },
        .subresourceRange = {vk::ImageAspectFlagBits::eColor, 0, 1, 0, 1},
    }));
}

} // namespace

struct MetalFXSpatialPass::Impl {
    struct Slot {
        vk::Image src_image{};
        VmaAllocation src_alloc{};
        id<MTLTexture> src_mtl = nil;

        vk::Image dst_image{};
        VmaAllocation dst_alloc{};
        id<MTLTexture> dst_mtl = nil;
        vk::ImageView dst_view_srgb{};
        vk::ImageView dst_view_unorm{};
        vk::ImageLayout dst_layout = vk::ImageLayout::eUndefined;
    };

    vk::Device vk_device{};
    VmaAllocator allocator{};
    PFN_vkExportMetalObjectsEXT export_fn{};

    id<MTLDevice> mtl_device = nil;
    id<MTLCommandQueue> mtl_queue = nil;
    id<MTLFXSpatialScaler> scaler = nil;

    u32 num_images = 0;
    u32 cur_slot = 0;
    vk::Extent2D cur_in{};
    vk::Extent2D cur_out{};
    bool cur_perceptual = true;
    bool available = false;
    bool active_last_frame = false;
    std::vector<Slot> slots;

    void DestroySlots() {
        for (auto& s : slots) {
            if (s.dst_view_srgb) {
                vk_device.destroyImageView(s.dst_view_srgb);
                s.dst_view_srgb = nullptr;
            }
            if (s.dst_view_unorm) {
                vk_device.destroyImageView(s.dst_view_unorm);
                s.dst_view_unorm = nullptr;
            }
            s.src_mtl = nil;
            s.dst_mtl = nil;
            if (s.src_image && allocator) {
                vmaDestroyImage(allocator, static_cast<VkImage>(s.src_image), s.src_alloc);
                s.src_image = nullptr;
                s.src_alloc = nullptr;
            }
            if (s.dst_image && allocator) {
                vmaDestroyImage(allocator, static_cast<VkImage>(s.dst_image), s.dst_alloc);
                s.dst_image = nullptr;
                s.dst_alloc = nullptr;
            }
            s.dst_layout = vk::ImageLayout::eUndefined;
        }
        slots.clear();
    }

    bool EnsureResources(Scheduler& scheduler, vk::Extent2D in_sz, vk::Extent2D out_sz,
                         bool perceptual_srgb) {
        if (scaler && cur_in == in_sz && cur_out == out_sz &&
            cur_perceptual == perceptual_srgb && !slots.empty()) {
            return true;
        }
        scheduler.Finish();
        scaler = nil;
        DestroySlots();

        @autoreleasepool {
            MTLFXSpatialScalerDescriptor* desc = [[MTLFXSpatialScalerDescriptor alloc] init];
            desc.inputWidth = in_sz.width;
            desc.inputHeight = in_sz.height;
            desc.outputWidth = out_sz.width;
            desc.outputHeight = out_sz.height;
            desc.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
            desc.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
            desc.colorProcessingMode = perceptual_srgb
                                           ? MTLFXSpatialScalerColorProcessingModePerceptual
                                           : MTLFXSpatialScalerColorProcessingModeLinear;
            scaler = [desc newSpatialScalerWithDevice:mtl_device];
            if (!scaler) {
                std::printf("MetalFX Spatial: newSpatialScalerWithDevice returned nil (%ux%u -> "
                            "%ux%u)\n",
                            in_sz.width, in_sz.height, out_sz.width, out_sz.height);
                return false;
            }
        }

        const u32 count = std::max(1u, num_images);
        slots.resize(count);
        for (u32 i = 0; i < count; ++i) {
            auto& s = slots[i];
            VkImage src_raw = VK_NULL_HANDLE;
            VkImage dst_raw = VK_NULL_HANDLE;
            if (!CreateExportableImage(allocator, in_sz.width, in_sz.height,
                                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                                       src_raw, s.src_alloc) ||
                !CreateExportableImage(
                    allocator, out_sz.width, out_sz.height,
                    VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                    dst_raw, s.dst_alloc)) {
                DestroySlots();
                scaler = nil;
                return false;
            }
            s.src_image = vk::Image{src_raw};
            s.dst_image = vk::Image{dst_raw};
            s.src_mtl = ExportTexture(static_cast<VkDevice>(vk_device), export_fn, src_raw);
            s.dst_mtl = ExportTexture(static_cast<VkDevice>(vk_device), export_fn, dst_raw);
            if (!s.src_mtl || !s.dst_mtl) {
                std::printf("MetalFX Spatial: failed exporting MTLTexture from VkImage\n");
                DestroySlots();
                scaler = nil;
                return false;
            }
            s.dst_view_srgb = CreateColorView(vk_device, s.dst_image, vk::Format::eR8G8B8A8Srgb);
            s.dst_view_unorm = CreateColorView(vk_device, s.dst_image, vk::Format::eR8G8B8A8Unorm);
            s.dst_layout = vk::ImageLayout::eUndefined;
        }

        cur_in = in_sz;
        cur_out = out_sz;
        cur_perceptual = perceptual_srgb;
        cur_slot = 0;
        std::printf("MetalFX Spatial: %ux%u -> %ux%u (%s, %u slots)\n", in_sz.width, in_sz.height,
                    out_sz.width, out_sz.height, perceptual_srgb ? "perceptual" : "linear", count);
        return true;
    }
};

MetalFXSpatialPass::MetalFXSpatialPass() : impl(std::make_unique<Impl>()) {}

MetalFXSpatialPass::~MetalFXSpatialPass() {
    Destroy();
}

void MetalFXSpatialPass::Create(const Instance& instance, u32 num_images) {
    Destroy();
    impl->vk_device = instance.GetDevice();
    impl->allocator = instance.GetAllocator();
    impl->num_images = num_images;
    if (!instance.IsMetalObjectsSupported()) {
        std::printf("MetalFX Spatial: VK_EXT_metal_objects unavailable\n");
        return;
    }

    auto dev = static_cast<VkDevice>(impl->vk_device);
    impl->export_fn = reinterpret_cast<PFN_vkExportMetalObjectsEXT>(
        VULKAN_HPP_DEFAULT_DISPATCHER.vkGetDeviceProcAddr(dev, "vkExportMetalObjectsEXT"));
    if (!impl->export_fn) {
        std::printf("MetalFX Spatial: vkExportMetalObjectsEXT entry point missing\n");
        return;
    }

    @autoreleasepool {
        VkExportMetalCommandQueueInfoEXT queue_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_COMMAND_QUEUE_INFO_EXT,
            .pNext = nullptr,
            .queue = static_cast<VkQueue>(instance.GetGraphicsQueue()),
            .mtlCommandQueue = nil,
        };
        VkExportMetalDeviceInfoEXT dev_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT,
            .pNext = &queue_info,
            .mtlDevice = nil,
        };
        VkExportMetalObjectsInfoEXT objs_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT,
            .pNext = &dev_info,
        };
        impl->export_fn(dev, &objs_info);
        impl->mtl_device = dev_info.mtlDevice;
        impl->mtl_queue = queue_info.mtlCommandQueue;
        if (!impl->mtl_device || !impl->mtl_queue) {
            std::printf("MetalFX Spatial: could not export MTLDevice/MTLCommandQueue\n");
            impl->mtl_device = nil;
            impl->mtl_queue = nil;
            return;
        }
        if (![MTLFXSpatialScalerDescriptor supportsDevice:impl->mtl_device]) {
            std::printf("MetalFX Spatial: device does not support MTLFXSpatialScaler\n");
            impl->mtl_device = nil;
            impl->mtl_queue = nil;
            return;
        }
        impl->available = true;
        std::printf("MetalFX Spatial: enabled on %s\n", [[impl->mtl_device name] UTF8String]);
    }
}

void MetalFXSpatialPass::Destroy() {
    if (!impl) {
        return;
    }
    impl->DestroySlots();
    impl->scaler = nil;
    impl->mtl_queue = nil;
    impl->mtl_device = nil;
    impl->export_fn = nullptr;
    impl->vk_device = nullptr;
    impl->allocator = nullptr;
    impl->cur_in = {};
    impl->cur_out = {};
    impl->available = false;
    impl->active_last_frame = false;
}

bool MetalFXSpatialPass::Available() const noexcept {
    return impl && impl->available;
}

bool MetalFXSpatialPass::ActiveLastFrame() const noexcept {
    return impl && impl->active_last_frame;
}

vk::ImageView MetalFXSpatialPass::Render(Scheduler& scheduler, vk::Image src_image,
                                           vk::Format src_format, vk::ImageLayout src_layout,
                                           vk::Extent2D input_size, vk::Extent2D output_size,
                                           bool is_hdr, bool perceptual_srgb) {
    impl->active_last_frame = false;
    if (!impl->available || is_hdr || !src_image || output_size.width <= input_size.width ||
        output_size.height <= input_size.height) {
        return {};
    }
    if (src_format != vk::Format::eR8G8B8A8Srgb && src_format != vk::Format::eR8G8B8A8Unorm) {
        return {};
    }
    if (!impl->EnsureResources(scheduler, input_size, output_size, perceptual_srgb)) {
        return {};
    }

    auto& slot = impl->slots[impl->cur_slot];
    impl->cur_slot = (impl->cur_slot + 1) % u32(impl->slots.size());

    scheduler.EndRendering();
    constexpr vk::ImageSubresourceRange color_range{
        .aspectMask = vk::ImageAspectFlagBits::eColor,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };

    const std::array enter_barriers{
        vk::ImageMemoryBarrier2{
            .srcStageMask = vk::PipelineStageFlagBits2::eAllCommands,
            .srcAccessMask = vk::AccessFlagBits2::eColorAttachmentWrite |
                             vk::AccessFlagBits2::eShaderRead | vk::AccessFlagBits2::eTransferWrite,
            .dstStageMask = vk::PipelineStageFlagBits2::eTransfer,
            .dstAccessMask = vk::AccessFlagBits2::eTransferRead,
            .oldLayout = src_layout,
            .newLayout = vk::ImageLayout::eTransferSrcOptimal,
            .image = src_image,
            .subresourceRange = color_range,
        },
        vk::ImageMemoryBarrier2{
            .srcStageMask = vk::PipelineStageFlagBits2::eTopOfPipe,
            .srcAccessMask = vk::AccessFlagBits2::eNone,
            .dstStageMask = vk::PipelineStageFlagBits2::eTransfer,
            .dstAccessMask = vk::AccessFlagBits2::eTransferWrite,
            .oldLayout = vk::ImageLayout::eUndefined,
            .newLayout = vk::ImageLayout::eTransferDstOptimal,
            .image = slot.src_image,
            .subresourceRange = color_range,
        },
        vk::ImageMemoryBarrier2{
            .srcStageMask = vk::PipelineStageFlagBits2::eAllCommands,
            .srcAccessMask = slot.dst_layout == vk::ImageLayout::eUndefined
                                 ? vk::AccessFlagBits2::eNone
                                 : vk::AccessFlagBits2::eShaderRead,
            .dstStageMask = vk::PipelineStageFlagBits2::eAllCommands,
            .dstAccessMask = vk::AccessFlagBits2::eMemoryRead | vk::AccessFlagBits2::eMemoryWrite,
            .oldLayout = slot.dst_layout,
            .newLayout = vk::ImageLayout::eGeneral,
            .image = slot.dst_image,
            .subresourceRange = color_range,
        },
    };

    auto cmdbuf = scheduler.CommandBuffer();
    cmdbuf.pipelineBarrier2({
        .imageMemoryBarrierCount = u32(enter_barriers.size()),
        .pImageMemoryBarriers = enter_barriers.data(),
    });

    const vk::ImageCopy copy_region{
        .srcSubresource = {vk::ImageAspectFlagBits::eColor, 0, 0, 1},
        .srcOffset = {0, 0, 0},
        .dstSubresource = {vk::ImageAspectFlagBits::eColor, 0, 0, 1},
        .dstOffset = {0, 0, 0},
        .extent = {input_size.width, input_size.height, 1},
    };
    cmdbuf.copyImage(src_image, vk::ImageLayout::eTransferSrcOptimal, slot.src_image,
                     vk::ImageLayout::eTransferDstOptimal, copy_region);

    const std::array exit_copy_barriers{
        vk::ImageMemoryBarrier2{
            .srcStageMask = vk::PipelineStageFlagBits2::eTransfer,
            .srcAccessMask = vk::AccessFlagBits2::eTransferRead,
            .dstStageMask = vk::PipelineStageFlagBits2::eFragmentShader |
                            vk::PipelineStageFlagBits2::eTransfer,
            .dstAccessMask = vk::AccessFlagBits2::eShaderRead | vk::AccessFlagBits2::eTransferRead,
            .oldLayout = vk::ImageLayout::eTransferSrcOptimal,
            .newLayout = src_layout,
            .image = src_image,
            .subresourceRange = color_range,
        },
        vk::ImageMemoryBarrier2{
            .srcStageMask = vk::PipelineStageFlagBits2::eTransfer,
            .srcAccessMask = vk::AccessFlagBits2::eTransferWrite,
            .dstStageMask = vk::PipelineStageFlagBits2::eAllCommands,
            .dstAccessMask = vk::AccessFlagBits2::eShaderRead,
            .oldLayout = vk::ImageLayout::eTransferDstOptimal,
            .newLayout = vk::ImageLayout::eShaderReadOnlyOptimal,
            .image = slot.src_image,
            .subresourceRange = color_range,
        },
    };
    cmdbuf.pipelineBarrier2({
        .imageMemoryBarrierCount = u32(exit_copy_barriers.size()),
        .pImageMemoryBarriers = exit_copy_barriers.data(),
    });

    scheduler.Flush();

    bool encoded = false;
    @autoreleasepool {
        std::scoped_lock lk{Scheduler::submit_mutex};
        id<MTLCommandBuffer> mtl_cmd = [impl->mtl_queue commandBuffer];
        if (mtl_cmd) {
            impl->scaler.colorTexture = slot.src_mtl;
            impl->scaler.outputTexture = slot.dst_mtl;
            impl->scaler.inputContentWidth = input_size.width;
            impl->scaler.inputContentHeight = input_size.height;
            [impl->scaler encodeToCommandBuffer:mtl_cmd];
            [mtl_cmd commit];
            encoded = true;
        }
    }

    if (!encoded) {
        slot.dst_layout = vk::ImageLayout::eGeneral;
        return {};
    }

    const vk::ImageMemoryBarrier2 to_read{
        .srcStageMask = vk::PipelineStageFlagBits2::eAllCommands,
        .srcAccessMask = vk::AccessFlagBits2::eMemoryWrite,
        .dstStageMask = vk::PipelineStageFlagBits2::eFragmentShader,
        .dstAccessMask = vk::AccessFlagBits2::eShaderRead,
        .oldLayout = vk::ImageLayout::eGeneral,
        .newLayout = vk::ImageLayout::eShaderReadOnlyOptimal,
        .image = slot.dst_image,
        .subresourceRange = color_range,
    };
    cmdbuf = scheduler.CommandBuffer();
    cmdbuf.pipelineBarrier2({.imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &to_read});
    slot.dst_layout = vk::ImageLayout::eShaderReadOnlyOptimal;
    impl->active_last_frame = true;
    return perceptual_srgb ? slot.dst_view_srgb : slot.dst_view_unorm;
}

} // namespace Vulkan::HostPasses
