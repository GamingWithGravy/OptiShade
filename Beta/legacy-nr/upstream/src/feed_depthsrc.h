// feed_depthsrc.h - which game buffer ReShade's Generic Depth is actually handing the shader (#145).
//
// Every depth check this project had looked at the depth AFTER DLSS5_Feed.fx had drawn it: the
// FLAT probe (a wrong buffer with nothing in it) and the resource line (what NGX receives, which
// is always the feed's own work-size texture). A wrong buffer WITH content passes both. SnowRunner
// with in-game MSAA on: the scene depth is multisampled, Generic Depth cannot read multisampled
// depth and greys it out, and its heuristic falls back to a 4608x1536 shadow-cascade atlas at a
// 3440x1440 back buffer. The probe called that healthy for 82 straight in-game samples while DLSS
// was fed entirely wrong depth. Turning MSAA off fixed it and gained ~14% frame rate.
//
// Two facts, both available without touching the GPU:
//   - the resource behind the `DepthBufferTex : DEPTH` texture of ReShade.fxh, as bound in
//     DLSS5_Feed.fx right now, against the back buffer it is supposed to match;
//   - every multisampled depth-stencil texture the game creates (init_resource), since a greyed
//     out MSAA candidate at screen size is exactly what makes Generic Depth pick something else.
//
// Shared by the 64-bit add-on and the 32-bit / helper add-on; each passes its own Log and tag.

#pragma once
#include <reshade.hpp>
#include <atomic>
#include <string.h>
#include <stdlib.h>

namespace feed_depthsrc
{
    // The largest multisampled depth-stencil texture the game has made. Written on whatever
    // thread creates resources, read on the render thread: packed into one word so the pair
    // can never be read half-updated.
    static std::atomic<uint64_t> g_msaa_depth{ 0 };   // (w << 32) | (h << 8) | samples, 0 = none seen

    static void OnInitResource(reshade::api::device *, const reshade::api::resource_desc &desc,
                               const reshade::api::subresource_data *, reshade::api::resource_usage,
                               reshade::api::resource)
    {
        if (desc.type != reshade::api::resource_type::texture_2d) return;
        if ((desc.usage & reshade::api::resource_usage::depth_stencil) == reshade::api::resource_usage::undefined) return;
        if (desc.texture.samples <= 1) return;
        const uint64_t w = desc.texture.width, h = desc.texture.height;
        const uint64_t packed = (w << 32) | ((h & 0xFFFFFFu) << 8) | (desc.texture.samples & 0xFFu);
        uint64_t cur = g_msaa_depth.load(std::memory_order_relaxed);
        while (((cur >> 32) * ((cur >> 8) & 0xFFFFFFu)) < w * h &&
               !g_msaa_depth.compare_exchange_weak(cur, packed, std::memory_order_relaxed)) {}
    }

    static void Register()   { reshade::register_event<reshade::addon_event::init_resource>(OnInitResource); }
    static void Unregister() { reshade::unregister_event<reshade::addon_event::init_resource>(OnInitResource); }

    // Within 1% (and 8 px: 1920x1088-style padding) of the back buffer in both axes.
    static bool Near(uint32_t a, uint32_t b)
    {
        const uint32_t d = a > b ? a - b : b - a;
        return d <= 8 || d * 100 <= b;
    }

