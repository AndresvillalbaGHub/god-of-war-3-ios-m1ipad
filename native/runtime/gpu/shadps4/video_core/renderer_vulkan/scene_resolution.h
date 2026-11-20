// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <utility>

namespace Vulkan::SceneResolution {
struct Size {
    uint32_t width = 1920, height = 1080;
    bool operator==(const Size&) const = default;
};
inline Size ForPreset(int preset, Size output = {}) {
    // Even dimensions for half-resolution effects; match the preset labels exactly.
    constexpr std::array<double, 5> scales{1.0, 1.5, 1.7, 2.0, 3.0};
    const double scale = scales[std::clamp(preset, 0, 4)];
    return {uint32_t(std::max(1l, std::lround(output.width / scale / 2)) * 2),
            uint32_t(std::max(1l, std::lround(output.height / scale / 2)) * 2)};
}
/// M1 Block C live scene scale: 0=native, 1=5/6 (450p), 2=4/5 (432p), 3=2/3 (360p).
/// Always returns even dimensions strictly smaller than `base` when mode > 0.
inline Size ForM1Scale(int mode, Size base) {
    if (mode <= 0 || base.width < 320 || base.height < 180) {
        return base;
    }
    constexpr std::array<std::pair<uint32_t, uint32_t>, 3> ratios{{
        {5u, 6u}, // 83.3%: 960x540 -> 800x450 (-30.6% px)
        {4u, 5u}, // 80.0%: 960x540 -> 768x432 (-36.0% px)
        {2u, 3u}, // 66.7%: 960x540 -> 640x360 (-55.6% px)
    }};
    const auto [num, den] = ratios[std::clamp(mode, 1, 3) - 1];
    uint32_t w = ((base.width * num / den) / 2u) * 2u;
    uint32_t h = ((base.height * num / den) / 2u) * 2u;
    w = std::clamp(w, 320u, base.width > 2u ? base.width - 2u : base.width);
    h = std::clamp(h, 180u, base.height > 2u ? base.height - 2u : base.height);
    return {w, h};
}
constexpr uint32_t Pack(Size size) { return size.width | (size.height << 16); }
constexpr Size Unpack(uint32_t packed) {
    return packed ? Size{packed & 65535u, packed >> 16} : Size{};
}
// A proxy and the guest-size image hold the same logical surface. Native shader reads
// need a resolve after proxy writes; native writes invalidate the cached proxy.
struct Coherence {
    bool valid = false, dirty = false;
    void ProxyWrite() { valid = dirty = true; }
    void CopiedToProxy() { valid = true; dirty = false; }
    void Resolved() { dirty = false; }
    void NativeWrite() { valid = dirty = false; }
};
} // namespace Vulkan::SceneResolution
