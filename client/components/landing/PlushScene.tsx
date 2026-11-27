"use client";

import { useEffect, useRef } from "react";
import * as THREE from "three";
import { mergeGeometries } from "three/examples/jsm/utils/BufferGeometryUtils.js";

// The whole home page sits on one plush landscape: a felt aqueduct and gate in
// the hero, cloud banks and coral bushes down the sides, an arch between the
// two halves of the page, and "talkflow" made of plush at the very bottom.
//
// It is a fixed WebGL canvas behind the page. Scrolling moves the camera down
// through the scene; elements with data-scene-y pin a world height to a point
// in the page, so the arch lines up with the gap it fills. The fuzz is shell
// texturing: each mesh is drawn SHELLS times, pushed out along its normals, and
// a per-strand hash discards everything that is not a hair at that height.

const SHELLS = 15;
const SPAN = 64; // world units from the hero to the footer
const SKY_FOG = new THREE.Color("#2f63de");

type Fur = { base: string; shadow: string; tip: string; len: number; density: number; shells?: number };
const CLOUD: Fur = { base: "#ffffff", shadow: "#a99ee8", tip: "#ffffff", len: 0.13, density: 44 };
const STONE: Fur = { base: "#fdfcff", shadow: "#a59de6", tip: "#ffffff", len: 0.08, density: 52 };
const CORAL: Fur = { base: "#f9654f", shadow: "#c7382f", tip: "#ffa58f", len: 0.19, density: 36 };
const LETTER: Fur = { base: "#ffffff", shadow: "#b9b0f0", tip: "#ffffff", len: 0.08, density: 56, shells: 12 };

const VERT = /* glsl */ `
  attribute float shell;
  uniform float furLen;
  varying vec3 vN;
  varying vec3 vBase;
  varying vec3 vWorld;
  varying float vH;
  void main() {
    vec3 n = normalize(normal);
    vec3 p = position + n * furLen * shell;
    p.y -= furLen * shell * shell * 0.3; // the tips droop a little
    vec4 w = modelMatrix * vec4(p, 1.0);
    vWorld = w.xyz;
    vBase = (modelMatrix * vec4(position, 1.0)).xyz;
    vH = shell;
    vN = normalize(mat3(modelMatrix) * n);
    gl_Position = projectionMatrix * viewMatrix * w;
  }
`;

const FRAG = /* glsl */ `
  uniform vec3 baseColor;
  uniform vec3 shadowColor;
  uniform vec3 tipColor;
  uniform vec3 fogColor;
  uniform float density;
  uniform vec3 lightDir;
  varying vec3 vN;
  varying vec3 vBase;
  varying vec3 vWorld;
  varying float vH;

  float hash(vec3 p) {
    p = fract(p * 0.3183099 + vec3(0.11, 0.17, 0.13));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
  }

  void main() {
    // A rotated, jittered strand grid, so no lattice shows on curved surfaces.
    vec3 q = mat3(0.80, 0.36, -0.48, -0.60, 0.48, -0.64, 0.0, 0.80, 0.60) * (vBase * density);
    vec3 cell = floor(q);
    vec3 jit = vec3(hash(cell), hash(cell + 17.3), hash(cell + 41.7)) - 0.5;
    vec3 f = fract(q) - 0.5 - jit * 0.55;
    float strand = mix(0.4, 1.0, hash(cell + 7.1));
    if (vH > 0.0) {
      if (vH > strand) discard;
      float radius = 0.55 * (1.0 - vH / strand);
      if (length(f) > radius) discard;
    }
    vec3 n = normalize(vN);
    float wrap = clamp((dot(n, lightDir) + 0.8) / 1.8, 0.0, 1.0);
    float ao = mix(0.74, 1.0, pow(vH, 0.6));
    vec3 col = mix(shadowColor, baseColor, wrap);
    col = mix(col, baseColor, 0.22) * ao; // soft bounce light from the clouds
    col = mix(col, tipColor, smoothstep(0.45, 1.0, vH) * 0.55 * wrap);
    vec3 V = normalize(cameraPosition - vWorld);
    float rim = pow(1.0 - max(dot(n, V), 0.0), 3.0);
    col += tipColor * rim * 0.18;
    float d = distance(cameraPosition, vWorld);
    col = mix(col, fogColor, smoothstep(26.0, 60.0, d) * 0.75);
    gl_FragColor = vec4(col, 1.0);
    #include <colorspace_fragment>
  }
`;

const LIGHT = new THREE.Vector3(-0.35, 0.62, 0.72).normalize();

