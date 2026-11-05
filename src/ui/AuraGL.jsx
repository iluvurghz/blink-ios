import { useEffect, useRef } from 'react';
import { store } from '../lib/store.js';

// «Вспышка»: a living light behind the cover. Three big soft glows in the cover's colours drift
// slowly over a dark ground, a warm core breathes behind the cover like a slow flash, the bottom
// falls to black where the controls sit. No noise loops: a handful of exp() per pixel, smooth on
// weak phones, and the tone curve rolls highlights off instead of clipping them. Drawn at a third
// of the screen resolution, 30 frames a second while playing and 20 when not, only while on screen,
// the window is visible and the full-screen player is closed; with reduced motion, in game mode or
// on a low battery it draws one still frame. The palette eases over when the track changes (read
// after a track change and every couple of seconds, never per frame).
// Returns false through onFail when WebGL is missing, so the caller can keep the plain background.
const VARS = ['--gA', '--gB', '--gC', '--accent'];

const VERT = 'attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}';
const FRAG = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 res;
uniform float t;
uniform float energy;
uniform vec3 c0;
uniform vec3 c1;
uniform vec3 c2;
uniform vec3 c3;
float ign(vec2 p){return fract(52.9829189*fract(dot(p,vec2(.06711056,.00583715))));}
void main(){
  vec2 uv=gl_FragCoord.xy/res;
  float asp=res.x/res.y;
  vec2 k=vec2(clamp(asp,1.,1.7),1.);
  float s=t*.16;
  vec2 pa=vec2(.22+.12*sin(s*.9),.78+.08*cos(s*.7));
  vec2 pb=vec2(.80+.10*cos(s*.8+1.),.46+.12*sin(s*.6));
  vec2 pc=vec2(.46+.14*sin(s*.5+2.),.16+.08*cos(s*.9+2.));
  vec2 da=(uv-pa)*k;
  vec2 db=(uv-pb)*k;
  vec2 dc=(uv-pc)*k;
  vec3 col=mix(c0,c1,uv.y)*.07;
  col+=c0*exp(-6.*dot(da,da))*.62;
  col+=c1*exp(-6.5*dot(db,db))*.50;
  col+=c2*exp(-7.*dot(dc,dc))*.42;
  // the flash: a warm core behind the cover that swells and settles
  float beat=pow(.5+.5*sin(t*.9),3.);
  vec2 dk=(uv-vec2(.5,.60))*k;
  float core=exp(-7.*dot(dk,dk));
  col+=mix(c3,vec3(1.),.08)*core*(.30+.18*energy+.18*beat*energy);
  col+=c3*exp(-3.*dot(dk,dk))*.10;
  // dark where the controls sit, and at the edges
  col*=.30+.70*smoothstep(.0,.6,uv.y);
  col*=1.-.55*smoothstep(.45,1.1,length((uv-.5)*vec2(k.x*.9,1.1)));
  col=1.-exp(-col*1.3);
  col+=(ign(gl_FragCoord.xy)-.5)/200.;
  gl_FragColor=vec4(max(col,0.),1.);
}`;

function parse(ctx, css) {
  ctx.fillStyle = '#000';
  ctx.fillStyle = css || '#c06030';
  ctx.fillRect(0, 0, 1, 1);
  const d = ctx.getImageData(0, 0, 1, 1).data;
  return [d[0] / 255, d[1] / 255, d[2] / 255];
}

// One canvas and one compiled program for the whole app: moving between pages re-attaches it
// instead of compiling the shader again (that was a half-second stall on phones).
let shared;
function setup() {
  if (shared !== undefined) return shared;
  shared = null;
  const canvas = document.createElement('canvas');
  canvas.setAttribute('aria-hidden', 'true');
  canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block';
  const gl = canvas.getContext('webgl', { antialias: false, premultipliedAlpha: false, preserveDrawingBuffer: true });
  if (!gl) return null;
  const sh = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
  };
  const vs = sh(gl.VERTEX_SHADER, VERT);
  const fs = sh(gl.FRAGMENT_SHADER, FRAG);
  if (!vs || !fs) return null;
  const prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'p');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const u = (k) => gl.getUniformLocation(prog, k);
  shared = { canvas, gl, uRes: u('res'), uT: u('t'), uE: u('energy'), uC: [u('c0'), u('c1'), u('c2'), u('c3')], t: Math.random() * 50, cur: null };
  return shared;
}

export default function AuraGL({ active = false, className = 'aura-gl', onFail, scale = 0.35 }) {
  const ref = useRef(null);
  const activeRef = useRef(active);
  activeRef.current = active;

  useEffect(() => {
    const host = ref.current;
    const sh = setup();
    if (!sh) return onFail && onFail();
    const { canvas, gl, uRes, uT, uE, uC } = sh;
    host.appendChild(canvas);

    const probe = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
    const still = window.matchMedia('(prefers-reduced-motion: reduce)');
    let lowBattery = false;
    if (navigator.getBattery)
      navigator
        .getBattery()
        .then((b) => {
          const check = () => {
            lowBattery = !b.charging && b.level < 0.2;
            start();
          };
          b.addEventListener('levelchange', check);
          b.addEventListener('chargingchange', check);
          check();
        })
        .catch(() => {});
    const isStill = () => still.matches || lowBattery || document.documentElement.dataset.game === 'on';
    // After the full-screen player closes the light stays off until its exit animation is over,
    // otherwise the WebGL redraw competes with it and the close stutters.
    let resumeAt = 0;
    let wasStage = !!store.get().stage;
    const hidden = () => !visible || document.hidden || store.get().stage || performance.now() < resumeAt;
    let target = [];
    // The palette and the time carry over between pages, so the light doesn't jump.
    let cur = sh.cur;
    let energy = activeRef.current ? 1 : 0.4;
    let t = sh.t;
    let raf = 0;
    let last = 0;
    let visible = true;

    const readColors = () => {
      const css = getComputedStyle(document.documentElement);
      target = VARS.map((v) => parse(probe, css.getPropertyValue(v).trim()));
      if (!cur) cur = sh.cur = target.map((c) => c.slice());
    };
    const resize = () => {
      const r = host.getBoundingClientRect();
      canvas.width = Math.max(1, Math.round(r.width * scale));
      canvas.height = Math.max(1, Math.round(r.height * scale));
      gl.viewport(0, 0, canvas.width, canvas.height);
    };
    const draw = () => {
      gl.uniform2f(uRes, canvas.width, canvas.height);
      gl.uniform1f(uT, t);
      gl.uniform1f(uE, energy);
      cur.forEach((c, k) => gl.uniform3f(uC[k], c[0], c[1], c[2]));
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };
    const frame = (now) => {
      raf = 0;
      if (hidden() || isStill()) return;
      raf = requestAnimationFrame(frame);
      if (now - last < (activeRef.current ? 33 : 50)) return;
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      energy += ((activeRef.current ? 1 : 0.4) - energy) * Math.min(1, dt * 1.2);
      t += dt * (0.3 + 0.5 * energy);
      // ~1.5 s to settle on a new palette
      const k = Math.min(1, dt * 2.2);
      cur.forEach((c, i) => c.forEach((x, j) => (c[j] = x + (target[i][j] - x) * k)));
      draw();
    };
    const start = () => {
      if (isStill()) return draw();
      if (!raf && !hidden()) raf = requestAnimationFrame(frame);
    };

    readColors();
    resize();
    draw();
    start();
    // The palette eases in on the root after a track change: read it a few times then, and
    // otherwise only every couple of seconds (not every frame).
    let lastId = store.get().track && store.get().track.id;
    let reads = [];
    const unsub = store.subscribe(() => {
      const st = !!store.get().stage;
      if (wasStage && !st) {
        resumeAt = performance.now() + 600;
        setTimeout(start, 620);
      }
      wasStage = st;
      const tr = store.get().track;
      const id = tr && tr.id;
      if (id !== lastId) {
        lastId = id;
        reads.forEach(clearTimeout);
        reads = [300, 900, 1600, 2600].map((ms) => setTimeout(readColors, ms));
      }
      start();
    });
    const colorTimer = setInterval(readColors, 2000);
    const ro = new ResizeObserver(() => {
      resize();
      draw();
    });
    ro.observe(host);
    const io = new IntersectionObserver(([e]) => {
      visible = e.isIntersecting;
      start();
    });
    io.observe(host);
    document.addEventListener('visibilitychange', start);
    still.addEventListener('change', start);
    window.addEventListener('blink-game', start);
    return () => {
      cancelAnimationFrame(raf);
      clearInterval(colorTimer);
      reads.forEach(clearTimeout);
      unsub();
      ro.disconnect();
      io.disconnect();
      document.removeEventListener('visibilitychange', start);
      still.removeEventListener('change', start);
      window.removeEventListener('blink-game', start);
      sh.t = t;
      if (canvas.parentNode === host) host.removeChild(canvas);
    };
  }, []);

  return <div ref={ref} className={className} aria-hidden="true" />;
}
