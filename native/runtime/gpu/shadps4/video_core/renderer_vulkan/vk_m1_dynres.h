// SPDX-License-Identifier: GPL-2.0-or-later
// gow3 (M1): Dynamic internal 3D resolution controller using draw-count + frametime hysteresis.

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "common/types.h"
#include "video_core/renderer_vulkan/scene_resolution.h"

namespace Vulkan {

class M1DynRes {
public:
    static SceneResolution::Size TierSize(SceneResolution::Size base, int tier) {
        tier = std::clamp(tier, 0, 3);
        if (tier == 0 || base.width == 0 || base.height == 0) {
            return base;
        }
        if (base.width == 960 && base.height == 540) {
            constexpr std::array<SceneResolution::Size, 4> k540 = {{
                {960, 540},
                {800, 450},
                {768, 432},
                {704, 396},
            }};
            return k540[tier];
        }
        if (base.width == 1280 && base.height == 720) {
            constexpr std::array<SceneResolution::Size, 4> k720 = {{
                {1280, 720},
                {1088, 612},
                {960, 540},
                {832, 468},
            }};
            return k720[tier];
        }
        constexpr std::array<double, 4> kScales = {1.0, 0.85, 0.75, 0.65};
        const double s = kScales[tier];
        const auto round_even = [](u32 dim, double scale, u32 min_even) -> u32 {
            const long even = std::max(1l, std::lround((double(dim) * scale) / 2.0)) * 2l;
            const u32 lo = std::min(dim, min_even);
            const u32 max_even = (dim >= 2) ? (dim & ~1u) : dim;
            return std::clamp(static_cast<u32>(even), lo, std::max(lo, max_even));
        };
        return {round_even(base.width, s, 640u), round_even(base.height, s, 360u)};
    }

    void ObserveBaseSize(u32 w, u32 h) {
        if (w >= 800 && w <= 1920 && h >= 450 && h <= 1080 && w != 2048 && (w % 2 == 0) &&
            (h % 2 == 0)) {
            if (!has_base || base_size.width != w || base_size.height != h) {
                base_size = {w, h};
                has_base = true;
                if (current_size.width == 0 || tier == 0) {
                    current_size = base_size;
                } else {
                    current_size = TierSize(base_size, tier);
                }
            }
        }
    }

