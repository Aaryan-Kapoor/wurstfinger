// Wires the demo together: the phone, the composer, the ribbon above the
// keys, the coach, and the synthetic finger that demonstrates strokes.

import theory from '../theory.generated.js';
import { Engine } from '../engine.js';
import { defaultPacks } from '../packs.js';
import { makePlanner } from '../planner.js';
import { scriptFor } from '../script.js';
import { pathFor } from '../robot.js';
import { parseStroke } from '../layout.js';
import { Keyboard, GEO, MODES, MODE_LABEL, keyRect } from './keyboard.js';
import { Guide } from './guide.js';
import { glyph, letterStroke } from './glyph.js';
import { mountPanel } from './panel.js';

const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const wait = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------- settings

const saved = JSON.parse(localStorage.getItem('wf-steno-settings') || '{}');
export const settings = Object.assign({ guide: 'adaptive', theme: 'dark', words: true, trail: true }, saved);
export function saveSettings() {
  localStorage.setItem('wf-steno-settings', JSON.stringify(settings));
  document.documentElement.dataset.theme = settings.theme;
  $('keys').classList.toggle('words-hidden', !settings.words);
}

// ------------------------------------------------------------------ engine

const packs = defaultPacks(theory);
try {
  const mine = JSON.parse(localStorage.getItem('wf-steno-mine') || 'null');
  if (mine) packs.find(p => p.id === 'mine').entries = mine;
} catch { /* a corrupt store is an empty one */ }
export const engine = new Engine(theory, packs);
export let planner = makePlanner(engine.entries, theory);

export function packsChanged() {
  localStorage.setItem('wf-steno-mine', JSON.stringify(packs.find(p => p.id === 'mine').entries));
  engine.setPacks(packs);
  planner = makePlanner(engine.entries, theory);
  renderRibbon();
}

// ---------------------------------------------------------------- keyboard

const overlay = $('overlay');
const state = { context: 'messages', coach: null, spelled: 0, lastTyped: '', recording: null, playing: false };

const kb = new Keyboard($('keys'), engine, {
  onMode: () => { renderPager(); renderRibbon(); },
  onTouch: t => { if (!t.dry || true) guide.show(t); trailStart(t); $('field').classList.add('busy'); },
  onCandidate: t => guide.update(t),
  onRelease: (t, c, entry) => { guide.hide(t, c && !(entry && entry.kind === 'undefined') ? c : null); trailEnd(t); $('field').classList.remove('busy'); },
  onStroke: (c, entry) => noteStroke(c, entry),
  onAction: (action, amount) => act(action, amount),
  onGhost: (phase, p) => ghost(phase, p),
});
// Recording and dry demonstrations intercept the commit.
const realCommit = kb.commit.bind(kb);
kb.commit = (c, t) => {
  if (state.recording && c.id !== undefined) { const done = state.recording; state.recording = null; done(c.id); return null; }
  if (t && t.dry) return null;
  return realCommit(c, t);
};
const guide = new Guide(overlay, kb, engine, settings);

function act(action, amount) {
  switch (action) {
    case 'undo': engine.backspace(); state.spelled = Math.max(0, state.spelled - 1); break;
    case 'delete': for (let i = 0; i < amount; i++) engine.backspace(); break;
    case 'deleteWord': engine.deleteWord(); break;
    case 'caret': engine.moveCaret(amount); break;
    case 'return': submit(); break;
    case 'globe': toast('Next language'); break;
    case 'hide': toast('Hide keyboard'); break;
    default: break;
  }
}

function toast(text) {
  const t = document.createElement('div');
  t.className = 'toast'; t.textContent = text;
  kb.utilEl.appendChild(t);
  setTimeout(() => t.remove(), 1400);
}

// ------------------------------------------------------------------- coach