function furMesh(geometry: THREE.BufferGeometry, fur: Fur) {
  const shells = fur.shells ?? SHELLS;
  const g = new THREE.InstancedBufferGeometry();
  g.index = geometry.index;
  g.setAttribute("position", geometry.getAttribute("position"));
  g.setAttribute("normal", geometry.getAttribute("normal"));
  const s = new Float32Array(shells);
  for (let i = 0; i < shells; i++) s[i] = i / (shells - 1);
  g.setAttribute("shell", new THREE.InstancedBufferAttribute(s, 1));
  g.instanceCount = shells;
  geometry.computeBoundingSphere();
  g.boundingSphere = geometry.boundingSphere!.clone();
  g.boundingSphere.radius += fur.len * 1.5;

  const material = new THREE.ShaderMaterial({
    vertexShader: VERT,
    fragmentShader: FRAG,
    uniforms: {
      furLen: { value: fur.len },
      density: { value: fur.density },
      baseColor: { value: new THREE.Color(fur.base) },
      shadowColor: { value: new THREE.Color(fur.shadow) },
      tipColor: { value: new THREE.Color(fur.tip) },
      fogColor: { value: SKY_FOG },
      lightDir: { value: LIGHT },
    },
  });
  return new THREE.Mesh(g, material);
}

// A deterministic random source, so the scene is the same on every visit.
function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// A heap of overlapping balls. flat > 0 squashes it into a cloud bank.
function puffs(rand: () => number, cx: number, cy: number, cz: number, w: number, h: number, count: number, r: number, flat = 0.3, detail = 2) {
  const parts: THREE.BufferGeometry[] = [];
  for (let i = 0; i < count; i++) {
    const u = rand() * 2 - 1;
    const x = cx + u * w;
    // Taller in the middle, so a heap has a crown.
    const crown = 1 - Math.abs(u) * 0.6;
    const y = cy + rand() * h * crown;
    const z = cz + (rand() * 2 - 1) * w * 0.25;
    const rr = r * (0.55 + rand() * 0.7) * (0.7 + crown * 0.5);
    const s = new THREE.IcosahedronGeometry(rr, detail);
    s.scale(1, 1 - flat * 0.4, 1);
    s.translate(x, y, z);
    s.deleteAttribute("uv");
    parts.push(s);
  }
  return mergeGeometries(parts)!;
}

// The aqueduct's side: a slab with round arches cut up from the bottom.
function aqueductGeometry(length: number, height: number, arches: number, pierRatio = 3.2, riseRatio = 0.5) {
  const pier = length / (arches * pierRatio);
  const span = (length - pier * (arches + 1)) / arches;
  const rise = height * riseRatio;
  const shape = new THREE.Shape();
  shape.moveTo(0, 0);
  shape.lineTo(0, height);
  shape.lineTo(length, height);
  shape.lineTo(length, 0);
  // Walk the bottom edge right to left, going up and over each arch.
  for (let i = arches - 1; i >= 0; i--) {
    const left = pier + i * (span + pier);
    const right = left + span;
    const r = span / 2;
    shape.lineTo(right, 0);
    shape.lineTo(right, rise - r);
    shape.absarc(left + r, rise - r, r, 0, Math.PI, false);
    shape.lineTo(left, 0);
  }
  shape.lineTo(0, 0);
  const g = new THREE.ExtrudeGeometry(shape, {
    depth: 1.1,
    bevelEnabled: true,
    bevelThickness: 0.16,
    bevelSize: 0.16,
    bevelSegments: 4,
    curveSegments: 24,
  });
  g.translate(0, 0, -0.55);
  g.deleteAttribute("uv");
  // A ledge along the top.
  const deck = new THREE.BoxGeometry(length + 0.5, 0.35, 1.6, 40, 2, 6);
  deck.translate(length / 2, height + 0.12, 0);
  deck.deleteAttribute("uv");
  return mergeGeometries([g.toNonIndexed(), deck.toNonIndexed()])!;
}

function gateGeometry(height: number, width: number) {
  const parts: THREE.BufferGeometry[] = [];
  for (const x of [-width / 2, width / 2]) {
    const col = new THREE.CylinderGeometry(0.28, 0.32, height, 24, 6);
    col.translate(x, height / 2, 0);
    parts.push(col.toNonIndexed());
  }
  const lintel = new THREE.BoxGeometry(width + 1.1, 0.45, 0.9, 16, 2, 4);
  lintel.translate(0, height + 0.2, 0);
  parts.push(lintel.toNonIndexed());
  const step = new THREE.BoxGeometry(width + 1.6, 0.3, 1.6, 16, 2, 6);
  step.translate(0, -0.1, 0);
  parts.push(step.toNonIndexed());
  for (const p of parts) p.deleteAttribute("uv");
  return mergeGeometries(parts)!;
}

