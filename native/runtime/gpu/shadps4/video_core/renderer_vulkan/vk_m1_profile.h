// SPDX-License-Identifier: GPL-2.0-or-later
// gow3 (M1): Apple Silicon TBDR knobs and live secondary-pass performance profile.

#pragma once

#include <algorithm>
#include <cstdlib>
#include <cstring>

#include "common/types.h"

namespace Vulkan {

enum class BloomMode : u8 {
    Full = 0,
    Lite = 1,
    Off = 2,
};

struct M1ProfileConfig {
    bool tbdr_opt = true;
    int shadow_limit = -1; // -1 = unlimited
    BloomMode bloom = BloomMode::Full;
    bool motion_blur = true;
    bool reflections = true;

    static M1ProfileConfig Resolve(int profile_level) {
        struct EnvOverrides {
            bool has_tbdr = false;
            bool tbdr_opt = true;
            bool has_shadow = false;
            int shadow_limit = -1;
            bool has_bloom = false;
            BloomMode bloom = BloomMode::Full;
            bool has_mblur = false;
            bool motion_blur = true;
            bool has_refl = false;
            bool reflections = true;
        };
        static const EnvOverrides env = [] {
            EnvOverrides o;
            if (const char* v = std::getenv("GOW3_TBDR_OPT"); v && v[0]) {
                o.has_tbdr = true;
                o.tbdr_opt = v[0] != '0';
            }
            if (const char* v = std::getenv("GOW3_M1_SHADOW_LIMIT"); v && v[0]) {
                o.has_shadow = true;
                o.shadow_limit = std::max(-1, std::atoi(v));
            }
            if (const char* v = std::getenv("GOW3_M1_BLOOM"); v && v[0]) {
                o.has_bloom = true;
                if (std::strcmp(v, "off") == 0 || v[0] == '2') {
                    o.bloom = BloomMode::Off;
                } else if (std::strcmp(v, "lite") == 0 || v[0] == '1') {
                    o.bloom = BloomMode::Lite;
                } else {
                    o.bloom = BloomMode::Full;
                }
            }
            if (const char* v = std::getenv("GOW3_M1_MOTION_BLUR"); v && v[0]) {
                o.has_mblur = true;
                o.motion_blur = v[0] != '0';
            }
            if (const char* v = std::getenv("GOW3_M1_REFLECTIONS"); v && v[0]) {
                o.has_refl = true;
                o.reflections = v[0] != '0';
            }
            return o;
        }();

        M1ProfileConfig cfg;
        const int level = std::clamp(profile_level, 0, 2);
        if (level == 1) {
            cfg.shadow_limit = 4;
            cfg.bloom = BloomMode::Lite;
            cfg.motion_blur = false;
            cfg.reflections = true;
        } else if (level == 2) {
            cfg.shadow_limit = 2;
            cfg.bloom = BloomMode::Lite;
            cfg.motion_blur = false;
            cfg.reflections = false;
        }
        if (env.has_tbdr) {
            cfg.tbdr_opt = env.tbdr_opt;
        }
        if (env.has_shadow) {
            cfg.shadow_limit = env.shadow_limit;
        }
        if (env.has_bloom) {
            cfg.bloom = env.bloom;
        }
        if (env.has_mblur) {
            cfg.motion_blur = env.motion_blur;
        }
        if (env.has_refl) {
            cfg.reflections = env.reflections;
        }
        return cfg;
    }
};

struct M1DrawContext {
    u32 vs_hash32{};
    u32 ps_hash32{};
    u32 num_bound_colors{};
    VAddr cb0_addr{};
    u32 cb0_width{};
    u32 cb0_height{};
    bool cb0_unorm8{};
    bool has_depth{};
    u32 depth_width{};
    u32 depth_height{};
    bool depth_clear_enable{};
};

class M1Profile {
public:
    struct Stats {
        u64 frames{};
        u64 shadows{};
        u64 motion_blur{};
        u64 bloom{};
        u64 reflections{};
        u64 noop{};
        u64 deferred_zclears{};
        u64 dont_care_loads{};
    };

    void OnFrameStart(int profile_level) {
        cfg = M1ProfileConfig::Resolve(profile_level);
        shadow_cascades = 0;
        in_shadow_cascade = false;
        skip_current_shadow = false;
        seen_main_depth = false;
        reflection_target = 0;
        ++stats.frames;
    }

    [[nodiscard]] bool TbdrOptEnabled() const noexcept {
        return cfg.tbdr_opt;
    }

    [[nodiscard]] const M1ProfileConfig& Config() const noexcept {
        return cfg;
    }