/** Watches how words get written and, when there was a shorter way, says so once. */
function noteStroke(c, entry) {
  if (!entry) return;
  if (entry.kind === 'letter' || (entry.kind === 'literal' && /^[a-z']$/i.test(entry.outline))) {
    state.spelled++;
    const p = engine.pendingOutline();
    state.lastTyped = p ? p.typed : (state.lastTyped + entry.outline);
    if (entry.kind === 'literal') state.lastTyped = (/[A-Za-z']+$/.exec(engine.state.text) || [''])[0];
    return;
  }
  if (state.spelled > 0 && kb.mode !== 'numeric') {
    const word = state.lastTyped.toLowerCase();
    state.coach = entry.expanded ? null : coachFor(word, state.spelled);
  } else if (entry.kind === 'word' || entry.kind === 'ending') {
    state.coach = null;
  }
  state.spelled = 0; state.lastTyped = '';
}

function coachFor(word, typedGestures) {
  if (!word || word.length < 2) return null;
  const plan = planner.plan(word);
  const strokes = planStrokes(plan);
  if (!strokes || strokes.gestures >= typedGestures) return null;
  return { word, plan, ...strokes };
}

/** A plan as what to show: glyph strokes and, for spelled parts, the letters. */
export function planStrokes(plan) {
  if (plan.kind === 'flick' || plan.kind === 'hook') return { parts: [{ stroke: plan.strokes[0] }], gestures: 1, why: plan.kind === 'flick' ? 'one flick' : 'flick and curl' };
  if (plan.kind === 'brief') return { parts: [{ letters: plan.outline }], gestures: plan.outline.length, why: `just ${plan.outline}` };
  if (plan.kind === 'ending') {
    const base = plan.base.strokes ? [{ stroke: plan.base.strokes[0] }] : [{ letters: plan.base.outline }];
    return { parts: [...base, { stroke: plan.strokes.at(-1) }], gestures: plan.gestures, why: `${plan.base.word} + ${theory.endings[plan.strokes.at(-1)]}` };
  }
  return null;
}

export const partsHtml = (parts, size = 24) => parts.map(p => p.stroke ? glyph(p.stroke, size) : `<span class="spell">${esc(p.letters)}</span>`).join('');

// ------------------------------------------------------------------ ribbon

function renderPager() {
  const pager = $('pager');
  if (!pager.children.length) {
    pager.innerHTML = '<div class="thumb"></div>' + MODES.map(m => `<button role="tab" data-mode="${m}">${MODE_LABEL[m]}</button>`).join('');
    pager.addEventListener('click', e => { const b = e.target.closest('button'); if (b) kb.setMode(b.dataset.mode); });
  }
  const i = MODES.indexOf(kb.mode);
  pager.querySelector('.thumb').style.transform = `translateX(${i * 48}px)`;
  for (const b of pager.querySelectorAll('button')) b.setAttribute('aria-pressed', b.dataset.mode === kb.mode);
}

let ribbonKey = '';
function renderRibbon() {
  const tape = $('tape');
  const chips = [];
  const pending = engine.pendingOutline();
  // Recent strokes, oldest first; letters collapse into the word being spelled.
  const recent = engine.tape.filter(e => ['word', 'ending', 'undefined'].includes(e.kind) || (e.kind === 'space' && e.expanded) || (e.kind === 'mark' && e.expanded)).slice(-3);
  const lastSeq = engine.tape.at(-1)?.seq;
  for (const e of recent) {
    const old = e.seq !== lastSeq || !!pending;
    if (e.kind === 'undefined') chips.push(`<span class="chip raw${old ? ' old' : ''}" data-seq="${e.seq}">${glyph(e.id, 22)}<span>no stroke here</span></span>`);
    else if (e.expanded) chips.push(`<span class="chip${old ? ' old' : ''}" data-seq="${e.seq}" style="padding-left:9px">${esc(e.out.trim())}</span>`);
    else chips.push(`<span class="chip${old ? ' old' : ''}" data-seq="${e.seq}">${e.id && parseStroke(e.id) ? glyph(e.id, 22) : ''}<span>${esc(e.kind === 'ending' ? e.label : e.out.trim() || e.label)}</span></span>`);
  }
  if (engine.lastEvent?.kind === 'undo' && engine.lastEvent.seq >= (lastSeq || 0)) {
    chips.push(`<span class="chip undo" data-seq="u${engine.lastEvent.seq}">${esc(engine.lastEvent.removed.trim() || engine.lastEvent.label)}</span>`);
  }
  if (pending) {
    const more = pending.expansion ? `<span class="arrow">→</span><span class="to">${esc(pending.expansion)}</span><kbd>space</kbd>` : '';
    chips.push(`<span class="chip spelling" data-seq="p">${esc(pending.typed)}${more}</span>`);
  } else if (state.coach) {
    const c = state.coach;
    chips.push(`<button class="chip coach" data-seq="c${c.word}" id="coachChip" title="Show me">${partsHtml(c.parts, 22)}<span>${esc(c.word)}</span><span class="why">${esc(c.why)}</span></button>`);
  }
  const key = chips.join('');
  if (key === ribbonKey) return;
  // Keep chips that have not changed so only new ones animate in.
  const before = new Set([...tape.children].map(n => n.dataset.seq));
  tape.innerHTML = key;
  for (const n of tape.children) if (before.has(n.dataset.seq)) n.style.animation = 'none';
  ribbonKey = key;
  $('coachChip')?.addEventListener('click', () => demonstrate(state.coach.parts));
}

// Dragging the ribbon sideways turns the keyboard's page.
{
  const ribbon = $('ribbon');
  let drag = null;
  ribbon.addEventListener('pointerdown', e => { if (e.target.closest('button')) return; drag = { x: e.clientX, t: performance.now(), moved: false }; ribbon.setPointerCapture(e.pointerId); });
  ribbon.addEventListener('pointermove', e => {
    if (!drag) return;
    const dx = (e.clientX - drag.x) / scale();
    if (Math.abs(dx) > 6) drag.moved = true;
    if (drag.moved) kb.dragStrip(dx);
  });
  const end = e => {
    if (!drag) return;
    const dx = (e.clientX - drag.x) / scale();
    if (drag.moved) kb.endDrag(dx, dx / Math.max(1, performance.now() - drag.t));
    drag = null;
  };
  ribbon.addEventListener('pointerup', end);
  ribbon.addEventListener('pointercancel', end);
}

// ---------------------------------------------------------------- composer

function renderField() {
  const f = $('field');
  const s = engine.state;
  const pending = engine.pendingOutline();
  const last = engine.lastEvent;
  let before = s.text;
  let html = '';
  if (!before && !s.after) {
    html = `<span><span class="caret"></span><span class="placeholder">${state.context === 'terminal' ? '' : 'iMessage'}</span></span>`;
  } else {
    let tail = '';
    if (pending && before.endsWith(pending.typed)) {
      const exp = pending.expansion;
      const ghostText = exp ? (exp.toLowerCase().startsWith(pending.typed.toLowerCase()) ? exp.slice(pending.typed.length) : '') : '';
      tail = `<span class="spelling">${esc(pending.typed)}</span>` + (ghostText ? `<span class="ghost">${esc(ghostText)}</span>` : '');
      before = before.slice(0, -pending.typed.length);
      html = esc(before) + tail.replace('</span><span class="ghost">', '</span><span class="caret"></span><span class="ghost">');
      if (!ghostText) html += '<span class="caret"></span>';
    } else {
      const landed = last && ['word', 'ending', 'space', 'mark'].includes(last.kind) && last.out && last.out.trim().length > 1 && before.endsWith(last.out) ? last.out : '';
      if (landed) {
        const lead = landed.match(/^\s*/)[0];
        html = esc(before.slice(0, -landed.length) + lead) + `<span class="landed">${esc(landed.slice(lead.length))}</span>`;
      } else html = esc(before);
      html += '<span class="caret"></span>';
    }
    html = `<span>${html}${esc(s.after)}</span>`;
  }
  f.innerHTML = html;
  $('send').disabled = !engine.text.trim();
}

const REPLIES = ['ok! what time?', 'sounds good to me', 'haha yes', 'are you bringing anyone?', 'see you there then', 'wait, which one?', "can't wait"];
let replyIndex = 0;

function addBubble(text, side) {
  const b = document.createElement('div');
  b.className = `bubble ${side}`;
  b.textContent = text;
  $('thread').appendChild(b);
  while ($('thread').children.length > 9) $('thread').firstChild.remove();
}

function submit() {
  const text = engine.text.trim();
  if (!text) return;
  if (state.context === 'terminal') {
    const term = $('terminal');
    const add = (cls, t) => { const l = document.createElement('div'); l.className = 'ln ' + cls; l.textContent = t; term.appendChild(l); };
    add('cmd', text);
    add('', fakeOutput(text));
    while (term.children.length > 14) term.firstChild.remove();
  } else {
    addBubble(text, 'out');
    if (!state.playing) setTimeout(() => addBubble(REPLIES[replyIndex++ % REPLIES.length], 'in'), 1100);
  }
  engine.reset('');
  state.coach = null; state.spelled = 0;
  renderRibbon();
}

function fakeOutput(cmd) {
  if (/^git status/.test(cmd)) return 'On branch engine\nnothing to commit, working tree clean';
  if (/^git commit/.test(cmd)) return '[engine 4c1d2e7] ' + (cmd.match(/"(.*)"/)?.[1] || 'update') + '\n 1 file changed, 3 insertions(+)';
  if (/^ls/.test(cmd)) return 'Package.swift  README.md  Sources  Tests  docs';
  if (/^git/.test(cmd)) return 'ok';
  return '';
}

$('send').addEventListener('click', submit);

export function setContext(context) {
  state.context = context;
  const terminal = context === 'terminal';
  $('ctxMessages').setAttribute('aria-pressed', !terminal);
  $('ctxTerminal').setAttribute('aria-pressed', terminal);
  $('thread').hidden = terminal; $('terminal').hidden = !terminal;
  $('who').textContent = terminal ? 'zsh' : 'Maya';
  $('whoSub').textContent = terminal ? 'wurstfinger · engine' : 'iMessage';
  $('field').classList.toggle('mono', terminal);
  // A field that asks for no capitals and no correction gets the shell pack.
  packs.find(p => p.id === 'shell').enabled = terminal;
  packs.find(p => p.id === 'texting').enabled = !terminal;
  engine.reset('');
  packsChanged();
  document.dispatchEvent(new CustomEvent('wf-context'));
}
$('ctxMessages').addEventListener('click', () => setContext('messages'));
$('ctxTerminal').addEventListener('click', () => setContext('terminal'));

// ------------------------------------------------------------------- trail

const trailCanvas = $('trail');
const trails = [];
let trailRaf = 0;
const TRAIL_PAD = 60;

function sizeTrail() {
  const dpr = Math.min(3, window.devicePixelRatio || 1) * Math.max(1, scale());
  const w = GEO.block + 2 * TRAIL_PAD, h = GEO.height + 2 * TRAIL_PAD;
  trailCanvas.width = w * dpr; trailCanvas.height = h * dpr;
  Object.assign(trailCanvas.style, { width: w + 'px', height: h + 'px', left: keysLeft() - TRAIL_PAD + 'px', top: keysTop() - TRAIL_PAD + 'px' });
  trailCanvas.getContext('2d').setTransform(dpr, 0, 0, dpr, TRAIL_PAD * dpr, TRAIL_PAD * dpr);
}
const keysLeft = () => $('keys').offsetLeft;
const keysTop = () => $('keys').offsetTop;

function trailStart(t) {
  if (!settings.trail) return;
  const tr = { t, released: 0 };
  trails.push(tr);
  if (!trailRaf) trailRaf = requestAnimationFrame(drawTrails);
}
function trailEnd(t) { const tr = trails.find(x => x.t === t); if (tr) tr.released = performance.now(); }

function drawTrails() {
  const ctx = trailCanvas.getContext('2d');
  ctx.clearRect(-TRAIL_PAD, -TRAIL_PAD, GEO.block + 2 * TRAIL_PAD, GEO.height + 2 * TRAIL_PAD);
  const now = performance.now();
  const ink = getComputedStyle(document.documentElement).getPropertyValue('--label').trim() || '#fff';
  for (let i = trails.length - 1; i >= 0; i--) {
    const tr = trails[i];
    const fade = tr.released ? 1 - (now - tr.released) / 350 : 1;
    if (fade <= 0) { trails.splice(i, 1); continue; }
    const pts = tr.t.path.map(p => ({ x: tr.t.origin.x + p.x, y: tr.t.origin.y + p.y }));
    if (pts.length < 2) continue;
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    const n = pts.length;
    for (let j = 1; j < n; j++) {
      const k = j / (n - 1);
      ctx.strokeStyle = ink;
      ctx.globalAlpha = 0.38 * fade * (0.3 + 0.7 * k);
      ctx.lineWidth = 2.5 + 7 * Math.pow(k, 0.55);
      ctx.beginPath(); ctx.moveTo(pts[j - 1].x, pts[j - 1].y); ctx.lineTo(pts[j].x, pts[j].y); ctx.stroke();
    }
  }
  ctx.globalAlpha = 1;
  trailRaf = trails.length ? requestAnimationFrame(drawTrails) : 0;
}

// ---------------------------------------------------------- synthetic finger

const finger = $('finger');
function ghost(phase, p) {
  if (phase === 'up') { finger.classList.remove('down'); return; }
  finger.style.left = keysLeft() + p.x + 'px';
  finger.style.top = keysTop() + p.y + 'px';
  if (phase === 'down') finger.classList.add('down');
}

/** Plays stroke ids with the synthetic finger. `dry` shows them without typing. */
export async function playStrokes(ids, { speed = 0.55, gap = 230, dry = false, hold = 260 } = {}) {
  if (state.playing) return;
  state.playing = true;
  document.body.classList.add('playing');
  try {
    for (const id of ids) {
      if (state.cancel) break;
      const s = parseStroke(id.replace(/-circle$/, ''));
      if (!s) continue;
      const rc = keyRect(s.key);
      const path = pathFor(id, rc.w, rc.h, 0);
      const moving = !!s.dir || id.endsWith('-circle');
      const p = kb.play(s.key, path, { speed: moving ? speed : 1, hold: moving ? hold : 70 });
      if (dry) for (const t of kb.touches.values()) if (t.ghost) t.dry = true;
      await p;
      await wait(moving ? gap : gap * 0.45);
    }
  } finally {
    state.playing = false; state.cancel = false;
    document.body.classList.remove('playing');
  }
}
export const stopPlaying = () => { if (state.playing) state.cancel = true; };

/** Shows how a plan is written, without typing anything. */
export function demonstrate(parts) {
  const ids = parts.flatMap(p => p.stroke ? [p.stroke] : [...p.letters].map(letterStroke).filter(Boolean));
  if (kb.mode !== 'steno') kb.setMode('steno');
  return playStrokes(ids, { dry: true, speed: 0.45, hold: 420 });
}

/** Types a sentence for real, at teaching speed. */
export async function typeSentence(text, opts = {}) {
  if (kb.mode !== 'steno') kb.setMode('steno');
  const script = scriptFor(text, planner, engine.entries, opts.level || 'all');
  if (!script) return false;
  await playStrokes(script.map(s => s.id), opts);
  return true;
}

export function startRecording() {
  return new Promise(resolve => { state.recording = resolve; });
}
export const cancelRecording = () => { state.recording = null; };

// ------------------------------------------------------------------- layout

function scale() { return parseFloat(getComputedStyle($('phoneWrap')).getPropertyValue('--scale')) || 1; }
function fit() {
  const narrow = window.innerWidth <= 900;
  const s = narrow ? Math.min(1, (window.innerWidth - 16) / 417) : Math.min(1.08, (window.innerHeight - 40) / 876, (window.innerWidth * 0.5) / 417);
  $('phoneWrap').style.setProperty('--scale', Math.max(0.5, s).toFixed(4));
  sizeTrail();
}
window.addEventListener('resize', fit);

// --------------------------------------------------------------------- boot

engine.on(() => { renderField(); renderRibbon(); });
addBubble('are you coming to the thing tonight?', 'in');
saveSettings();
renderPager();
fit();
renderField();
renderRibbon();
mountPanel({
  engine, kb, packs, theory, settings, saveSettings, packsChanged, typeSentence, demonstrate, playStrokes, stopPlaying,
  startRecording, cancelRecording, planStrokes, partsHtml,
  planner: () => planner,
  scriptFor: (text, level) => scriptFor(text, planner, engine.entries, level),
  setContextIfNeeded: context => { if (state.context !== context) setContext(context); },
});
document.fonts?.ready.then(fit);

// For the screenshot and review scripts.
window.wf = { engine, kb, settings, typeSentence, playStrokes, demonstrate, setContext, theory, planner: () => planner, scriptFor: (t, l) => scriptFor(t, planner, engine.entries, l), saveSettings };
