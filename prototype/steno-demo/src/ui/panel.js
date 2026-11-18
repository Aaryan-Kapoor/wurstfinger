// The side panel: lessons, lookup, dictionaries, the numbers, settings.
// In the app these are settings screens; here they sit beside the phone.

import results from '../eval.generated.js';
import { KEYS, DIRS, DIR_ARROW, strokeId, isStrokeId, LETTER_SLOTS } from '../layout.js';
import { labelOf } from '../packs.js';
import { glyph, describe, letterStroke } from './glyph.js';

const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const PLAY = '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M4 2.5v11l9-5.5z"/></svg>';

const LESSONS = [
  { id: 'flicks', title: '1 · Words on a flick', blurb: 'Every word here is one flick, on the key of its first letter. “I” is just the letter.', text: 'I think you are right about that.' },
  { id: 'flicks2', title: '2 · More flicks', blurb: 'Nothing but flicks again. Notice you never touch the space bar.', text: 'What is it like in here?' },
  { id: 'hooks', title: '3 · Curl for a relative', blurb: 'Flick, then turn a corner. “that” curled right is “that’s”; “to” has today, tonight and tomorrow.', text: "Thanks, that's good. See you tomorrow." },
  { id: 'endings', title: '4 · Finish a word on the space bar', blurb: 'Flick the space bar instead of tapping it: up for -s, up-right for -ing, up-left for the past.', text: 'He wants to keep working on it.' },
  { id: 'spell', title: '5 · Spell the rest, and stop early', blurb: 'Anything else you spell as always. When the ribbon shows the whole word, you can stop: the next stroke finishes it.', text: 'Probably because everything is different.' },
  { id: 'shell', title: '6 · A shell, with its own dictionary', context: 'terminal', blurb: 'In a field that wants no capitals the Shell dictionary takes over: gc is a commit with the caret inside the quotes.', strokes: ['O-sw', 'O-w', 'SP', 'S-nw', 'I', 'I-sw', 'SP', 'T', 'T-ne', 'O-ne', 'O'], expect: 'git commit -m "fix typo"' },
];

