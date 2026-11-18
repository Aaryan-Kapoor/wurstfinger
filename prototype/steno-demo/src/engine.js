// The translator: strokes in, text out. No DOM, no timers, no randomness.
//
// It borrows Plover's model whole. Every stroke is looked up in a stack of
// dictionaries; the longest run of strokes that has an entry wins and may
// rewrite what the shorter run typed; spaces and capitals are the
// translator's job, not the typist's; and one undo takes back one stroke,
// however much text that stroke wrote.
//
// Letters are strokes too. A letter's translation is `{&x}`, which glues to
// the letters round it, so spelling a word is fingerspelling, and the run of
// letters you have spelled is itself an outline: when the word ends, the
// dictionaries are asked about it once more ("tmrw" -> "tomorrow").

import { applyEnding, ENDINGS } from './orthography.js';
import { resolvePacks, labelOf } from './packs.js';
import { isStrokeId } from './layout.js';

const OPENERS = /[(\[{<\n\t /]$/;
const WORD_TAIL = /([A-Za-z][A-Za-z']*)$/;
const MAX_HISTORY = 200;
const MAX_OUTLINE_STROKES = 4;

const capitalise = s => s.replace(/[A-Za-z]/, c => c.toUpperCase());

export class Engine {
  /**
   * @param theory  generated theory (doubling exceptions)
   * @param packs   dictionary stack, highest priority first
   */
  constructor(theory, packs) {
    this.theory = theory;
    this.listeners = new Set();
    this.setPacks(packs);
    this.reset('');
  }

  // ------------------------------------------------------------ dictionaries

  setPacks(packs) {
    this.packs = packs;
    const { entries, source, shadowed, options } = resolvePacks(packs);
    this.entries = entries;
    this.source = source;
    this.shadowed = shadowed;
    this.options = options;
    // Outlines of several strokes, indexed by their last stroke for the longest-match scan.
    this.multi = new Set(Object.keys(entries).filter(o => o.includes('/')));
    if (this.state && !this.state.text) this.state.capNext = options.autoCapitalize;
    this.emit();
  }

  lookup(outline) { return this.entries[outline]; }
  /** What a stroke would type, as a short label, or '' when it is undefined. */
  label(outline) { return labelOf(this.entries[outline]); }

  // ------------------------------------------------------------------ state

  reset(text = '') {
    this.state = {
      text, after: '',
      capNext: this.options.autoCapitalize && !/\S/.test(text.split(/[.?!\n]/).pop() || ''),
      lowerNext: false, attachNext: false,
      pending: null,                  // { start } while a word is being spelled
    };
    this.history = [];                // undo records, oldest first
    this.tape = [];                   // what the ribbon shows
    this.seq = 0;
    this.emit();
  }

  get text() { return this.state.text + this.state.after; }
  get caret() { return this.state.text.length; }

  on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit() { for (const fn of this.listeners) fn(this); }

  /** The letters spelled since the last boundary, and what they will become. */
  pendingOutline() {
    const p = this.state.pending;
    if (!p) return null;
    const typed = this.state.text.slice(p.start);
    const expansion = p.literal ? undefined : this.entries[typed.toLowerCase()];
    return { typed, expansion: expansion && !isStrokeId(typed) ? labelOf(expansion) : null, literal: !!p.literal };
  }

  // ----------------------------------------------------------------- input

  /**
   * One stroke. `id` is a stroke id (`T-n-cw`, `SP`, `T`).
   * Returns the tape entry describing what happened.
   */
  stroke(id) {
    const before = this.snapshot();
    let translation = this.entries[id];
    let outline = id;
    let consumed = 0;                 // earlier strokes this one joins

    // Longest match: does this stroke complete an outline begun by the strokes before it?
    const chain = this.chain();
    for (let k = Math.min(chain.length, MAX_OUTLINE_STROKES - 1); k >= 1; k--) {
      const candidate = [...chain.slice(-k).map(c => c.id), id].join('/');
      if (this.multi.has(candidate)) { outline = candidate; translation = this.entries[candidate]; consumed = k; break; }
    }

    if (translation === undefined) {
      return this.record({ id, outline: id, kind: 'undefined', before, label: '', out: '' });
    }

    let base = before;
    if (consumed) {                   // rewrite: take back the strokes this outline swallows
      const swallowed = this.history.splice(-consumed, consumed);
      base = swallowed[0].before;
      this.restore(base);
      this.tape.splice(-consumed, consumed);
    }
    const kind = this.apply(translation);
    return this.record({ id, outline, kind, before: base, label: labelOf(translation), strokes: consumed + 1 });
  }

  /** Text typed outside the dictionaries (detail and number modes). */
  literal(str) {
    const before = this.snapshot();
    const s = this.state;
    let out = str;
    if (s.capNext && /[a-z]/i.test(str) && this.options.autoCapitalizeLiteral) out = capitalise(str);
    s.text += out;
    s.pending = null; s.attachNext = false; s.capNext = false;
    return this.record({ id: null, outline: str, kind: 'literal', before, label: str });
  }

  /**
   * The undo key. Takes back the last stroke whole; when there is nothing of
   * ours to take back, deletes one character.
   */
  backspace() {
    const last = this.history.pop();
    if (last) {
      this.restore(last.before);
      if (last.expanded && this.state.pending) this.state.pending.literal = true;
      this.tape.pop();
      const entry = { seq: ++this.seq, kind: 'undo', id: '*', outline: '*', label: last.label, out: '', removed: last.out || '' };
      this.lastEvent = entry;
      this.emit();
      return entry;
    }
    const s = this.state;
    if (!s.text) return null;
    const removed = [...s.text].pop();
    s.text = s.text.slice(0, -removed.length);
    this.afterExternalEdit();
    const entry = { seq: ++this.seq, kind: 'delete', id: '*', outline: '*', label: '⌫', out: '', removed };
    this.lastEvent = entry;
    this.emit();
    return entry;
  }

  /** Deletes the word before the caret. Not undoable: it is an edit, not a stroke. */
  deleteWord() {
    const s = this.state;
    const m = /\S+\s*$/.exec(s.text);
    if (!m) return;
    s.text = s.text.slice(0, m.index);
    this.afterExternalEdit();
    this.emit();
  }

  moveCaret(delta) {
    const s = this.state;
    const all = s.text + s.after;
    const at = Math.max(0, Math.min(all.length, s.text.length + delta));
    if (at === s.text.length) return false;
    s.text = all.slice(0, at); s.after = all.slice(at);
    this.afterExternalEdit();
    this.emit();
    return true;
  }

  /** The text changed under us: what we remember about our own strokes no longer applies. */
  afterExternalEdit() {
    const s = this.state;
    this.history = [];
    s.pending = null; s.attachNext = false; s.lowerNext = false;
    const tail = s.text.split(/[.?!\n]/).pop() || '';
    s.capNext = this.options.autoCapitalize && !/\S/.test(tail) && (s.text === '' || /[.?!\n]\s*$/.test(s.text));
  }

  // ------------------------------------------------------------ translation

  /** Applies one translation to the text. Returns the kind of thing it was. */
  apply(translation) {
    const s = this.state;
    const atoms = translation.split(/(\{[^}]*\})/).filter(a => a !== '');
    let kind = 'word';
    let caretMark = null;
    let attachPrev = false;

    for (let i = 0; i < atoms.length; i++) {
      const atom = atoms[i];
      if (atom[0] !== '{') {                                    // plain text
        const text = i === 0 ? atom.replace(/^\s+/, '') : atom;
        if (!text) continue;
        this.word(text, attachPrev);
        attachPrev = true;                                       // the rest of this translation is contiguous
        continue;
      }
      const body = atom.slice(1, -1);
      if (body === '|') { caretMark = s.text.length; continue; }
      if (body === '') { s.attachNext = false; s.capNext = false; continue; }
      if (body[0] === '&') { this.glue(body.slice(1)); kind = 'letter'; continue; }
      if (body === '^') {                                        // bare attach
        if (i === 0) { this.boundary(); attachPrev = true; } else s.attachNext = true;
        continue;
      }
      if (body === '^ ^') {
        // A brief that leaves the caret somewhere, or asks to attach, has already said what follows it.
        if (this.boundary() === 'placed') { kind = 'word'; continue; }
        s.text += ' '; s.attachNext = false; kind = 'space'; continue;
      }
      if (body === '-|') { s.capNext = true; s.lowerNext = false; kind = 'shift'; continue; }
      if (body === '>') { s.lowerNext = true; s.capNext = false; kind = 'shift'; continue; }
      if (/^[.?!]$/.test(body)) { this.mark(body, true); kind = 'mark'; attachPrev = false; continue; }
      if (/^[,:;]$/.test(body)) { this.mark(body, false); kind = 'mark'; attachPrev = false; continue; }
      if (body[0] === '#') { this.key(body.slice(1)); kind = 'key'; continue; }
      const open = body.startsWith('^'), close = body.endsWith('^') && body.length > 1;
      const inner = body.slice(open ? 1 : 0, close ? -1 : undefined);
      if (open && !close && ENDINGS[inner] && i === 0) { this.ending(inner); kind = 'ending'; attachPrev = true; continue; }
      if (open) { this.boundary(); this.trimSpace(); }
      this.word(inner, open || attachPrev);
      if (close) s.attachNext = true;
      attachPrev = true;
      if (open && i === 0) kind = 'ending';
    }
    if (caretMark !== null) {
      s.after = s.text.slice(caretMark) + s.after;
      s.text = s.text.slice(0, caretMark);
    }
    return kind;
  }

  /** Ends the word being spelled, expanding it if the dictionaries know it as an outline. */
  boundary() {
    const s = this.state;
    const p = s.pending;
    if (!p) return false;
    s.pending = null;
    if (p.literal) return false;
    const typed = s.text.slice(p.start);
    const translation = this.entries[typed.toLowerCase()];
    if (translation === undefined || isStrokeId(typed)) return false;
    const wasCapital = /^[A-Z]/.test(typed);
    s.text = s.text.slice(0, p.start);
    s.attachNext = true;                                         // spacing was settled when the first letter went in
    const owed = { cap: s.capNext, lower: s.lowerNext };           // a shift already asked for the word after this one
    s.capNext = wasCapital; s.lowerNext = false;
    const afterBefore = s.after;
    this.apply(translation);
    s.capNext = s.capNext || owed.cap; s.lowerNext = s.lowerNext || owed.lower;
    this.expandedNow = true;
    return (s.after !== afterBefore || s.attachNext) ? 'placed' : true;
  }

  needsSpace() {
    const s = this.state;
    return s.text.length > 0 && !s.attachNext && !OPENERS.test(s.text);
  }

  cased(text) {
    const s = this.state;
    let out = text;
    if (s.capNext) out = capitalise(out);
    else if (s.lowerNext) out = out.replace(/[A-Za-z]/, c => c.toLowerCase());
    s.capNext = false; s.lowerNext = false;
    return out;
  }

  word(text, attach) {
    const s = this.state;
    if (!attach) this.boundary();
    s.text += (!attach && this.needsSpace() ? ' ' : '') + this.cased(text);
    s.attachNext = false;
  }

  glue(letter) {
    const s = this.state;
    if (s.pending) { s.text += letter; return; }                 // inside a spelled word
    if (/^[A-Za-z]$/.test(letter) || s.text === '' || !WORD_TAIL.test(s.text)) {
      const space = this.needsSpace() ? ' ' : '';
      s.text += space;
      s.pending = { start: s.text.length };
      s.text += /^[A-Za-z]$/.test(letter) ? this.cased(letter) : letter;
      s.attachNext = false;
    } else {
      s.text += letter;                                          // an apostrophe after a finished word: Mom's
    }
  }

  trimSpace() { this.state.text = this.state.text.replace(/ +$/, ''); }

  mark(ch, stop) {
    const s = this.state;
    this.boundary();
    this.trimSpace();
    s.text += ch;
    s.attachNext = false;
    if (stop) s.capNext = this.options.autoCapitalize;
  }

  ending(name) {
    const s = this.state;
    this.boundary();
    this.trimSpace();
    const m = WORD_TAIL.exec(s.text);
    if (!m) { s.text += ENDINGS[name].label.replace(/^-/, ''); return; }
    s.text = s.text.slice(0, m.index) + applyEnding(m[1], name, this.theory.doubling);
    s.attachNext = false;
  }

  key(name) {
    const s = this.state;
    this.boundary();
    switch (name) {
      case 'Return': s.text += '\n'; s.capNext = this.options.autoCapitalize; break;
      case 'Tab': s.text += '\t'; break;
      case 'BackSpace': s.text = s.text.slice(0, -1); break;
      case 'Left': if (s.text) { s.after = s.text.slice(-1) + s.after; s.text = s.text.slice(0, -1); } break;
      case 'Right': if (s.after) { s.text += s.after[0]; s.after = s.after.slice(1); } break;
      default: break;
    }
    s.attachNext = false;
  }

  // --------------------------------------------------------------- history

  snapshot() { return { ...this.state, pending: this.state.pending && { ...this.state.pending } }; }
  restore(snap) { this.state = { ...snap, pending: snap.pending && { ...snap.pending } }; }

  /** The strokes since the last thing that was not a stroke, for longest match. */
  chain() {
    const out = [];
    for (let i = this.history.length - 1; i >= 0 && out.length < MAX_OUTLINE_STROKES; i--) {
      const h = this.history[i];
      if (!h.id || h.strokes > 1) break;
      out.unshift(h);
    }
    return out;
  }

  record({ id, outline, kind, before, label, strokes = 1 }) {
    // What changed, as "removed" and "added" after the common prefix.
    const was = before.text + before.after, now = this.state.text + this.state.after;
    let i = 0;
    while (i < was.length && i < now.length && was[i] === now[i]) i++;
    let j = 0;
    while (j < was.length - i && j < now.length - i && was[was.length - 1 - j] === now[now.length - 1 - j]) j++;
    const entry = {
      seq: ++this.seq, id, outline, kind, label,
      out: now.slice(i, now.length - j), removed: was.slice(i, was.length - j),
      expanded: !!this.expandedNow, strokes,
    };
    this.expandedNow = false;
    if (kind !== 'undefined') {
      this.history.push({ id, before, label, out: entry.out, expanded: entry.expanded, strokes });
      if (this.history.length > MAX_HISTORY) this.history.shift();
    }
    this.tape.push(entry);
    if (this.tape.length > 40) this.tape.shift();
    this.lastEvent = entry;
    this.emit();
    return entry;
  }
}
