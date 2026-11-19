// SPDX-License-Identifier: GPL-2.0-or-later
// Non-Apple fallback stub for MetalFXSpatialPass.

#include "video_core/renderer_vulkan/host_passes/metalfx_pass.h"

namespace Vulkan::HostPasses {

struct MetalFXSpatialPass::Impl {};

MetalFXSpatialPass::MetalFXSpatialPass() : impl(std::make_unique<Impl>()) {}
MetalFXSpatialPass::~MetalFXSpatialPass() = default;

void MetalFXSpatialPass::Create(const Instance&, u32) {}
void MetalFXSpatialPass::Destroy() {}
bool MetalFXSpatialPass::Available() const noexcept {
    return false;
}
bool MetalFXSpatialPass::ActiveLastFrame() const noexcept {
    return false;
}

vk::ImageView MetalFXSpatialPass::Render(Scheduler&, vk::Image, vk::Format, vk::ImageLayout,
                                           vk::Extent2D, vk::Extent2D, bool, bool) {
    return {};
}

} // namespace Vulkan::HostPasses
