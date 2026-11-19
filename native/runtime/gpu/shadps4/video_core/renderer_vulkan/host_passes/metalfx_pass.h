// SPDX-License-Identifier: GPL-2.0-or-later
// gow3 (M1): Native Apple MetalFX Spatial upscaling pass (VK_EXT_metal_objects interop).

#pragma once

#include <memory>

#include "common/types.h"
#include "video_core/renderer_vulkan/vk_common.h"

namespace Vulkan {
class Instance;
class Scheduler;
} // namespace Vulkan

namespace Vulkan::HostPasses {

class MetalFXSpatialPass {
public:
    MetalFXSpatialPass();
    ~MetalFXSpatialPass();

    MetalFXSpatialPass(const MetalFXSpatialPass&) = delete;
    MetalFXSpatialPass& operator=(const MetalFXSpatialPass&) = delete;

    void Create(const Instance& instance, u32 num_images);
    void Destroy();

    [[nodiscard]] bool Available() const noexcept;
    [[nodiscard]] bool ActiveLastFrame() const noexcept;

    vk::ImageView Render(Scheduler& scheduler, vk::Image src_image, vk::Format src_format,
                         vk::ImageLayout src_layout, vk::Extent2D input_size,
                         vk::Extent2D output_size, bool is_hdr, bool perceptual_srgb);

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

} // namespace Vulkan::HostPasses
