#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Physically-motivated defocus.
//
// The reason most webcam "portrait mode" looks like a smudge rather than a lens
// comes down to two things, and both are fixed here:
//
//   1. Real optics average *photons*, which are linear. Blurring in sRGB (which
//      is perceptually encoded, roughly x^(1/2.2)) crushes bright highlights
//      into muddy grey. Blurring in LINEAR light lets a specular glint bloom
//      into a proper bokeh ball. Everything below happens in linear space.
//
//   2. A segmentation mask is binary: you're "person" or "background", so your
//      chair and the wall six metres behind it get blurred by the same amount.
//      Real defocus scales with distance. We use a continuous depth map to
//      compute a per-pixel circle of confusion instead.
// ---------------------------------------------------------------------------

struct BokehUniforms {
    float2 texelSize;
    float  focusDepth;      // normalized scene depth of the focal plane, 0..1
    float  aperture;        // f-number; smaller = shallower depth of field
    float  maxCoCPixels;    // clamp, so a huge blur can't tank the frame rate
    float  highlightBloom;  // 0..1, how strongly highlights blow out
    float  highlightThresh; // linear luminance above which a pixel "blooms"
    int    apertureBlades;  // 0 = circular, 6 = hexagonal
    float  matteStrength;   // how hard the subject matte pins the subject sharp
    int    useDepth;        // 0 = uniform blur behind the subject (mask only)
};

constant float PI = 3.14159265359;
// Golden-angle spiral: gives an evenly-distributed disc with no visible
// structure, unlike a square grid which leaves a lattice in the highlights.
constant float GOLDEN_ANGLE = 2.39996323;
constant int   MAX_SAMPLES = 64;
constant int   MIN_SAMPLES = 12;

// --- colour space ----------------------------------------------------------

inline float3 srgbToLinear(float3 c) {
    return select(c / 12.92,
                  pow((c + 0.055) / 1.055, 3.0),
                  c > 0.04045);
}

inline float3 linearToSrgb(float3 c) {
    return select(c * 12.92,
                  1.055 * pow(c, 1.0 / 2.4) - 0.055,
                  c > 0.0031308);
}

inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// ---------------------------------------------------------------------------
// Pass 1 — NV12 -> linear RGB.
//
// The C1's ISP hands us NV12 straight off the wire. Metal samples the Y and
// CbCr planes as two textures, so the CPU never touches a pixel: no colour
// conversion, no intermediate copy.
// ---------------------------------------------------------------------------

kernel void nv12_to_linear(texture2d<float, access::sample> lumaTex   [[texture(0)]],
                           texture2d<float, access::sample> chromaTex [[texture(1)]],
                           texture2d<float, access::write>  out       [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());

    float  y  = lumaTex.sample(s, uv).r;
    float2 cbcr = chromaTex.sample(s, uv).rg;

    // BT.709, video range (Y 16-235, CbCr 16-240) — what the ISP emits.
    y = (y - 16.0 / 255.0) * (255.0 / 219.0);
    float cb = (cbcr.x - 128.0 / 255.0) * (255.0 / 224.0);
    float cr = (cbcr.y - 128.0 / 255.0) * (255.0 / 224.0);

    float3 rgb = float3(y + 1.5748 * cr,
                        y - 0.1873 * cb - 0.4681 * cr,
                        y + 1.8556 * cb);

    out.write(float4(srgbToLinear(saturate(rgb)), 1.0), gid);
}

// ---------------------------------------------------------------------------
// Matte refinement — joint-bilateral (guided) upsample.
//
// Vision hands back a mask far smaller than the frame. Bilinearly upscaling it
// is what produces the staircase you see marching down the side of a face:
// interpolation can only average the blocky mask it was given, it cannot invent
// an edge, so the mask boundary never lands on the real jawline.
//
// A joint-bilateral upsample fixes this by using the FULL-RESOLUTION image as a
// guide. For each output pixel we gather nearby mask samples, but weight each
// one by how similar its colour is to the centre pixel. A mask sample sitting on
// skin barely influences a pixel on the wall behind it, and vice versa — so the
// mask edge gets pulled onto the actual luminance edge in the photograph. Hair,
// jawlines and shoulders snap into place, and the staircase disappears, because
// the guide image has all the high-frequency detail the mask lacks.
//
// This is the standard cure, and it's why "upscale the mask" is never enough.
// ---------------------------------------------------------------------------