    bool ShouldSkipDraw(const M1DrawContext& ctx) {
        static constexpr u32 kClearVs = 0x2401e5acu;
        static constexpr u32 kClearPs = 0xd1b8f55cu;
        static constexpr u32 kShadowProjVs = 0xd381d0b6u;
        static constexpr u32 kShadowProjPs = 0x811d0c07u;
        static constexpr u32 kMBlurVs = 0x56453c3eu;
        static constexpr u32 kMBlurFeedbackPs = 0xd56574cfu;
        static constexpr u32 kMBlurCompositePs = 0xb4587d5du;
        static constexpr u32 kBloomVs = 0x9987a1e7u;

        // Always learn transient secondary render target addresses so live profile toggles work
        // on the very next frame without restarting.
        if (ctx.vs_hash32 == kMBlurVs && ctx.ps_hash32 == kMBlurFeedbackPs && ctx.cb0_addr) {
            motion_blur_target = ctx.cb0_addr;
        }
        if (!seen_main_depth && ctx.num_bound_colors == 1 && ctx.vs_hash32 == kClearVs &&
            ctx.ps_hash32 == kClearPs && ctx.cb0_addr && ctx.cb0_unorm8 && ctx.has_depth &&
            ctx.depth_clear_enable && ctx.depth_width == ctx.cb0_width &&
            ctx.depth_height == ctx.cb0_height && ctx.cb0_width <= 640 && ctx.cb0_height <= 360) {
            reflection_target = ctx.cb0_addr;
        }

        // Shadow map cascades (2048x2048 depth-only) and their projection passes into scene color.
        if (ctx.num_bound_colors == 0 && ctx.has_depth && ctx.depth_width == 2048 &&
            ctx.depth_height == 2048) {
            seen_main_depth = true;
            if (!in_shadow_cascade || ctx.depth_clear_enable) {
                ++shadow_cascades;
                in_shadow_cascade = true;
                skip_current_shadow =
                    (cfg.shadow_limit >= 0 && shadow_cascades > cfg.shadow_limit);
            }
            if (skip_current_shadow) {
                ++stats.shadows;
                return true;
            }
            return false;
        }
        if (ctx.num_bound_colors == 0 && ctx.has_depth && ctx.depth_width >= 960) {
            seen_main_depth = true;
        }
        if (ctx.vs_hash32 == kShadowProjVs && ctx.ps_hash32 == kShadowProjPs) {
            in_shadow_cascade = false;
            if (skip_current_shadow) {
                ++stats.shadows;
                return true;
            }
            return false;
        }
        if (ctx.num_bound_colors > 0 || ctx.has_depth) {
            in_shadow_cascade = false;
            skip_current_shadow = false;
        }

        // Self-contained half-resolution object motion blur buffer and composite passes.
        if (!cfg.motion_blur) {
            if (ctx.vs_hash32 == kMBlurVs &&
                (ctx.ps_hash32 == kMBlurFeedbackPs || ctx.ps_hash32 == kMBlurCompositePs)) {
                ++stats.motion_blur;
                return true;
            }
            if (motion_blur_target != 0 && ctx.cb0_addr == motion_blur_target && ctx.cb0_unorm8) {
                ++stats.motion_blur;
                return true;
            }
        }

        // Multi-pass bloom pyramid (never skip tone-map/LUT ps 0xd27a6203).
        if (cfg.bloom != BloomMode::Full && ctx.vs_hash32 == kBloomVs) {
            if (IsBloomLowerMipPs(ctx.ps_hash32) ||
                (cfg.bloom == BloomMode::Off && IsBloomBaseOrCompositePs(ctx.ps_hash32))) {
                ++stats.bloom;
                return true;
            }
        }

        // Half-resolution planar reflection render passes (keep initial clear draw and UI intact).
        if (!cfg.reflections && !seen_main_depth && reflection_target != 0 &&
            ctx.cb0_addr == reflection_target && ctx.cb0_unorm8 && ctx.has_depth &&
            ctx.depth_width == ctx.cb0_width && ctx.depth_height == ctx.cb0_height &&
            ctx.vs_hash32 != kClearVs && !IsUiMovieVs(ctx.vs_hash32)) {
            ++stats.reflections;
            return true;
        }

        return false;
    }

    void NoteNoop() noexcept {
        ++stats.noop;
    }
    void NoteDeferredZClear() noexcept {
        ++stats.deferred_zclears;
    }
    void NoteDontCareLoad() noexcept {
        ++stats.dont_care_loads;
    }

    Stats ConsumeStats() noexcept {
        const Stats out = stats;
        stats = {};
        return out;
    }

private:
    static constexpr bool IsBloomLowerMipPs(u32 ps) noexcept {
        return ps == 0x0010caf9u || ps == 0xbe43d0aau || ps == 0x525ec988u;
    }

    static constexpr bool IsBloomBaseOrCompositePs(u32 ps) noexcept {
        return ps == 0x0439fa1bu || ps == 0xcecf26ddu || ps == 0xf9812259u || ps == 0xc9e7c40cu;
    }

    static constexpr bool IsUiMovieVs(u32 vs) noexcept {
        return vs == 0x34e8a281u || vs == 0x81d336ceu || vs == 0x09957251u ||
               vs == 0x24042a9bu || vs == 0xa400228bu;
    }

    M1ProfileConfig cfg{};
    int shadow_cascades = 0;
    bool in_shadow_cascade = false;
    bool skip_current_shadow = false;
    bool seen_main_depth = false;
    VAddr motion_blur_target = 0;
    VAddr reflection_target = 0;
    Stats stats{};
};

} // namespace Vulkan
