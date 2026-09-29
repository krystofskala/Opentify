#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Pořadí uniformů = indexy `setFloat` v lib/widgets/app_background.dart.
uniform vec2 uSize;        // 0-1  logické pixely
uniform float uTime;       // 2    fáze pohybu, periodická po 600 jednotkách
uniform float uWarp;       // 3    síla "tekutého" pokřivení
uniform float uGrain;      // 4    amplituda zrna (sRGB, ±)
uniform float uPixelRatio; // 5
uniform float uBloom;      // 6    krátké rozjasnění při změně skladby/barvy
uniform float uDark;       // 7    1 = tmavý režim
uniform vec3 uC0;          // 8    základní tón (pozadí)
uniform vec3 uC1;          // 11
uniform vec3 uC2;          // 14
uniform vec3 uC3;          // 17
uniform vec3 uC4;          // 20   světlý highlight (pruhy/jiskry)
uniform vec3 uC5;          // 23
// Předchozí paleta -- při změně skladby se zrno přebarvuje zrnko po zrnku.
uniform vec3 uP0;          // 26
uniform vec3 uP1;          // 29
uniform vec3 uP2;          // 32
uniform vec3 uP3;          // 35
uniform vec3 uP4;          // 38
uniform vec3 uP5;          // 41
uniform float uMix;        // 44   0 = předchozí paleta, 1 = nová

out vec4 fragColor;

const float TAU = 6.2831853;
const float W0 = TAU / 600.0;

// Hash s malými, omezenými vstupy (volající drží p < ~300) -- bez sin(),
// takže se nerozpadne ani při mediump přesnosti v iOS Safari.
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(mod(i, 289.0));
    float b = hash(mod(i + vec2(1.0, 0.0), 289.0));
    float c = hash(mod(i + vec2(0.0, 1.0), 289.0));
    float d = hash(mod(i + vec2(1.0, 1.0), 289.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
    return 0.65 * noise(p) + 0.35 * noise(p * 2.03 + 17.0);
}

// Lissajousova dráha jednoho barevného bodu; frekvence jsou celé násobky
// W0, takže je celý pohyb periodický a Dart může fázi bezešvě zabalit.
vec2 lissa(float t, float fx, float fy, float ph, float aspect) {
    return vec2(0.46 * aspect * sin(W0 * fx * t + ph), 0.40 * cos(W0 * fy * t + ph * 1.7));
}

vec3 glow(vec3 col, vec3 c, vec2 p, vec2 center, float radius, float strength) {
    vec2 d = p - center;
    float w = exp(-dot(d, d) / (radius * radius));
    return mix(col, c, clamp(w * strength, 0.0, 1.0));
}

vec3 scene(vec3 c0, vec3 c1, vec3 c2, vec3 c3, vec3 c4, vec3 c5, vec2 pw, float t, float aspect, float band) {
    vec3 col = c0;
    col = glow(col, c1, pw, lissa(t, 10.0, 7.0, 0.0, aspect), 0.62, 0.95);
    col = glow(col, c2, pw, lissa(t, 6.0, 11.0, 2.1, aspect), 0.48, 0.90);
    col = glow(col, c3, pw, lissa(t, 13.0, 9.0, 4.2, aspect), 0.40, 0.85);
    col = glow(col, c5, pw, lissa(t, 8.0, 14.0, 1.3, aspect), 0.34, 0.80);
    col = glow(col, c4, pw, lissa(t, 11.0, 6.0, 5.4, aspect), 0.22 + 0.06 * uBloom, 0.55 + 0.35 * uBloom);
    return mix(col, c4, band * band * 0.24);
}

void main() {
    vec2 frag = FlutterFragCoord().xy;
    vec2 uv = frag / uSize;
    float aspect = uSize.x / uSize.y;
    vec2 p = vec2((uv.x - 0.5) * aspect, uv.y - 0.5);
    float t = uTime;

    // Tekuté pokřivení prostoru (2 fbm = 4 vyhodnocení šumu).
    vec2 drift = vec2(cos(W0 * 7.0 * t), sin(W0 * 5.0 * t)) * 1.4;
    vec2 q = vec2(fbm(p * 1.5 + drift), fbm(p * 1.5 - drift + vec2(5.2, 1.3)));
    vec2 pw = p + (q - 0.5) * uWarp;

    // Lesklé "tekuté" pruhy (1 fbm = 2 vyhodnocení šumu).
    // Nízká frekvence + širší náběh = pár rozmáchlých tekutých šmouh, ne
    // síť tenkých obrysů.
    float n = fbm(pw * 1.3 - drift * 0.5);
    float band = 1.0 - smoothstep(0.0, 0.12, abs(n - 0.52));

    // Vrstvené měkké záře -- velké "bokeh" skvrny i roztažené tekuté tvary
    // -- pro novou i předchozí paletu (tvary stejné, jen barvy).
    vec3 col = scene(uC0, uC1, uC2, uC3, uC4, uC5, pw, t, aspect, band);

    // Změna palety: každé zrnko se přebarví ve vlastní chvíli (náhodný práh
    // zrnka + měkké ostrůvky), takže to vypadá, že zrno postupně mění barvu
    // -- ne jako prolnutí celé plochy najednou.
    vec2 cell = floor(frag * uPixelRatio / 1.6);
    if (uMix < 0.999) {
        vec3 prev = scene(uP0, uP1, uP2, uP3, uP4, uP5, pw, t, aspect, band);
        float th = 0.55 * hash(mod(cell, 283.0) + 11.0) + 0.45 * noise(p * 2.2 + 3.0);
        float m = smoothstep(th - 0.08, th + 0.08, uMix * 1.16 - 0.08);
        col = mix(prev, col, m);
    }

    // Tmavý režim: jemná vinětace pro hloubku; světlý bez ní.
    float vig = smoothstep(0.35, 1.05, length(p * vec2(0.8, 1.0)));
    col *= mix(1.0, mix(1.0, 0.78, vig), uDark);
    col += uBloom * 0.04;

    // Filmové zrno: statické v prostoru obrazovky, buňky ~1.6 fyzického px,
    // trojúhelníkové rozdělení. Dva různé moduly -> bez viditelného dláždění.
    float g = hash(mod(cell, 289.0)) + hash(mod(cell, 257.0) + 7.0) - 1.0;
    col += g * uGrain;

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
