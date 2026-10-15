#version 460 core

// Die Sprach-Kugel als Flüssigkeit: ineinander verwirbelte Farben, Lichtadern wie Sonnenlicht
// am Grund eines Pools, Wellen beim Sprechen, ein Strudel beim Nachdenken, Glas-Rand und
// Glanzlicht. Läuft auf der Grafikkarte, siehe voice_orb.dart (ShaderOrbPainter).

#include <flutter/runtime_effect.glsl>

uniform vec2 uCenter; // Mitte in Pixeln
uniform float uUnit;  // halbe Breite des Kugel-Widgets in Pixeln
uniform float uTime;  // Sekunden
uniform float uLevel; // Stimme 0..1, geglättet
uniform float uThink; // 0..1
uniform float uScale; // Aufgehen beim Öffnen
uniform float uSpin;  // fortlaufende Drehung

out vec4 fragColor;

const vec3 AMBER = vec3(1.0, 0.702, 0.251);
const vec3 CORAL = vec3(1.0, 0.416, 0.361);
const vec3 VIOLET = vec3(0.608, 0.420, 1.0);
const vec3 CYAN = vec3(0.247, 0.816, 1.0);
const vec3 DEEP = vec3(0.075, 0.05, 0.15);

// Zufall ohne sin(), damit es auch mit großen Werten auf Mobil-GPUs ruhig bleibt.
float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = m * p;
    a *= 0.5;
  }
  return v;
}

mat2 rot(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat2(c, -s, s, c);
}

void main() {
  vec2 p = (FlutterFragCoord().xy - uCenter) / uUnit;
  float len = length(p);
  float ang = atan(p.y, p.x);
  float t = uTime;
  float lv = clamp(uLevel, 0.0, 1.2);

  // Umriss: mehrere langsame Wellen laufen um die Kugel, mit der Stimme stärker.
  float R = 0.6 * uScale * (1.0 + 0.16 * lv);
  float w = 0.008 + 0.045 * lv + 0.015 * uThink;
  float edge = R * (1.0 + w * (0.55 * sin(3.0 * ang + t * 1.9)
                             + 0.35 * sin(5.0 * ang - t * 2.7 + 1.3)
                             + 0.25 * sin(2.0 * ang + t * 1.1 + 2.0)
                             + 0.15 * sin(7.0 * ang + t * 3.6 + 0.4)));
  float aa = 1.5 / uUnit;
  float inside = 1.0 - smoothstep(edge - aa, edge + aa, len);

  vec3 col = vec3(0.0);
  if (inside > 0.0) {
    vec2 q = p / edge;
    float z = sqrt(max(1.0 - dot(q, q), 0.0));
    vec3 n = normalize(vec3(q, z + 0.001));

    // Blick in eine Wasserkugel: zum Rand hin gestaucht.
    vec2 uv = q * (0.75 + 0.6 * (1.0 - z));
    // Strudel beim Nachdenken, innen schneller als außen.
    uv = rot(uSpin * 0.35 + uThink * (1.0 - length(q)) * 2.6) * uv;
    // Wellenringe von der Mitte aus, solange jemand spricht.
    float rl = length(uv);
    uv += uv / (rl + 0.001) * sin(rl * 14.0 - t * 7.0) * 0.035 * lv * exp(-rl * 1.2);

    // Verwirbelte Strömung (Domain Warping).
    vec2 a1 = vec2(fbm(uv * 1.1 + vec2(0.0, t * 0.16)), fbm(uv * 1.1 + vec2(5.2, -t * 0.13)));
    vec2 a2 = vec2(fbm(uv * 1.3 + 2.0 * a1 + vec2(1.7, 9.2) + t * 0.11),
                   fbm(uv * 1.3 + 2.0 * a1 + vec2(8.3, 2.8) - t * 0.09));
    float f = fbm(uv * 1.6 + 2.4 * a2 + t * 0.05);

    float m1 = smoothstep(0.25, 0.75, a1.x);
    float m2 = smoothstep(0.30, 0.80, a2.y);
    vec3 liquid = mix(mix(VIOLET, CYAN, m1), mix(CORAL, AMBER, m1), m2);
    liquid = mix(liquid, AMBER, smoothstep(0.55, 0.9, f) * 0.5);

    float bright = 0.42 + 0.7 * f + 0.3 * lv;
    vec3 c = mix(DEEP, liquid, clamp(0.1 + 1.2 * f * (0.55 + 0.45 * z), 0.0, 1.0)) * bright;

    // Lichtadern wie am Grund eines Pools.
    float cl = abs(sin((f + a2.x) * 7.0 + t * 0.5));
    c += pow(1.0 - cl, 14.0) * (0.2 + 0.4 * lv) * (0.4 + 0.6 * z) * mix(vec3(1.0), AMBER, 0.3);

    // Nachdenken: ein Lichtschweif kreist innen am Rand.
    float arcAng = mod(ang - t * 3.2, 6.28318);
    float arc = smoothstep(0.0, 3.6, arcAng) * (1.0 - smoothstep(3.6, 3.9, arcAng));
    float bd = (length(q) - 0.8) * 12.0;
    c += uThink * arc * exp(-bd * bd) * 0.9 * vec3(1.0, 0.95, 0.9);

    // Glasrand (Fresnel) und Licht von oben links.
    float fres = pow(1.0 - z, 3.0);
    c += fres * mix(CYAN, VIOLET, 0.5 + 0.5 * sin(ang + t * 0.8)) * (0.5 + 0.4 * lv);
    vec3 L = normalize(vec3(-0.45, -0.6, 0.65));
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    c *= 0.78 + 0.22 * clamp(dot(n, L) * 1.2 + 0.4, 0.0, 1.0);
    c += vec3(pow(max(dot(n, H), 0.0), 60.0) * 0.85 + pow(max(dot(n, L), 0.0), 6.0) * 0.1);

    col = c * inside;
  }

  // Leuchten um die Kugel, läuft zum Rand des Bereichs weich aus.
  vec3 glowCol = mix(mix(AMBER, VIOLET, 0.5 + 0.5 * sin(t * 0.7)), mix(CYAN, CORAL, 0.5 + 0.5 * sin(t * 0.5)), 0.35);
  float d = max(len - edge, 0.0);
  float glow = exp(-d * (5.5 - 2.0 * lv)) * (0.28 + 0.45 * lv + 0.15 * uThink);
  glow *= (1.0 + 0.25 * lv * sin(d * 38.0 - t * 6.0)) * (1.0 - smoothstep(0.9, 1.45, len)) * (1.0 - inside);

  // Flutter erwartet vormultipliziertes Alpha.
  fragColor = vec4(col + glowCol * glow, clamp(inside + glow, 0.0, 1.0));
}