// "talkflow" built from plush balls: the word is drawn in the site's serif on
// a canvas, and a ball goes wherever the ink is.
async function letterGeometry(width: number) {
  const family = getComputedStyle(document.documentElement).getPropertyValue("--font-newsreader").trim() || "Georgia, serif";
  const font = `800 240px ${family}`;
  try {
    await document.fonts.load(font, "talkflow");
  } catch {}
  const c = document.createElement("canvas");
  c.width = 1200;
  c.height = 340;
  const ctx = c.getContext("2d", { willReadFrequently: true })!;
  ctx.font = font;
  ctx.textAlign = "center";
  ctx.textBaseline = "alphabetic";
  ctx.letterSpacing = "-6px";
  ctx.fillText("talkflow", c.width / 2, 250);
  const data = ctx.getImageData(0, 0, c.width, c.height).data;
  const m = ctx.measureText("talkflow");
  const step = 6; // px between balls
  const scale = width / Math.max(1, m.width);
  const rand = rng(7);
  const parts: THREE.BufferGeometry[] = [];
  for (let y = 0; y < c.height; y += step) {
    for (let x = 0; x < c.width; x += step) {
      if (data[(y * c.width + x) * 4 + 3] < 140) continue;
      const s = new THREE.IcosahedronGeometry(step * scale * (0.95 + rand() * 0.3), 1);
      s.translate((x - c.width / 2) * scale, (175 - y) * scale, (rand() - 0.5) * step * scale);
      s.deleteAttribute("uv");
      parts.push(s);
    }
  }
  return parts.length ? mergeGeometries(parts) : null;
}