kernel void matte_refine(texture2d<float, access::sample> matteTex [[texture(0)]],
                         texture2d<float, access::sample> guideTex [[texture(1)]],  // linear RGB, full res
                         texture2d<float, access::write>  out      [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 texel = 1.0 / float2(w, h);

    float centerLuma = luminance(guideTex.sample(s, uv).rgb);

    // Radius in full-res pixels. Needs to be wide enough to reach across the
    // blocky mask's own texel, or there's nothing to pull the edge from.
    const int R = 4;
    const float spatialSigma = 3.0;
    const float rangeSigma   = 0.08;   // luma difference that counts as "an edge"

    float accum = 0.0;
    float weightSum = 0.0;

    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            float2 offset = float2(dx, dy) * texel * 2.0;
            float2 suv = uv + offset;

            float m = matteTex.sample(s, suv).r;
            float l = luminance(guideTex.sample(s, suv).rgb);

            float d2 = float(dx * dx + dy * dy);
            float spatial = exp(-d2 / (2.0 * spatialSigma * spatialSigma));

            float dl = l - centerLuma;
            float range = exp(-(dl * dl) / (2.0 * rangeSigma * rangeSigma));

            float wgt = spatial * range;
            accum += m * wgt;
            weightSum += wgt;
        }
    }

    float refined = weightSum > 0.0001 ? accum / weightSum : matteTex.sample(s, uv).r;
    out.write(float4(refined, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// Pass 2 — circle of confusion.
//
// CoC is signed: negative in front of the focal plane, positive behind it. The
// sign matters, because foreground blur must be allowed to spill *over* the
// subject while background blur must not.
//
// The subject matte (from Vision) is not used as the blur mask — it only pins
// the subject to the focal plane. Depth models routinely put part of a cheek or
// a shoulder at the wrong depth, and without this you get a blurry patch on
// someone's face. Belt and braces.
// ---------------------------------------------------------------------------

kernel void compute_coc(texture2d<float, access::sample> depthTex [[texture(0)]],
                        texture2d<float, access::sample> matteTex [[texture(1)]],
                        texture2d<float, access::write>  cocOut   [[texture(2)]],
                        constant BokehUniforms&          u        [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= cocOut.get_width() || gid.y >= cocOut.get_height()) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(cocOut.get_width(), cocOut.get_height());

    float depth = depthTex.sample(s, uv).r;   // 0 = near, 1 = far
    float matte = matteTex.sample(s, uv).r;   // 1 = subject

    // Pull the subject toward the focal plane so it can never be defocused by a
    // noisy depth estimate.
    //
    // Ramp this in smoothly rather than trusting the mask's raw value. The mask
    // is never perfect, and a linear mix turns every one of its imperfections
    // into a visible step in the blur — the sharp/soft boundary traces the mask's
    // errors exactly. Easing across the middle of the range keeps the transition
    // gradual, so a slightly wrong mask degrades into a soft gradient instead of
    // a hard cut-out edge.
    float m = smoothstep(0.15, 0.85, matte);

    // Uniform mode: the mask alone decides. Everything that isn't the subject gets
    // the same blur, so a wrong depth estimate can't put a soft patch on a cheek
    // or leave a chunk of wall in focus. Fewer failure modes, and it's what most
    // video-call software actually ships.
    if (u.useDepth == 0) {
        float coc = (1.0 - m) * u.maxCoCPixels * saturate(3.5 / max(u.aperture, 1.0));
        cocOut.write(float4(coc, 0, 0, 1), gid);
        return;
    }

    depth = mix(depth, u.focusDepth, m * u.matteStrength);

    // Thin-lens-ish: CoC grows with distance from the focal plane and shrinks as
    // the aperture closes.
    //
    // The previous ramp divided by (aperture * 0.06), which at f/6.5 meant a
    // depth difference of only 0.39 already saturated to MAXIMUM blur — so
    // essentially everything that wasn't exactly on the focal plane got slammed,
    // and the result was a uniform haze that smeared the whole room together
    // rather than a depth-graded falloff. This is far gentler: at f/2.8 you get
    // a strong, obvious effect; by f/11 it's nearly gone, which is what those
    // numbers mean on a real lens.
    float signedDist = depth - u.focusDepth;
    float strength = 3.5 / max(u.aperture, 1.0);
    float coc = clamp(signedDist * strength, -1.0, 1.0) * u.maxCoCPixels;

    cocOut.write(float4(coc, 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// Pass 3 — the gather.
//
// Scatter-as-gather: for each output pixel, walk a disc of neighbours and accept
// a neighbour only if *its* CoC is large enough to have splattered this far. A
// naive gather blurs a sharp foreground into the background and leaves a halo
// around the subject; this is the standard fix.
//
// Highlight weighting is what sells it. Weighting each sample by its own
// luminance (raised to a power) means a bright glint dominates the average and
// spreads into a bright, well-defined disc — the "bokeh ball" — instead of
// being averaged into mush.
// ---------------------------------------------------------------------------

kernel void bokeh_gather(texture2d<float, access::sample> colorTex [[texture(0)]],
                         texture2d<float, access::sample> cocTex   [[texture(1)]],
                         texture2d<float, access::write>  out      [[texture(2)]],
                         constant BokehUniforms&          u        [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);

    float  centerCoC = cocTex.sample(s, uv).r;
    float3 centerCol = colorTex.sample(s, uv).rgb;

    float radius = abs(centerCoC);

    // In focus: skip the whole gather. Most of a typical frame lands here, so
    // this early-out is most of the performance.
    if (radius < 1.0) {
        out.write(float4(centerCol, 1.0), gid);
        return;
    }

    float3 accum = 0.0;
    float  weightSum = 0.0;

    // Sample density has to keep up with the disc's area, or a wide blur ends up
    // as a sparse scatter of samples that reads as a dirty smear rather than a
    // smooth defocus. Scale the count with the radius and spend the budget only
    // where the blur is actually wide.
    int sampleCount = clamp(int(radius * 2.5), MIN_SAMPLES, MAX_SAMPLES);

    // Gamma-weighted accumulation — this is what actually produces bokeh BALLS.
    //
    // Averaging colour linearly spreads a bright glint's energy evenly across the
    // disc, so it fades to a dim smudge. Averaging in a higher power instead lets
    // bright samples dominate, then taking the root on the way out restores the
    // level — the highlight survives as a distinct bright disc instead of being
    // washed into its neighbours. p = 1 is a plain average (no bloom).
    //
    // The previous approach keyed off a luminance threshold of 0.75 in LINEAR
    // light (~0.89 as displayed) and ramped to 1.25, above the maximum possible
    // value — so almost nothing in a normal room ever crossed it, and even pure
    // white only reached half strength. It was effectively dead code.
    float p = 1.0 + u.highlightBloom * 6.0;

    for (int i = 0; i < sampleCount; ++i) {
        float t     = (float(i) + 0.5) / float(sampleCount);
        float r     = sqrt(t);                    // sqrt keeps the disc uniform
        float theta = float(i) * GOLDEN_ANGLE;

        float2 dir = float2(cos(theta), sin(theta));

        // A polygonal aperture (a 6-blade iris, say) makes highlights hexagonal
        // rather than round. Opal chose hexagons; we let the user pick.
        if (u.apertureBlades > 2) {
            float bladeAngle = 2.0 * PI / float(u.apertureBlades);
            float a = theta - bladeAngle * floor(theta / bladeAngle) - bladeAngle * 0.5;
            r *= cos(bladeAngle * 0.5) / max(cos(a), 0.2);
        }

        float2 offset = dir * r * radius;
        float2 sampleUV = uv + offset * u.texelSize;

        float3 col = colorTex.sample(s, sampleUV).rgb;
        float  sCoC = cocTex.sample(s, sampleUV).r;

        // Only accept a neighbour whose own blur is wide enough to reach us.
        // Without this, sharp foreground bleeds outward and haloes the subject.
        float reach = smoothstep(0.0, 1.0, (abs(sCoC) - length(offset) + 1.0));

        // Foreground (negative CoC) is allowed to spill over things behind it;
        // background is not allowed to spill onto the subject.
        if (sCoC < 0.0 && centerCoC >= 0.0) reach = 1.0;

        accum += pow(max(col, 0.0), p) * reach;
        weightSum += reach;
    }

    float3 result = weightSum > 0.0001
        ? pow(accum / weightSum, 1.0 / p)
        : centerCol;
    out.write(float4(result, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Pass 4 — composite and encode.
//
// Blend sharp and blurred by |CoC| so the transition into defocus is gradual
// rather than a visible cutout edge, then go back to sRGB for display/encode.
// ---------------------------------------------------------------------------

kernel void composite(texture2d<float, access::sample> sharpTex [[texture(0)]],
                      texture2d<float, access::sample> blurTex  [[texture(1)]],
                      texture2d<float, access::sample> cocTex   [[texture(2)]],
                      texture2d<float, access::write>  out      [[texture(3)]],
                      constant BokehUniforms&          u        [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);

    float3 sharp = sharpTex.sample(s, uv).rgb;
    float3 blur  = blurTex.sample(s, uv).rgb;
    float  coc   = abs(cocTex.sample(s, uv).r);

    float mixAmt = smoothstep(0.5, 2.5, coc);
    float3 lin = mix(sharp, blur, mixAmt);

    out.write(float4(linearToSrgb(saturate(lin)), 1.0), gid);
}

// ---------------------------------------------------------------------------
// Preview blit — aspect-fill.
//
// A blit-encoder copy can only move pixels 1:1, which letterboxes the image
// inside the window. This draws a full-screen triangle instead and samples the
// frame with an aspect-preserving *fill* (crop the overflowing axis rather than
// pad it), so the preview always covers the window edge to edge.
//
// Mirroring happens here, and only here: a webcam preview should read like a
// mirror, but the image sent to other people must NOT be mirrored or their text
// comes out backwards. Keeping the flip in the preview path means the virtual
// camera can share every earlier stage and still go out the right way round.
// ---------------------------------------------------------------------------

struct PreviewUniforms {
    float2 scale;     // uv scale for aspect-fill
    int    mirror;
};

struct PreviewVertex {
    float4 position [[position]];
    float2 uv;
};

vertex PreviewVertex preview_vertex(uint vid [[vertex_id]],
                                    constant PreviewUniforms& u [[buffer(0)]]) {
    // One oversized triangle covers the viewport with no vertex buffer.
    float2 pos[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
    float2 p = pos[vid];

    PreviewVertex out;
    out.position = float4(p, 0, 1);

    // Clip space (-1..1, y up) -> texture uv (0..1, y down).
    float2 uv = float2((p.x + 1) * 0.5, 1.0 - (p.y + 1) * 0.5);

    // Zoom about the centre so the short axis fills and the long axis crops.
    uv = (uv - 0.5) * u.scale + 0.5;

    if (u.mirror != 0) uv.x = 1.0 - uv.x;

    out.uv = uv;
    return out;
}

fragment float4 preview_fragment(PreviewVertex in [[stage_in]],
                                 texture2d<float, access::sample> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

// ---------------------------------------------------------------------------
// Depth/matte post — temporal smoothing.
//
// The crawling, shimmering edges you see in most virtual-background software are
// per-frame jitter in the mask: the network makes a slightly different decision
// each frame and the edge vibrates. An exponential moving average costs almost
// nothing and removes nearly all of it. We blend a little faster where the
// estimate moved a lot, so genuine motion isn't smeared into a trail.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Depth history — a BACKGROUND depth map.
//
// The naive thing is to smooth the raw depth map over time. That produces a
// blur which visibly trails the subject, and the reason is subtle: *you are in
// the depth map*. Stand still, and the pixels you occupy record your depth
// (near). Step aside, and those pixels should instantly become the wall behind
// you (far) — but a smoothed history still holds your old near-depth for as long
// as its time constant, so the vacated region keeps reading as "close to the
// focal plane" and keeps rendering SHARP. A person-shaped sharp ghost, dragging
// along behind you.
//
// So: never let the subject write into the depth history. Where the matte says
// "this is the person", we freeze the history and keep whatever background depth
// we last saw there. The moment they move away, the correct background depth is
// already sitting there waiting — no catch-up, no trail. And the subject itself
// doesn't need a depth: it's pinned to the focal plane by the matte anyway.
// ---------------------------------------------------------------------------

kernel void depth_smooth(texture2d<float, access::sample> currentTex [[texture(0)]],
                         texture2d<float, access::sample> matteTex   [[texture(1)]],
                         texture2d<float, access::sample> historyIn  [[texture(2)]],
                         texture2d<float, access::write>  historyOut [[texture(3)]],
                         constant float&                  alpha      [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= historyOut.get_width() || gid.y >= historyOut.get_height()) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(historyOut.get_width(), historyOut.get_height());

    float cur   = currentTex.sample(s, uv).r;
    float hist  = historyIn.sample(s, uv).r;
    float matte = matteTex.sample(s, uv).r;

    float delta = abs(cur - hist);
    // Move faster where the estimate changed a lot — that's real geometry
    // appearing (a revealed wall), not noise.
    float a = mix(alpha, 1.0, smoothstep(0.06, 0.25, delta));

    // ...but never where the subject is standing. Freeze, and keep the background.
    a *= 1.0 - smoothstep(0.35, 0.65, matte);

    historyOut.write(float4(mix(hist, cur, a), 0, 0, 1), gid);
}

// ---------------------------------------------------------------------------
// Mask stabilisation — motion-adaptive, with hysteresis.
//
// The segmentation network re-decides every frame with no memory, so it will
// happily flip-flop on an ambiguous object: one frame "person", the next
// "background". The object hasn't moved — the *decision* moved. On screen that's
// a static thing pulsing in and out of focus, which is far more distracting than
// any amount of blur error, because the eye is drawn to change.
//
// A single smoothing rate can't fix this. Smooth hard enough to kill the flicker
// and the blur trails your head; smooth lightly enough to track your head and the
// flicker comes back. The two requirements are in direct conflict...
//
// ...but only if you apply the same rate everywhere. They never actually collide
// in the same PIXEL: a flickering object is one that ISN'T MOVING, and your head
// is one that IS. So look at the image itself. Where the picture is static, trust
// history and average hard — a still object has no legitimate reason for its mask
// to change, so any change there is noise. Where the picture is moving, believe
// the new mask immediately.
//
// Hysteresis on top: small disagreements with history are ignored outright, so a
// mask hovering around the decision boundary settles instead of buzzing.
// ---------------------------------------------------------------------------

kernel void matte_stabilize(texture2d<float, access::sample> currentTex  [[texture(0)]],
                            texture2d<float, access::sample> historyIn   [[texture(1)]],
                            texture2d<float, access::sample> guideTex    [[texture(2)]], // linear RGB
                            texture2d<float, access::sample> prevLumaIn  [[texture(3)]],
                            texture2d<float, access::write>  historyOut  [[texture(4)]],
                            texture2d<float, access::write>  prevLumaOut [[texture(5)]],
                            constant float2&                 alphas      [[buffer(0)]], // (static, moving)
                            uint2 gid [[thread_position_in_grid]]) {
    uint w = historyOut.get_width(), h = historyOut.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);

    float cur   = currentTex.sample(s, uv).r;
    float hist  = historyIn.sample(s, uv).r;
    float luma  = luminance(guideTex.sample(s, uv).rgb);
    float prevL = prevLumaIn.sample(s, uv).r;

    // How much did the PICTURE change here? (Not the mask — the picture.)
    float motion = abs(luma - prevL);
    float moving = smoothstep(0.015, 0.10, motion);

    // Static pixels average hard; moving pixels snap to the new mask.
    float a = mix(alphas.x, alphas.y, moving);

    // Hysteresis: ignore small disagreements entirely. This is what stops a mask
    // sitting near the decision boundary from buzzing between two values forever.
    float disagreement = abs(cur - hist);
    a *= smoothstep(0.04, 0.14, disagreement);

    historyOut.write(float4(mix(hist, cur, a), 0, 0, 1), gid);
    prevLumaOut.write(float4(luma, 0, 0, 1), gid);
}

kernel void temporal_smooth(texture2d<float, access::sample> currentTex [[texture(0)]],
                            texture2d<float, access::sample> historyTex [[texture(1)]],
                            texture2d<float, access::write>  out        [[texture(2)]],
                            constant float&                  alpha      [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());

    float cur  = currentTex.sample(s, uv).r;
    float hist = historyTex.sample(s, uv).r;

    float delta = abs(cur - hist);
    float a = mix(alpha, 1.0, smoothstep(0.15, 0.5, delta));

    out.write(float4(mix(hist, cur, a), 0, 0, 1), gid);
}
