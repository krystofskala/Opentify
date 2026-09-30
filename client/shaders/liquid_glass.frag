#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Liquid Glass s lomem (schválený náhled "Lom skla"): obsah pod sklem
// (zachycené pozadí appky + stránka) se v pruhu u hrany láme podle Snellova
// zákona na profilu "squircle" (n = 1.5, paprsek jde celou tloušťkou skla,
// nejsilněji u hrany), střed je rozmazaný, u hrany čistší, lem v barvě
// obsahu. Pořadí uniformů = indexy `setFloat` v lib/widgets/glass/liquid_glass.dart.
uniform vec2 uSize;       // 0-1   velikost prvku (logické px)
uniform vec2 uOrigin;     // 2-3   poloha prvku v zachyceném výřezu (logické px)
uniform vec2 uCapSize;    // 4-5   velikost výřezu (logické px)
uniform float uRadius;    // 6
uniform float uBezel;     // 7
uniform float uStrength;  // 8
uniform float uBlur;      // 9     poloměr rozmazání středu (px)
uniform vec4 uFill;       // 10-13 výplň skla (rgb, alfa)
uniform float uSat;       // 14    vibrance
uniform float uNorm;      // 15    normování posunu (max přes profil)
uniform float uDpr;       // 16
uniform sampler2D uBg;
uniform sampler2D uPage;

out vec4 fragColor;

vec3 scene(vec2 p) {
  vec2 uv = clamp((uOrigin + p) / uCapSize, vec2(0.0), vec2(1.0));
  vec3 bg = texture(uBg, uv).rgb;
  vec4 pg = texture(uPage, uv);   // premultiplied
  return pg.rgb + bg * (1.0 - pg.a);
}

float sdf(vec2 p) {
  vec2 h = uSize * 0.5;
  float r = min(uRadius, min(h.x, h.y));
  vec2 q = abs(p - h) - (h - r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float prof(float x) { return pow(max(0.0, 1.0 - pow(1.0 - x, 4.0)), 0.25); }

float snell(float x) {
  float e = 0.002;
  float slope = (prof(min(1.0, x + e)) - prof(max(0.0, x - e))) / (2.0 * e);
  float t1 = atan(slope);
  float t2 = asin(sin(t1) / 1.5);
  return (0.8 + prof(x)) * tan(t1 - t2) / uNorm;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float d = sdf(p);
  float alpha = clamp(0.5 - d * uDpr, 0.0, 1.0);
  if (alpha <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  float t = -d;
  float x = clamp(t / uBezel, 0.0, 1.0);
  vec2 q = p;
  if (t < uBezel) {
    vec2 n = normalize(vec2(sdf(p + vec2(0.5, 0.0)) - sdf(p - vec2(0.5, 0.0)),
                            sdf(p + vec2(0.0, 0.5)) - sdf(p - vec2(0.0, 0.5))) + 1e-6);
    q = p - n * snell(max(0.002, x)) * uStrength;
  }
  vec3 col = scene(q);
  // Rozmazání: u hrany slabší (lom zůstane ostrý), ve středu plné.
  float frost = 0.25 + 0.75 * smoothstep(0.0, 1.0, x);
  if (uBlur > 0.5) {
    vec3 s = vec3(0.0);
    for (int i = 0; i < 12; i++) {
      float a = float(i) * 0.5236;
      float rr = uBlur * (0.45 + 0.55 * mod(float(i), 2.0));
      s += scene(q + vec2(cos(a), sin(a)) * rr);
    }
    col = mix(col, s / 12.0, frost);
  }
  // Vibrance (sytost kolem jasu) jako CSS saturate().
  float lum = dot(col, vec3(0.213, 0.715, 0.072));
  col = mix(vec3(lum), col, uSat);
  col = mix(col, uFill.rgb, uFill.a);
  // Lem 1.2 px: zjasněný obsah pod hranou (v jeho barvě, ne bílá).
  if (t < 1.2) col = col * 1.35 + 0.15;
  col = clamp(col, 0.0, 1.0);
  fragColor = vec4(col * alpha, alpha);
}
