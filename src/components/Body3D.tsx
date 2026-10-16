// Interactive 2.5D relief of the profile photo: the cut-out is draped over an estimated depth map
// (made locally by server/photo/cutout.swift) and lit from its own surface normals.
import { useEffect, useRef, useState } from 'react';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import type { PhotoMeta } from '../../shared/types.ts';

const VERTEX = /* glsl */ `
  uniform sampler2D depthMap;
  uniform float depthScale;
  uniform vec2 texel;
  uniform vec2 planeSize;
  varying vec2 vUv;
  varying vec3 vNormal;
  varying vec3 vView;
  void main() {
    vUv = uv;
    float d = texture2D(depthMap, uv).r;
    float dx = texture2D(depthMap, uv + vec2(texel.x, 0.0)).r - texture2D(depthMap, uv - vec2(texel.x, 0.0)).r;
    float dy = texture2D(depthMap, uv + vec2(0.0, texel.y)).r - texture2D(depthMap, uv - vec2(0.0, texel.y)).r;
    vec3 n = normalize(vec3(
      -dx * depthScale / (2.0 * texel.x * planeSize.x),
      -dy * depthScale / (2.0 * texel.y * planeSize.y),
      1.0));
    vNormal = normalize(normalMatrix * n);
    vec4 mv = modelViewMatrix * vec4(position + vec3(0.0, 0.0, d * depthScale), 1.0);
    vView = normalize(-mv.xyz);
    gl_Position = projectionMatrix * mv;
  }
`;

const FRAGMENT = /* glsl */ `
  uniform sampler2D map;
  uniform vec3 keyLight;
  varying vec2 vUv;
  varying vec3 vNormal;
  varying vec3 vView;
  void main() {
    vec4 c = texture2D(map, vUv);
    // Same soft fade as the dashboard: the figure dissolves toward the bottom.
    float a = c.a * smoothstep(0.02, 0.42, vUv.y);
    if (a < 0.02) discard;
    vec3 n = normalize(vNormal);
    // The photo already carries its studio lighting, so shading stays subtle: a soft key light for shape
    // and only a trace of rim light (weighted by alpha, so the silhouette edge doesn't glow).
    float key = max(dot(n, normalize(keyLight)), 0.0);
    float rim = pow(1.0 - max(dot(n, normalize(vView)), 0.0), 3.0);
    vec3 col = c.rgb * (0.88 + 0.16 * key) + vec3(0.05) * rim * a;
    gl_FragColor = vec4(col, a);
    #include <colorspace_fragment>
  }
`;

export default function Body3D({ photo, onClose }: { photo: PhotoMeta; onClose: () => void }) {
  const mount = useRef<HTMLDivElement>(null);
  const closeBtn = useRef<HTMLButtonElement>(null);
  const reset = useRef<() => void>(() => {});
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    closeBtn.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  useEffect(() => {
    const el = mount.current!;
    let renderer: THREE.WebGLRenderer;
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    } catch {
      setError('3D needs WebGL, which this browser has turned off.');
      return;
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    el.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(28, 1, 0.1, 100);
    const home = new THREE.Vector3(0, 0.12, 4.6);
    camera.position.copy(home);

    const aspect = photo.width / photo.height;
    const planeH = 2.2;
    const planeW = planeH * aspect;
    const segs = 320;
    const geometry = new THREE.PlaneGeometry(planeW, planeH, Math.round(segs * Math.min(1, aspect)), Math.round(segs / Math.max(1, aspect)));

    const loader = new THREE.TextureLoader();
    const v = `?v=${photo.version}`;
    const map = loader.load(`/api/profile/cutout.png${v}`, () => setReady(true), undefined, () => setError("Couldn't load your photo."));
    map.colorSpace = THREE.SRGBColorSpace;
    map.anisotropy = renderer.capabilities.getMaxAnisotropy();
    const depthMap = loader.load(`/api/profile/depth.png${v}`, (t) => {
      const img = t.image as HTMLImageElement;
      material.uniforms.texel.value.set(1 / img.width, 1 / img.height);
    });

    const material = new THREE.ShaderMaterial({
      uniforms: {
        map: { value: map },
        depthMap: { value: depthMap },
        depthScale: { value: planeW * 0.34 },
        texel: { value: new THREE.Vector2(1 / 384, 1 / 512) },
        planeSize: { value: new THREE.Vector2(planeW, planeH) },
        keyLight: { value: new THREE.Vector3(-0.5, 0.6, 1) },
      },
      vertexShader: VERTEX,
      fragmentShader: FRAGMENT,
      transparent: true,
    });
    const mesh = new THREE.Mesh(geometry, material);
    const group = new THREE.Group();
    group.add(mesh);
    group.position.y = 0.05;
    scene.add(group);

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.enablePan = false;
    controls.minDistance = 2.8;
    controls.maxDistance = 7;
    // A single photo only describes the front, so keep the view in front of it.
    controls.minAzimuthAngle = -0.62;
    controls.maxAzimuthAngle = 0.62;
    controls.minPolarAngle = Math.PI / 2 - 0.4;
    controls.maxPolarAngle = Math.PI / 2 + 0.3;
    controls.target.set(0, 0.12, 0);
    controls.update();

    let lastInput = performance.now();
    const touched = () => (lastInput = performance.now());
    controls.addEventListener('start', touched);
    controls.addEventListener('change', touched);
    reset.current = () => {
      camera.position.copy(home);
      controls.target.set(0, 0.12, 0);
      controls.update();
    };

    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const resize = () => {
      const { width, height } = el.getBoundingClientRect();
      renderer.setSize(width, height);
      camera.aspect = width / Math.max(height, 1);
      camera.updateProjectionMatrix();
    };
    const ro = new ResizeObserver(resize);
    ro.observe(el);
    resize();

    let frame = 0;
    const clock = new THREE.Clock();
    const tick = () => {
      const t = clock.getElapsedTime();
      // Gentle idle sway so the depth reads even before anyone drags.
      const idle = performance.now() - lastInput > 2500 && !reduceMotion;
      const target = idle ? Math.sin(t * 0.5) * 0.28 : 0;
      group.rotation.y += (target - group.rotation.y) * 0.04;
      controls.update();
      renderer.render(scene, camera);
      frame = requestAnimationFrame(tick);
    };
    tick();

    return () => {
      cancelAnimationFrame(frame);
      ro.disconnect();
      controls.dispose();
      geometry.dispose();
      material.dispose();
      map.dispose();
      depthMap.dispose();
      renderer.dispose();
      el.removeChild(renderer.domElement);
    };
  }, [photo]);

  return (
    <div className="viewer" role="dialog" aria-modal="true" aria-label="3D view of your photo">
      <div className="viewer-stage" ref={mount} />
      {!ready && !error && <div className="viewer-note">Building your 3D view…</div>}
      {error && <div className="viewer-note">{error}</div>}
      <div className="viewer-bar">
        <span className="muted small">Drag to turn · scroll to zoom</span>
        <button className="btn" onClick={() => reset.current()}>
          Reset view
        </button>
        <button className="btn btn-primary" ref={closeBtn} onClick={onClose}>
          Close
        </button>
      </div>
      <p className="viewer-foot muted small">
        Depth is estimated from a single photo on this Mac, so the view stays in front of you.
      </p>
    </div>
  );
}