    // Call on the bound runtime's DLSS5_Feed render. Rate-limits itself (every 2 s) and logs only
    // when what it sees changes, so it costs nothing worth measuring.
    static void Check(reshade::api::effect_runtime *rt, const char *effect_file, void (*log)(const char *, ...),
                      const char *tag)
    {
        static ULONGLONG last = 0;
        const ULONGLONG now = GetTickCount64();
        if (now - last < 2000) return;
        last = now;

        reshade::api::device *dev = rt->get_device();
        if (dev == nullptr) return;

        reshade::api::effect_texture_variable var = {};
        rt->enumerate_texture_variables(effect_file, [&var](reshade::api::effect_runtime *r, reshade::api::effect_texture_variable v) {
            if (var.handle != 0) return;
            char name[128] = {};
            r->get_texture_variable_name(v, name);
            const size_t n = strlen(name), k = sizeof("DepthBufferTex") - 1;
            if (n >= k && strcmp(name + n - k, "DepthBufferTex") == 0) var = v;
        });
        if (var.handle == 0) return;   // an older DLSS5_Feed.fx without ReShade.fxh's depth texture

        reshade::api::resource_view srv = {}, srv_srgb = {};
        rt->get_texture_binding(var, &srv, &srv_srgb);
        if (srv.handle == 0) return;   // Generic Depth has bound nothing yet: the FLAT probe covers that
        const reshade::api::resource res = dev->get_resource_from_view(srv);
        if (res.handle == 0) return;
        const reshade::api::resource_desc dd = dev->get_resource_desc(res);

        const reshade::api::resource bb = rt->get_current_back_buffer();
        if (bb.handle == 0) return;
        const reshade::api::resource_desc bd = dev->get_resource_desc(bb);
        const uint32_t dw = dd.texture.width, dh = dd.texture.height, bw = bd.texture.width, bh = bd.texture.height;
        if (dw == 0 || dh == 0 || bw == 0 || bh == 0) return;

        const uint64_t msaa = g_msaa_depth.load(std::memory_order_relaxed);
        const uint32_t mw = static_cast<uint32_t>(msaa >> 32), mh = static_cast<uint32_t>((msaa >> 8) & 0xFFFFFFu),
                       ms = static_cast<uint32_t>(msaa & 0xFFu);
        const bool msaa_screen = msaa != 0 && Near(mw, bw) && Near(mh, bh);

        // Only speak when something changed: the bound buffer, the back buffer or the MSAA picture.
        static uint64_t said[3] = {};
        const uint64_t now_state[3] = { (uint64_t(dw) << 32) | dh, (uint64_t(bw) << 32) | bh, msaa };
        if (memcmp(said, now_state, sizeof(said)) == 0) return;
        memcpy(said, now_state, sizeof(said));

        char msaa_note[400] = {};
        if (msaa_screen)
            _snprintf_s(msaa_note, sizeof(msaa_note), _TRUNCATE,
                        " The game also made a %ux%u depth buffer with %u samples (MSAA): ReShade cannot read multisampled "
                        "depth, which is why Generic Depth greys it out and cannot pick the real scene depth. Turn MSAA off "
                        "in the game's graphics settings -- DLSS already antialiases, so it costs nothing and usually gains "
                        "frame rate.", mw, mh, ms);

        const bool screen_sized = Near(dw, bw) && Near(dh, bh);
        if (screen_sized && !msaa_screen)
        {
            log("[%s] depth source: Generic Depth gives the shader a %ux%u buffer, %u sample(s), at the %ux%u back buffer -- the right size",
                tag, dw, dh, static_cast<unsigned>(dd.texture.samples), bw, bh);
            return;
        }

        // Smaller at the same aspect ratio is a game rendering 3D below its output resolution
        // (render scale, dynamic resolution). That depth is the right one and DLSS takes it.
        const double da = static_cast<double>(dw) / dh, ba = static_cast<double>(bw) / bh;
        if (dw < bw && dh < bh && (da > ba ? da / ba : ba / da) < 1.02 && !msaa_screen)
        {
            log("[%s] depth source: Generic Depth gives the shader a %ux%u buffer at the %ux%u back buffer -- same aspect "
                "ratio, smaller: the game renders 3D at %u%% (render scale or dynamic resolution). That is normal.",
                tag, dw, dh, bw, bh, dw * 100 / bw);
            return;
        }

        char line[1100];
        // Screen-sized but the game also has a screen-sized MSAA depth (#145): the scene is drawn into
        // the MSAA one, so the single-sample buffer bound here is most likely a near-empty side target.
        if (screen_sized)
            _snprintf_s(line, sizeof(line), _TRUNCATE,
                        "depth source: Generic Depth gives the shader a %ux%u single-sample buffer at the back buffer's size, "
                        "but the game draws its scene into a multisampled depth buffer ReShade cannot read, so the bound one "
                        "is probably a near-empty side target (watch for 'depth is FLAT' lines).%s",
                        dw, dh, msaa_note);
        else
        _snprintf_s(line, sizeof(line), _TRUNCATE,
                    "depth source: Generic Depth gives the shader a %ux%u buffer, but the back buffer is %ux%u. That is "
                    "not the scene's depth -- most likely a shadow map or atlas -- so DLSS and the neural pass are fed "
                    "wrong depth even while the depth probe looks healthy.%s%s",
                    dw, dh, bw, bh, msaa_note,
                    msaa_screen ? "" : " Open the ReShade overlay > Add-ons > Generic Depth and pick the candidate at your "
                                       "resolution with the most draw calls; if it is greyed out as multisampled, turn MSAA off "
                                       "in the game.");
        log("[%s] WARNING: %s", tag, line);
        char tagged[1200];
        _snprintf_s(tagged, sizeof(tagged), _TRUNCATE, "[DLSS 5 Feed] %s", line);
        reshade::log::message(reshade::log::level::warning, tagged);
    }
}