export function mountPanel(api) {
  const { engine, kb, packs, theory, settings } = api;
  const $ = id => document.getElementById(id);

  // ------------------------------------------------------------------ tabs
  $('tabs').addEventListener('click', e => {
    const b = e.target.closest('button'); if (!b) return;
    for (const t of $('tabs').children) t.setAttribute('aria-selected', t === b);
    for (const name of ['learn', 'lookup', 'packs', 'numbers', 'settings']) $('pane-' + name).hidden = name !== b.dataset.tab;
    if (b.dataset.tab === 'packs') renderPacks();
    if (b.dataset.tab === 'lookup') renderKeyMap();
  });

  // ----------------------------------------------------------------- learn
  let active = null;                    // the lesson being tried

  const lessonScript = l => l.strokes ? l.strokes.map(id => ({ id })) : api.scriptFor(l.text, 'all');

  /** The lesson's words with the strokes that write them underneath. */
  function lessonWords(l) {
    if (l.strokes) return [{ text: l.expect, parts: l.strokes.map(id => ({ stroke: id })) }];
    const out = [];
    let script = api.scriptFor(l.text, 'all') || [];
    const tokens = l.text.match(/[A-Za-z]+(?:'[A-Za-z]+)*|[^\sA-Za-z]/g) || [];
    let i = 0;
    for (const tok of tokens) {
      if (!/^[A-Za-z]/.test(tok)) { out.push({ text: tok, punct: true, parts: [] }); while (script[i] && script[i].kind === 'mark') { i++; break; } continue; }
      const parts = [];
      while (script[i] && (script[i].kind === 'space' || script[i].kind === 'shift')) i++;
      let letters = '';
      while (script[i] && script[i].word === tok) {
        const s = script[i++];
        if (['flick', 'hook', 'ending'].includes(s.kind)) { if (letters) { parts.push({ letters }); letters = ''; } parts.push({ stroke: s.id }); }
        else letters += labelOf(engine.lookup(s.id));
      }
      if (letters) parts.push({ letters });
      out.push({ text: tok, parts });
    }
    return out;
  }

  function renderLearn() {
    const rules = [
      { ids: ['T-n'], title: 'A flick is a word', text: 'Letters and the six everyday marks keep their directions. Every other direction on a key now types <b>a word that starts with one of that key’s letters</b>, with its space.' },
      { ids: ['T-n-back'], title: 'A curl is its relative', text: 'Finish the flick with a corner: <b>right</b> for is/are/am, <b>left</b> for not/will, <b>back</b> for have, then the words that begin the same way.' },
      { ids: ['SP-ne'], title: 'The space bar ends a word', text: 'Tap it for a space when you need one. Flick it to end the word with <b>-s, -ing, -ed, -ly, -er or ’s</b>; the spelling follows.' },
      { ids: ['T', 'O', 'R-w', 'O'], title: 'Everything else is spelled', text: 'Letters still work, so no word is ever out of reach. Common long words finish themselves after a few letters, and <b>one undo takes back a whole stroke</b>.' },
    ];
    const pane = $('pane-learn');
    pane.innerHTML = `<h2>Four rules</h2>` + rules.map((r, i) => `
      <div class="card rule">
        <button class="demo" data-rule="${i}" title="Show me">${glyph(r.ids[0], 44)}</button>
        <div><h3>${r.title}</h3><p>${r.text}</p></div>
      </div>`).join('')
      + `<h2>Try it</h2>` + LESSONS.map(l => `
      <div class="card lesson" data-lesson="${l.id}">
        <h3>${esc(l.title)}</h3>
        <p>${esc(l.blurb)}</p>
        <div class="target">${lessonWords(l).map((w, i) => `<span class="w${w.punct ? ' punct' : ''}" data-i="${i}"><span>${esc(w.text)}</span><span class="strokes">${api.partsHtml(w.parts, 40)}</span></span>`).join('')}</div>
        <div class="row"><button class="btn" data-watch="${l.id}">${PLAY} Watch</button><button class="btn quiet" data-try="${l.id}">Try it yourself</button><span class="meta" data-meta="${l.id}"></span></div>
      </div>`).join('')
      + `<p class="note">The words under each key and every stroke above were assigned by a program from 4.3 million words of conversation and real text messages. “Numbers” has the method and what it buys.</p>`;
    for (const l of LESSONS) {
      const n = (lessonScript(l) || []).length, letters = (l.expect || l.text).length;
      pane.querySelector(`[data-meta="${l.id}"]`).textContent = `${n} strokes · ${letters} letter by letter`;
    }
  }

  $('pane-learn').addEventListener('click', async e => {
    const rule = e.target.closest('[data-rule]');
    if (rule) {
      const demos = [['T-n'], ['T-n-back'], ['T-nw', 'SP-ne'], ['T', 'O', 'R-w', 'O']];
      api.setContextIfNeeded('messages');
      api.playStrokes(demos[+rule.dataset.rule], { dry: true, speed: 0.4, hold: 520, gap: 420 });
      return;
    }
    const watch = e.target.closest('[data-watch]'), tryIt = e.target.closest('[data-try]');
    const id = (watch || tryIt)?.dataset.watch || (watch || tryIt)?.dataset.try;
    if (!id) return;
    const l = LESSONS.find(x => x.id === id);
    api.setContextIfNeeded(l.context || 'messages');
    engine.reset('');
    active = { lesson: l, startSeq: engine.seq };
    progress();
    if (watch) await api.playStrokes(lessonScript(l).map(s => s.id), { speed: 0.5, hold: 300, gap: 260 });
  });

  /** Marks the words of the active lesson as they appear in the field. */
  function progress() {
    for (const card of $('pane-learn').querySelectorAll('.lesson')) {
      const mine = active && card.dataset.lesson === active.lesson.id;
      for (const w of card.querySelectorAll('.w')) w.classList.remove('done', 'next');
      if (!mine) continue;
      const l = active.lesson;
      const words = lessonWords(l);
      const typed = engine.text.toLowerCase().trim();
      const target = (l.expect || l.text).toLowerCase();
      let upTo = 0, done = 0;
      if (l.strokes) done = typed === target ? 1 : 0;
      else for (const [i, w] of words.entries()) {
        const at = target.indexOf(w.text.toLowerCase(), upTo);
        const end = at + w.text.length;
        if (typed.length >= end && typed.slice(0, end) === target.slice(0, end)) { done = i + 1; upTo = end; } else break;
      }
      const els = card.querySelectorAll('.w');
      els.forEach((w, i) => { w.classList.toggle('done', i < done); w.classList.toggle('next', i === done); });
      const meta = card.querySelector('[data-meta]');
      const used = engine.seq - active.startSeq;
      if (done === words.length) meta.textContent = `Done in ${used} strokes · ${(l.expect || l.text).length} letter by letter`;
    }
  }
  engine.on(progress);

  // ---------------------------------------------------------------- lookup
  function renderLookup() {
    $('pane-lookup').innerHTML = `
      <h2>How do I write…</h2>
      <div class="lookup"><input id="lookupWord" type="text" placeholder="a word, such as because or thinking" autocomplete="off" autocapitalize="off" spellcheck="false"></div>
      <div class="plan" id="lookupPlan"></div>
      <h2>What is on each key</h2>
      <p>The flick word in each free direction, then its curls. Letters keep their own two curls.</p>
      <div class="keymap" id="keymap"></div>`;
    $('lookupWord').addEventListener('input', lookup);
    lookup();
  }

  function lookup() {
    const raw = $('lookupWord').value.trim().toLowerCase();
    const out = $('lookupPlan');
    if (!raw) { out.innerHTML = '<span class="how">Type a word to see its one stroke. Every word has exactly one.</span>'; return; }
    if (!/^[a-z']+$/.test(raw)) { out.innerHTML = '<span class="how">Letters only, please.</span>'; return; }
    const plan = api.planner().plan(raw);
    const s = api.planStrokes(plan);
    if (!s) {
      out.innerHTML = `<div class="strokes"><span class="spell" style="font:700 13px var(--rounded)">${esc(raw)}</span></div><span class="how">Spelled letter by letter: <b>${raw.length} taps and flicks</b>. No stroke is assigned; add one under Dictionaries.</span>`;
      return;
    }
    const how = plan.kind === 'flick' ? `one flick: ${describe(plan.strokes[0])}`
      : plan.kind === 'hook' ? `${describe(plan.strokes[0])}`
      : plan.kind === 'brief' ? `spell <b>${esc(plan.outline)}</b>; the next stroke or space finishes it`
      : `${esc(plan.base.word)}, then ${describe(plan.strokes.at(-1))}`;
    out.innerHTML = `<div class="strokes">${api.partsHtml(s.parts, 36)}</div><span class="how"><b>${s.gestures} ${s.gestures === 1 ? 'stroke' : 'strokes'}</b> instead of ${raw.length + 1}. ${how[0].toUpperCase() + how.slice(1)}.</span><button class="btn quiet" id="lookupShow">${PLAY} Show me</button>`;
    $('lookupShow').addEventListener('click', () => api.demonstrate(s.parts));
  }

  function renderKeyMap() {
    const map = $('keymap'); if (!map) return;
    map.innerHTML = KEYS.map(key => {
      let html = `<div class="k"><b>${key.toLowerCase()}</b>`;
      for (const dir of DIRS) {
        const base = engine.lookup(strokeId(key, dir));
        if (base === undefined) continue;
        const label = labelOf(base);
        const curls = ['cw', 'ccw', 'back'].map(t => labelOf(engine.lookup(strokeId(key, dir, t)))).filter(l => l && !/^[A-Z]$/.test(l));
        if (/^\{&/.test(base) && !curls.length) continue;
        html += `<div><span>${DIR_ARROW[dir]} ${esc(label)}</span>${curls.length ? `<span style="color:var(--ink-3);font-weight:500">${esc(curls.join(' · '))}</span>` : ''}</div>`;
      }
      return html + '</div>';
    }).join('');
  }

  // ----------------------------------------------------------------- packs
  let openPack = 'mine';
  let filter = '';

  function renderPacks() {
    const pane = $('pane-packs');
    const pack = packs.find(p => p.id === openPack);
    const entries = Object.entries(pack.entries).filter(([o, t]) => !filter || o.toLowerCase().includes(filter) || t.toLowerCase().includes(filter));
    const shadowed = engine.shadowed.filter(s => s.pack === openPack);
    pane.innerHTML = `
      <h2>Dictionaries</h2>
      <p>Everything steno mode types comes from these, letters included. They are stacked: <b>the first one that knows a stroke wins</b>. Switch one on for a job, or put your own strokes on top.</p>
      ${packs.map(p => `
        <div class="card pack" data-pack="${p.id}" style="${p.id === openPack ? 'box-shadow: inset 0 0 0 1.5px var(--accent)' : 'cursor:pointer'}">
          <button class="switch" role="switch" aria-checked="${p.enabled}" data-toggle="${p.id}" aria-label="Use ${esc(p.name)}"></button>
          <div><div class="name">${esc(p.name)}</div><div class="desc">${esc(p.description)}</div></div>
          <div class="count">${Object.keys(p.entries).length}</div>
        </div>`).join('')}
      <h2>${esc(pack.name)}</h2>
      <div class="lookup"><input id="packFilter" type="text" placeholder="Filter ${Object.keys(pack.entries).length} entries" value="${esc(filter)}" autocomplete="off" spellcheck="false"></div>
      <div class="entries">${entries.slice(0, 150).map(([o, t]) => `
        <div class="e"><span>${isStrokeId(o) ? glyph(o, 26) : ''}</span><code>${esc(o)}</code><span class="t">${esc(t)}</span>${pack.editable ? `<button class="x" data-del="${esc(o)}" aria-label="Remove">×</button>` : '<span></span>'}</div>`).join('') || '<div class="e"><span></span><code></code><span class="t" style="color:var(--ink-3)">Nothing here yet.</span><span></span></div>'}
      </div>
      ${entries.length > 150 ? `<div class="note">Showing 150 of ${entries.length}. Filter to narrow it.</div>` : ''}
      ${pack.editable ? `
        <div class="entry">
          <div class="outline"><input id="newOutline" type="text" placeholder="stroke or letters" autocomplete="off" autocapitalize="off" spellcheck="false"><button class="rec" id="recBtn">Record</button></div>
          <input id="newText" type="text" placeholder="what it types" autocomplete="off" spellcheck="false">
          <button class="btn" id="addBtn">Add</button>
        </div>
        <div class="note" id="entryNote">A stroke is written <code>T-n</code>, <code>T-n-cw</code>, <code>SP-ne</code>; letters such as <code>omw</code> expand when the word ends. Or press Record and make the stroke on the keyboard.</div>` : `<div class="note">This dictionary is generated and read-only. To change one of its strokes, add the same stroke to “My strokes”: it wins.</div>`}
      ${shadowed.length ? `<div class="note warn">${shadowed.length} ${shadowed.length === 1 ? 'entry here is' : 'entries here are'} overridden by a dictionary above: ${shadowed.slice(0, 6).map(s => `<code>${esc(s.outline)}</code>`).join(' ')}</div>` : ''}
      <h2>Text format</h2>
      <p>Plain JSON, the same shape as a Plover dictionary, with the operators <code>{^ing}</code> <code>{pre^}</code> <code>{&amp;x}</code> <code>{.}</code> <code>{-|}</code> <code>{#Return}</code> and <code>{|}</code> for where the caret lands.</p>
      <textarea id="packJson" rows="6" spellcheck="false" style="font:500 12px var(--mono)" ${pack.editable ? '' : 'readonly'}>${esc(JSON.stringify(pack.editable ? pack.entries : Object.fromEntries(Object.entries(pack.entries).slice(0, 40)), null, 1))}</textarea>
      ${pack.editable ? '<div class="row" style="margin-top:6px"><button class="btn quiet" id="applyJson">Apply JSON</button><span class="note" id="jsonNote" style="margin:0"></span></div>' : '<div class="note">First 40 entries shown.</div>'}`;
    $('packFilter').addEventListener('input', e => { filter = e.target.value.toLowerCase(); const pos = e.target.selectionStart; renderPacks(); const f = $('packFilter'); f.focus(); f.setSelectionRange(pos, pos); });
    $('addBtn')?.addEventListener('click', addEntry);
    $('newText')?.addEventListener('keydown', e => { if (e.key === 'Enter') addEntry(); });
    $('recBtn')?.addEventListener('click', record);
    $('applyJson')?.addEventListener('click', applyJson);
  }

  async function record() {
    const btn = $('recBtn');
    if (btn.classList.contains('on')) { api.cancelRecording(); btn.classList.remove('on'); btn.textContent = 'Record'; return; }
    btn.classList.add('on'); btn.textContent = 'Stroke now';
    if (kb.mode !== 'steno') kb.setMode('steno');
    const id = await api.startRecording();
    const input = $('newOutline');
    if (input) { input.value = id; $('recBtn').classList.remove('on'); $('recBtn').textContent = 'Record'; $('newText').focus(); note(`Recorded ${id}: ${describe(id)}.`); }
  }

  const note = (text, warn) => { const n = $('entryNote'); if (n) { n.textContent = text; n.classList.toggle('warn', !!warn); } };

  function addEntry() {
    const outline = $('newOutline').value.trim(), text = $('newText').value;
    if (!outline || !text) { note('Give both a stroke (or letters) and what it types.', true); return; }
    const valid = outline.split('/').every(isStrokeId) || /^[a-z0-9'.\-]+$/.test(outline);
    if (!valid) { note('That is neither a stroke such as T-n-cw nor lowercase letters.', true); return; }
    const pack = packs.find(p => p.id === openPack);
    const was = engine.lookup(outline);
    pack.entries[outline] = text;
    if (!pack.enabled) pack.enabled = true;
    api.packsChanged();
    renderPacks();
    note(was !== undefined && was !== text ? `Added. It now overrides “${labelOf(was)}”.` : 'Added.');
  }

  function applyJson() {
    const pack = packs.find(p => p.id === openPack);
    try {
      const parsed = JSON.parse($('packJson').value);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('expected an object of outline: translation');
      for (const [o, t] of Object.entries(parsed)) if (typeof t !== 'string') throw new Error(`"${o}" must map to text`);
      pack.entries = parsed;
      api.packsChanged();
      renderPacks();
      $('jsonNote').textContent = `Applied ${Object.keys(parsed).length} entries.`;
    } catch (err) { $('jsonNote').textContent = `Not applied: ${err.message}`; $('jsonNote').classList.add('warn'); }
  }

  $('pane-packs').addEventListener('click', e => {
    const toggle = e.target.closest('[data-toggle]');
    if (toggle) { const p = packs.find(x => x.id === toggle.dataset.toggle); p.enabled = !p.enabled; api.packsChanged(); renderPacks(); return; }
    const del = e.target.closest('[data-del]');
    if (del) { delete packs.find(p => p.id === openPack).entries[del.dataset.del]; api.packsChanged(); renderPacks(); return; }
    const card = e.target.closest('[data-pack]');
    if (card && card.dataset.pack !== openPack) { openPack = card.dataset.pack; filter = ''; renderPacks(); }
  });
  document.addEventListener('wf-context', () => { if (!$('pane-packs').hidden) renderPacks(); });

  // --------------------------------------------------------------- numbers
  function renderNumbers(corpus = 'daily') {
    const r = results.evaluation[corpus];
    const names = { daily: 'Everyday dialogue', movie: 'Film dialogue', sms: 'Real SMS (Singapore)' };
    const max = Math.max(...r.stages.map(s => s.wpm));
    $('pane-numbers').innerHTML = `
      <h2>What it buys, on text it never saw</h2>
      <p>A tenth of each corpus was held out before the strokes were assigned. A model typist then typed it: <b>${r.messages.toLocaleString()} messages, ${r.chars.toLocaleString()} characters</b>. Each row adds what a learner would pick up next.</p>
      <div class="seg" id="corpusSeg">${Object.keys(results.evaluation).map(c => `<button data-corpus="${c}" aria-pressed="${c === corpus}">${names[c]}</button>`).join('')}</div>
      <table class="t"><tr><th>You know</th><th>Strokes per word</th><th>Fewer strokes</th><th>Model WPM</th><th>Pessimistic</th></tr>
        ${r.stages.map(s => `<tr><td>${esc(s.stage)}</td><td>${s.gesturesPerWord.toFixed(2)}</td><td>${s.saving.toFixed(0)} %</td><td>${s.wpm.toFixed(0)}</td><td>${s.wpmRecall.toFixed(0)}</td></tr>`).join('')}
      </table>
      <div class="bars">${r.stages.map(s => `<div class="bar"><span class="lbl">${esc(s.stage)}</span><div class="track"><div class="fill" style="width:${(s.wpm / max * 100).toFixed(1)}%"></div></div><span class="val">${s.gesturesPerWord.toFixed(2)} / word</span></div>`).join('')}</div>
      <p class="note">Stroke counts are exact. Words per minute are a model: a one-thumb expert at 262 ms per letter, 300 ms per word flick, 702 ms per curl (sources in <code>src/model.js</code>). “Pessimistic” makes curls 922 ms and adds 300 ms of recall to every stroke that is not a letter. The letter keyboard is ${r.letterWpm} WPM under the same model. None of this is a measurement of people.</p>
      <h2>Where the words come from</h2>
      <p>${Object.values(theory.meta.corpora).reduce((s, c) => s + c.trainingTokens, 0).toLocaleString()} words from three corpora: film dialogue, written everyday dialogue and real text messages. A word’s weight is the geometric mean of its frequency in all three, so it has to be common everywhere. The ${theory.meta.counts.flicks} flick words are ${theory.meta.share.flicks} % of all word tokens; the ${theory.meta.counts.hooks} curls another ${theory.meta.share.hooks} %.</p>
      <h2>How often a stroke is misread</h2>
      <p>A synthetic thumb drew every shape 3,200 times at three levels of sloppiness (at 1.0: direction off by 9°, length off by a quarter, corner cut). This tests the recogniser’s margins, not human hands.</p>
      <table class="t"><tr><th>Sloppiness</th><th>Flick</th><th>Curl right</th><th>Curl left</th><th>Back</th><th>All</th></tr>
        ${Object.entries(results.robustness).sort((a, b) => a[0] - b[0]).map(([lvl, x]) => `<tr><td>${lvl}</td><td>${x.shapes.flick} %</td><td>${x.shapes.cw} %</td><td>${x.shapes.ccw} %</td><td>${x.shapes.back} %</td><td>${x.accuracy} %</td></tr>`).join('')}
      </table>`;
    $('corpusSeg').addEventListener('click', e => { const b = e.target.closest('button'); if (b) renderNumbers(b.dataset.corpus); });
  }

  // -------------------------------------------------------------- settings
  function renderSettings() {
    const seg = (id, options, value) => `<div class="seg" data-setting="${id}">${options.map(([v, label]) => `<button data-value="${v}" aria-pressed="${String(v) === String(value)}">${label}</button>`).join('')}</div>`;
    $('pane-settings').innerHTML = `
      <h2>Settings</h2>
      <div class="card">
        <div class="setting"><div><div class="what">Guide</div><div class="why">The map above your finger. “Fades” shows it at once on a key you are new to and waits longer the more you use that key.</div></div>${seg('guide', [['adaptive', 'Fades'], ['always', 'Always'], ['pause', 'On pause'], ['off', 'Off']], settings.guide)}</div>
        <div class="setting"><div><div class="what">Words on the keys</div><div class="why">Hide them once you know them; the guide still shows them.</div></div>${seg('words', [[true, 'Shown'], [false, 'Hidden']], settings.words)}</div>
        <div class="setting"><div><div class="what">Finger trail</div><div class="why">Draws the path of each stroke.</div></div>${seg('trail', [[true, 'On'], [false, 'Off']], settings.trail)}</div>
        <div class="setting"><div><div class="what">Appearance</div></div>${seg('theme', [['dark', 'Dark'], ['light', 'Light']], settings.theme)}</div>
        <div class="setting"><div><div class="what">Practice memory</div><div class="why">The guide remembers how often you used each key. ${Object.values(kb.usage).reduce((s, n) => s + n, 0)} word strokes so far.</div></div><button class="btn quiet" id="resetUsage">Forget</button></div>
      </div>
      <h2>Getting around</h2>
      <div class="card">
        <p><b>Switch keyboards</b> by dragging the strip above the keys sideways, by swiping the keys with two fingers, or with the corner key: up-left for numbers, up-right for letters.</p>
        <p><b>The corner key</b> holds what the right-hand column used to: tap to undo a stroke, flick up to send, left to delete a word, and drag left to keep deleting.</p>
        <p><b>The space bar</b> is two keys wide everywhere. Drag it sideways to move the caret.</p>
      </div>`;
    $('pane-settings').querySelectorAll('[data-setting]').forEach(s => s.addEventListener('click', e => {
      const b = e.target.closest('button'); if (!b) return;
      const v = b.dataset.value;
      settings[s.dataset.setting] = v === 'true' ? true : v === 'false' ? false : v;
      api.saveSettings(); renderSettings();
    }));
    $('resetUsage').addEventListener('click', () => { kb.usage = {}; localStorage.removeItem('wf-steno-usage'); renderSettings(); });
  }

  renderLearn(); renderLookup(); renderNumbers(); renderSettings();
  return { renderPacks, renderLearn };
}