export function PlushScene() {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    let renderer: THREE.WebGLRenderer;
    try {
      renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: "high-performance" });
    } catch {
      return; // No WebGL: the page keeps its plain sky gradient.
    }
    renderer.setClearColor(0x000000, 0);

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(35, 1, 0.5, 200);
    const rand = rng(42);
    const add = (g: THREE.BufferGeometry, fur: Fur) => {
      const mesh = furMesh(g, fur);
      scene.add(mesh);
      return mesh;
    };

    // Hero: the aqueduct rising to the right toward a gate on a cloud hill.
    const aqueduct = add(aqueductGeometry(20, 3.2, 4), STONE);
    // Rotated so the right end recedes; it ends at the gate hill.
    aqueduct.position.set(-11.4, -8.6, -4);
    aqueduct.rotation.set(0, 0.25, 0.075);
    add(gateGeometry(2.4, 1.6), STONE).position.set(8.8, -3.7, -9.4);
    add(puffs(rand, 9.2, -6.9, -9.2, 3.4, 3.0, 28, 1.25, 0.15), CLOUD);
    add(puffs(rand, -14, -7.6, -3, 3.2, 5, 34, 1.5, 0.1), CLOUD);
    add(puffs(rand, 0, -11.2, -6, 17, 2.4, 76, 1.3, 0.45), CLOUD);
    add(puffs(rand, -9.8, -9.4, 3.5, 3.6, 2.4, 16, 1.35, 0), CORAL);
    add(puffs(rand, 10.2, -9.2, 3.5, 3.4, 2.6, 16, 1.35, 0), CORAL);

    // Down the page: cloud banks and the odd coral bush at the edges.
    for (let y = -16; y > -SPAN + 6; y -= 4.6) {
      const side = (y / 4.6) % 2 === 0 ? 1 : -1;
      for (const s of [side, -side]) {
        const x = s * (11.5 + rand() * 3);
        const z = -4 - rand() * 6;
        if (rand() < 0.28) add(puffs(rand, x, y + rand() * 2, z + 3, 1.6, 1.4, 8, 0.95, 0, 2), CORAL);
        else add(puffs(rand, x, y + rand() * 2, z, 2.6 + rand() * 2, 1.6, 16, 1.2, 0.35), CLOUD);
      }
    }

    // The arch between the two halves of the page, standing in a cloud bank.
    const archY = -30;
    const arch = add(aqueductGeometry(6, 5.4, 1, 6, 0.86), STONE);
    arch.position.set(-3, archY - 3.2, -6);
    add(puffs(rand, 0, archY - 3.6, -5, 17, 1.6, 64, 1.25, 0.5), CLOUD);
    add(puffs(rand, -7.5, archY - 3.2, -1.5, 2.2, 1.5, 9, 1.05, 0), CORAL);
    add(puffs(rand, 7.8, archY - 3.0, -1.5, 2.2, 1.6, 9, 1.05, 0), CORAL);

    // Footer: the plush word on a bed of clouds, coral at the sides.
    const end = -SPAN;
    add(puffs(rand, 0, end - 6.8, -3, 18, 2.4, 80, 1.35, 0.5), CLOUD);
    add(puffs(rand, -10.5, end - 6.4, 2, 3, 2.4, 14, 1.3, 0), CORAL);
    add(puffs(rand, 10.5, end - 6.2, 2, 3, 2.6, 14, 1.3, 0), CORAL);

    let letters: THREE.Mesh | null = null;
    let disposed = false;

    // Scroll anchors: [page scroll position, camera height].
    let anchors: [number, number][] = [[0, 0]];
    function measure() {
      const max = Math.max(1, document.documentElement.scrollHeight - innerHeight);
      const list: [number, number][] = [[0, 0]];
      document.querySelectorAll<HTMLElement>("[data-scene-y]").forEach((el) => {
        const r = el.getBoundingClientRect();
        const at = r.top + scrollY + r.height / 2 - innerHeight / 2;
        list.push([Math.min(max, Math.max(0, at)), Number(el.dataset.sceneY)]);
      });
      list.push([max, -SPAN]);
      anchors = list.sort((a, b) => a[0] - b[0]);
    }
    function cameraY(s: number) {
      for (let i = 1; i < anchors.length; i++) {
        const [s0, y0] = anchors[i - 1];
        const [s1, y1] = anchors[i];
        if (s <= s1) return s1 === s0 ? y1 : y0 + ((s - s0) / (s1 - s0)) * (y1 - y0);
      }
      return anchors[anchors.length - 1][1];
    }

    const pointer = { x: 0, y: 0, cx: 0, cy: 0 };
    let raf = 0;
    let baseZ = 24;

    function resize() {
      const w = innerWidth;
      const h = innerHeight;
      renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 1.35));
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
      // Keep at least 26 units of width in view, so phones see the whole scene.
      const tan = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
      baseZ = Math.max(24, 26 / (2 * tan * camera.aspect));
      camera.updateProjectionMatrix();
      measure();
      kick();
    }

    function frame() {
      raf = 0;
      if (disposed) return;
      pointer.cx += (pointer.x - pointer.cx) * 0.06;
      pointer.cy += (pointer.y - pointer.cy) * 0.06;
      const y = cameraY(scrollY);
      camera.position.set(pointer.cx * 0.9, y - pointer.cy * 0.5, baseZ);
      camera.lookAt(0, y, 0);
      renderer.render(scene, camera);
      if (Math.abs(pointer.x - pointer.cx) + Math.abs(pointer.y - pointer.cy) > 0.002) kick();
    }
    function kick() {
      if (!raf && !disposed) raf = requestAnimationFrame(frame);
    }

    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const onPointer = (e: PointerEvent) => {
      if (reduced) return;
      pointer.x = (e.clientX / innerWidth) * 2 - 1;
      pointer.y = (e.clientY / innerHeight) * 2 - 1;
      kick();
    };

    letterGeometry(15).then((g) => {
      if (disposed || !g) return;
      letters = add(g, LETTER);
      letters.position.set(0, end - 1.6, 1.5);
      kick();
    });

    const ro = new ResizeObserver(() => {
      measure();
      kick();
    });
    ro.observe(document.body);
    addEventListener("resize", resize);
    addEventListener("scroll", kick, { passive: true });
    addEventListener("pointermove", onPointer, { passive: true });
    resize();
    canvas.dataset.ready = "1";

    return () => {
      disposed = true;
      cancelAnimationFrame(raf);
      ro.disconnect();
      removeEventListener("resize", resize);
      removeEventListener("scroll", kick);
      removeEventListener("pointermove", onPointer);
      scene.traverse((o) => {
        if (o instanceof THREE.Mesh) {
          o.geometry.dispose();
          (o.material as THREE.Material).dispose();
        }
      });
      renderer.dispose();
    };
  }, []);

  return (
    <canvas
      ref={ref}
      aria-hidden="true"
      className="pointer-events-none fixed inset-0 -z-10 block h-svh w-full opacity-0 transition-opacity duration-700 data-[ready]:opacity-100"
    />
  );
}