    SceneResolution::Size OnFrameBoundary(u32 draws, double frame_ms, double elapsed_s,
                                          int setting_mode) {
        struct EnvConfig {
            bool has_mode = false;
            int mode = 1;
            bool has_force = false;
            SceneResolution::Size force_size{};
            int threshold = 1050;
        };
        static const EnvConfig env = [] {
            EnvConfig cfg;
            if (const char* v = std::getenv("GOW3_M1_DYNRES"); v && v[0]) {
                cfg.has_mode = true;
                if (std::strcmp(v, "off") == 0 || v[0] == '0') {
                    cfg.mode = 0;
                } else if (std::strcmp(v, "aggressive") == 0 || v[0] == '2') {
                    cfg.mode = 2;
                } else {
                    cfg.mode = 1;
                }
            }
            if (const char* v = std::getenv("GOW3_M1_DYNRES_FORCE"); v && v[0]) {
                u32 fw = 0, fh = 0;
                if (std::sscanf(v, "%ux%u", &fw, &fh) == 2 && fw >= 320 && fh >= 180) {
                    cfg.has_force = true;
                    cfg.force_size = {fw & ~1u, fh & ~1u};
                }
            }
            if (const char* v = std::getenv("GOW3_M1_DYNRES_THRESH"); v && v[0]) {
                cfg.threshold = std::clamp(std::atoi(v), 300, 4000);
            }
            return cfg;
        }();

        if (!has_base) {
            return SceneResolution::Size{0, 0};
        }

        const int mode = std::clamp(env.has_mode ? env.mode : setting_mode, 0, 2);
        if (mode == 0 && !env.has_force) {
            tier = 0;
            down_hold = 0;
            up_hold = 0;
            current_size = base_size;
            return current_size;
        }

        if (env.has_force) {
            const u32 w = std::clamp(env.force_size.width & ~1u, 320u, base_size.width & ~1u);
            const u32 h = std::clamp(env.force_size.height & ~1u, 180u, base_size.height & ~1u);
            current_size = {w, h};
            return current_size;
        }

        const double clamped_ms = std::clamp(frame_ms, 4.0, 250.0);
        if (!ema_ready) {
            ema_draws = double(draws);
            ema_ms = clamped_ms;
            ema_ready = true;
        } else {
            constexpr double kAlpha = 0.2;
            ema_draws = (1.0 - kAlpha) * ema_draws + kAlpha * double(draws);
            ema_ms = (1.0 - kAlpha) * ema_ms + kAlpha * clamped_ms;
        }

        const int max_tier = (mode >= 2) ? 3 : 2;
        if (tier > max_tier) {
            tier = max_tier;
        }

        const double t0 = double(env.threshold);
        bool want_down = false;
        if (tier < max_tier && draws >= 400) {
            if (tier == 0) {
                want_down = (ema_draws >= t0 || ema_ms >= 44.0);
            } else if (tier == 1) {
                want_down = (ema_draws >= (t0 + 400.0) || ema_ms >= 52.0);
            } else if (tier == 2) {
                want_down = (ema_draws >= (t0 + 700.0) || ema_ms >= 58.0);
            }
        }

        bool want_up = false;
        if (!want_down && tier > 0) {
            if (draws < 400) {
                want_up = true;
            } else if (tier == 3) {
                want_up = (ema_draws <= (t0 + 400.0) && ema_ms <= 42.0);
            } else if (tier == 2) {
                want_up = (ema_draws <= (t0 + 100.0) && ema_ms <= 38.0);
            } else if (tier == 1) {
                want_up = (ema_draws <= (t0 - 250.0) && ema_ms <= 34.0);
            }
        }

        const bool down_cooldown_ok = (last_change_s < 0.0) || ((elapsed_s - last_change_s) >= 2.0);
        const bool up_cooldown_ok = (last_change_s < 0.0) || ((elapsed_s - last_change_s) >= 3.5);

        if (want_down) {
            ++down_hold;
            up_hold = 0;
            if (down_hold >= 15 && down_cooldown_ok) {
                ++tier;
                last_change_s = elapsed_s;
                down_hold = 0;
                up_hold = 0;
                ++tier_changes;
            }
        } else if (want_up) {
            ++up_hold;
            down_hold = 0;
            if (up_hold >= 45 && up_cooldown_ok) {
                --tier;
                last_change_s = elapsed_s;
                down_hold = 0;
                up_hold = 0;
                ++tier_changes;
            }
        } else {
            down_hold = 0;
            up_hold = 0;
        }

        current_size = TierSize(base_size, tier);
        return current_size;
    }

    [[nodiscard]] bool HasBase() const noexcept { return has_base; }
    [[nodiscard]] SceneResolution::Size BaseSize() const noexcept { return base_size; }
    [[nodiscard]] SceneResolution::Size CurrentSize() const noexcept { return current_size; }
    [[nodiscard]] int Tier() const noexcept { return tier; }
    [[nodiscard]] double EmaDraws() const noexcept { return ema_draws; }
    [[nodiscard]] double EmaMs() const noexcept { return ema_ms; }

    u64 ConsumeTierChanges() noexcept {
        const u64 out = tier_changes;
        tier_changes = 0;
        return out;
    }

private:
    bool has_base = false;
    bool ema_ready = false;
    SceneResolution::Size base_size{0, 0};
    SceneResolution::Size current_size{0, 0};
    int tier = 0;
    u32 down_hold = 0;
    u32 up_hold = 0;
    double ema_draws = 0.0;
    double ema_ms = 0.0;
    double last_change_s = -1.0;
    u64 tier_changes = 0;
};

} // namespace Vulkan
