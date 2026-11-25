// B8Script in JavaScript: the interpreter of the web player (b8script.html).
//
// It follows ref.py, the reference interpreter in B8Script-interpreters/testing,
// step for step, so that the test suite can check it byte for byte
// (test_web.py). Two modes:
//   live  (the page): ? waits for real. A wait is not done in a loop; step()
//         throws WAIT and leaves the ? to run again, so the page can give the
//         browser its turn and come back when a key comes or the time is up.
//   test  (test_web.py): input is a list of keys, as in ref.py. 0? (or a line)
//         with no keys left ends the run; n? with none left returns 0.
//         With play set, any ? with no keys left ends the run (test_games.py).
// Output is bytes, the same bytes ref.py prints: the console escapes are ANSI.
'use strict';

const CR = 13;
const STOP = { stop: true };                 // the program ended
const WAIT = { wait: true };                 // a ? is waiting (live mode)
const DS_MAX = 250, RS_MAX = 120;            // as in ref.py: so that a runaway ends
const isDig = c => c >= 48 && c <= 57;
const isHex = c => isDig(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);

class Err {
  constructor(code, place) { this.code = code; this.place = place; }
}

class B8 {
  constructor(prog, o = {}) {
    this.m = new Uint8Array(65536);
    this.progAt = o.progAt ?? 0x9000;
    this.let = o.let ?? 0x8000;
    this.lb = o.linebuf ?? 0x8100;
    this.heaplim = o.heaplim ?? 0xE000;
    this.retbyte = o.retbyte ?? 0xC9;
    this.checked = !!o.checked;
    this.live = !!o.live;
    this.play = !!o.play;
    this.now = o.now || (() => Date.now());
    this.m.set(prog, this.progAt);
    this.m[this.progAt + prog.length] = 0;
    this.ip = this.progAt;
    this.heapcell = this.let + 0x7C;
    this.progend = this.progAt + prog.length + 1;
    this.w(this.heapcell, this.progend);
    this.undef = new Set();
    if (this.checked) for (let c = 0x41; c <= 0x5A; c++) this.undef.add(c);
    this.at = this.progAt;
    this.ds = [];
    this.rs = [];
    this.inp = Array.from(o.inp || []);      // keys not yet read
    this.out = [];
    this.error = null;                       // the letter of a checked build's error
    this.ended = false;
    this.why = '';                           // why the run ended, for the page
    this.waitAt = -1;                        // the ? that is waiting, and till when
    this.waitUntil = 0;
    this.line = null;                        // a -n? line being typed (live)
  }

  // memory
  w(a, v) { this.m[a & 0xFFFF] = v & 0xFF; this.m[(a + 1) & 0xFFFF] = (v >> 8) & 0xFF; }
  r(a) { return this.m[a & 0xFFFF] | (this.m[(a + 1) & 0xFFFF] << 8); }
  cell(c) { return this.let + 2 * (c - 0x41); }

  // stacks: an empty one is an underflow (s or r) in a checked build, 0 otherwise
  push(v) { this.ds.push(v & 0xFFFF); }
  pop() {
    if (!this.ds.length) { if (this.checked) throw new Err('s', this.at); return 0; }
    return this.ds.pop();
  }
  top() {
    if (!this.ds.length) { if (this.checked) throw new Err('s', this.at); return 0; }
    return this.ds[this.ds.length - 1];
  }
  rpop() {
    if (!this.rs.length) { if (this.checked) { this.rs = []; throw new Err('r', this.at); } return 0; }
    return this.rs.pop();
  }
  static s(v) { return v & 0x8000 ? v - 0x10000 : v; }

  ch() { const c = this.m[this.ip]; this.ip = (this.ip + 1) & 0xFFFF; return c; }
  emit(c) { this.out.push(c & 0xFF); }
  emits(s) { for (let i = 0; i < s.length; i++) this.out.push(s.charCodeAt(i) & 0xFF); }
  pnum(v) { this.emits(String(B8.s(v & 0xFFFF))); }

  skipString() {          // past the closing quote; false if the text ran out first
    for (;;) {
      let c = this.ch();
      if (c === 47) { c = this.ch(); if (c) continue; }
      if (c === 0) return false;
      if (c === 34) return true;
    }
  }

  skip(opener) {          // to the closer at this level (see ref.py)
    let d = 0;
    const at = this.at;
    for (;;) {
      let c = this.ch();
      if (c === 34 && !this.skipString()) c = 0;
      if (c === 0) {
        if (opener === 92 || !this.checked) throw STOP;
        throw new Err('N', at);
      } else if (c === 40 || c === 91) d++;
      else if (c === 41 || c === 93) {
        if (d === 0) {
          if (this.checked && ((opener === 40 && c === 93) || (opener === 91 && c === 41))) throw new Err('N', at);
          return c;
        }
        d--;
      }
    }
  }

  // keys
  haveKey() { return this.inp.length > 0; }
  key() { return this.inp.shift(); }
  noKey() {               // a ? found no key: wait (live) or end (test)
    if (this.live) throw WAIT;
    this.why = 'input'; throw STOP;
  }

  // -n?: Backspace takes one back and is echoed; CR ends the line, stored and not
  // echoed; any other key is stored and echoed while there is room.
  readline(n) {
    n = Math.min(n, 127);
    if (!this.line) this.line = [];
    const buf = this.line;
    for (;;) {
      if (!this.haveKey()) this.noKey();
      const c = this.key();
      if (c === CR) break;
      if (c === 8) { if (buf.length) { buf.pop(); this.emit(8); } }
      else if (buf.length < n) { buf.push(c); this.emit(c); }
    }
    buf.push(CR);
    this.m.set(buf, this.lb);
    this.line = null;
    return this.lb;
  }

  linecol(place) {
    if (place < this.progAt) return [0, ((place - this.lb) & 0xFFFF) + 1];
    let start = this.progAt, line = 1;
    for (let a = this.progAt; a < place; a++) if (this.m[a] === 10) { line++; start = a + 1; }
    return [line, place - start + 1];
  }

  report(code, place) {
    const [line, col] = this.linecol(place);
    this.emits(`\r\nErr ${code} @ ${line},${col}\r\n`);
    this.emits(`D:${this.ds.length}:`);
    if (this.ds.length > 8) this.emits(' ...');
    for (const v of this.ds.slice(-8)) this.emits(' ' + B8.s(v));
    this.emits(`\r\nR:${this.rs.length}\r\n`);
  }

  escape(c) {             // $ met / and a character from 60h to 7Eh
    if (c >= 0x61 && c <= 0x7A) this.pnum(this.r(this.cell(c)));
    else if (c === 0x7E) {
      if (this.checked && this.ds.length < 3) { this.ds = []; throw new Err('s', this.at); }
      const n = this.ds.length;
      const col = n >= 2 ? this.ds.splice(n - 2, 1)[0] : 0;
      const row = this.ds.length >= 2 ? this.ds.splice(this.ds.length - 2, 1)[0] : 0;
      this.emits(`\x1b[${(row + 1) & 0xFFFF};${(col + 1) & 0xFFFF}H`);
    } else this.emits({ 0x60: '\x1b[?25l', 0x7B: '\x1b[H\x1b[J', 0x7C: '\x1b[?25h', 0x7D: '\x1b[K' }[c]);
  }

  // Run up to n steps. Returns 'run' (steps used up), 'wait', 'end' or 'error'.
  run(n = 5000000) {
    try {
      for (let i = 0; i < n; i++) {
        this.at = this.ip;
        this.step();
        if (this.checked && this.ds.length > DS_MAX) throw new Err('S', this.at);
        if (this.checked && this.rs.length > RS_MAX) throw new Err('R', this.at);
      }
      return 'run';
    } catch (e) {
      if (e === WAIT) { this.ip = this.at; return 'wait'; }
      return this.finish(e);
    }
  }

  finish(e) {
    this.ended = true;
    if (e instanceof Err) {
      this.error = e.code;
      this.report(e.code, e.place);
      return 'error';
    }
    if (e === STOP) return 'end';
    throw e;
  }

  // The break key (Ctrl-C), from the page: a checked build reports B at the
  // character about to run; an unchecked one just stops.
  brk() {
    if (this.ended) return;
    if (this.checked) this.finish(new Err('B', this.ip));
    else { this.ended = true; this.why = 'break'; }
  }

  storeOk(a, n) { return !this.checked || (this.let <= a && a + n <= this.heaplim); }

  step() {
    let c = this.ch();
    if (c === 0) throw STOP;
    if (c >= 128 && this.checked) throw new Err('X', this.at);
    if (c <= 32 || c >= 127) return;
    if (isDig(c) || (c === 45 && isDig(this.m[this.ip]))) {
      const neg = c === 45;
      if (neg) c = this.ch();
      let v = 0;
      for (;;) {
        v = (v * 10 + c - 48) & 0xFFFF;
        if (!isDig(this.m[this.ip])) break;
        c = this.ch();
      }
      this.push(neg ? -v : v);
      return;
    }
    if (c >= 65 && c <= 90) {                                  // A-Z: call a word
      if (this.undef.has(c)) throw new Err('U', this.at);
      this.rs.push(this.ip);
      this.ip = this.r(this.cell(c));
      return;
    }
    if (c >= 97 && c <= 122) { this.push(this.cell(c)); return; }   // a-z: a variable
    let a, b, v;
    switch (c) {
      case 43: b = this.pop(); a = this.pop(); this.push(a + b); break;           // +
      case 45: b = this.pop(); a = this.pop(); this.push(a - b); break;           // -
      case 42: b = this.pop(); a = this.pop(); this.push((a * b) % 65536); break;  // *
      case 47: {                                                                   // /
        if (this.checked && this.ds.length > 1 && this.ds[this.ds.length - 1] === 0) throw new Err('Z', this.at);
        b = B8.s(this.pop()); a = B8.s(this.pop());
        let q, r;
        if (b === 0) { q = 0; r = a; }
        else {
          q = Math.floor(Math.abs(a) / Math.abs(b));
          if ((a < 0) !== (b < 0)) q = -q;
          r = a - q * b;
        }
        this.push(q); this.push(r);
        break;
      }
      case 38: b = this.pop(); a = this.pop(); this.push(a & b); break;           // &
      case 124: b = this.pop(); a = this.pop(); this.push(a | b); break;          // |
      case 94: b = this.pop(); a = this.pop(); this.push(a ^ b); break;           // ^
      case 126: this.push(~this.pop()); break;                                    // ~
      case 60: case 61: case 62: {                                                // < = >
        b = B8.s(this.pop()); a = B8.s(this.pop());
        this.push((c === 60 ? a < b : c === 61 ? a === b : a > b) ? -1 : 0);
        break;
      }
      case 58: a = this.pop(); this.push(a); this.push(a); break;                 // :
      case 59: this.pop(); break;                                                 // ;
      case 37: b = this.pop(); a = this.pop(); this.push(b); this.push(a); break; // %
      case 123: this.rs.push(this.pop()); break;                                  // {
      case 125: this.push(this.rpop()); break;                                    // }
      case 64: this.push(this.r(this.pop())); break;                              // @
      case 33:                                                                    // !
        if (this.ds.length > 1 && !this.storeOk(this.ds[this.ds.length - 1], 2)) throw new Err('O', this.at);
        a = this.pop(); v = this.pop(); this.w(a, v);
        break;
      case 44: this.push(this.m[this.pop()]); break;                              // ,
      case 46:                                                                    // .
        if (this.ds.length > 1 && !this.storeOk(this.ds[this.ds.length - 1], 1)) throw new Err('O', this.at);
        a = this.pop(); v = this.pop(); this.m[a] = v & 0xFF;
        break;
      case 95: {                                                                  // _
        const h = this.r(this.heapcell);
        if (this.checked && this.ds.length) {
          const e = h + B8.s(this.top());
          if (!(this.progend <= e && e < this.heaplim)) throw new Err('H', this.at);
        }
        const n = this.pop();
        this.push(h); this.w(this.heapcell, h + n);
        break;
      }
      case 40:                                                                    // (
        if (this.pop()) this.rs.push(this.ip); else this.skip(c);
        break;
      case 41:                                                                    // )
        if (this.pop()) {
          if (!this.rs.length) { if (this.checked) throw new Err('r', this.at); this.ip = 0; }
          else this.ip = this.rs[this.rs.length - 1];
        } else this.rpop();
        break;
      case 92:                                                                    // \
        if (this.pop()) {
          const k = this.skip(c);
          if (k === 41) this.rpop(); else this.ip = this.rpop();
        }
        break;
      case 91: {                                                                  // [
        const n = this.ch();
        if ((n | 0x20) >= 0x61 && (n | 0x20) <= 0x7A) { this.w(this.cell(n), this.ip); this.undef.delete(n); }
        else if (n !== 32 && this.checked) throw new Err('W', this.ip - 1);
        else this.push(this.ip);
        this.skip(c);
        break;
      }
      case 93: this.ip = this.rpop(); break;                                      // ]
      case 34:                                                                    // "
        this.push(this.ip);
        if (!this.skipString()) { if (this.checked) throw new Err('Q', this.at); throw STOP; }
        break;
      case 36: {                                                                  // $
        a = this.top();
        for (;;) {
          let k = this.m[a & 0xFFFF]; a++;
          if (k === 34) break;
          if (k === 47) {
            k = this.m[a & 0xFFFF]; a++;
            if (k >= 0x60 && k <= 0x7E) { this.escape(k); continue; }
            k &= 0xBF;
          } else if (k === 0 && this.checked) throw new Err('Q', this.at);
          this.emit(k);
        }
        this.pop();
        break;
      }
      case 39: this.emit(this.pop()); break;                                      // '
      case 35: this.pnum(this.pop()); break;                                      // #
      case 63: {                                                                  // ?
        // The count stays on the stack until the ? is done, so that a wait can
        // run the ? again.
        const n = B8.s(this.top());
        if (n === 0) {
          if (!this.haveKey()) this.noKey();
          this.pop(); this.push(this.key());
        } else if (n > 0) {
          if (this.haveKey()) { this.waitAt = -1; this.pop(); this.push(this.key()); }
          else if (!this.live) { this.pop(); this.push(0); }
          else {
            const t = this.now();
            if (this.waitAt !== this.at) { this.waitAt = this.at; this.waitUntil = t + n; }
            if (t < this.waitUntil) throw WAIT;
            this.waitAt = -1; this.pop(); this.push(0);
          }
        } else {
          const l = this.readline(-n);
          this.pop(); this.push(l);
        }
        break;
      }
      case 96: {                                                                  // `
        if (isHex(this.m[this.ip])) {
          a = this.pop();
          for (;;) {
            const h = this.m[this.ip];
            if (!isHex(h)) break;
            this.ip++;
            const l = this.m[this.ip];
            if (!isHex(l)) break;
            this.ip++;
            this.m[a & 0xFFFF] = parseInt(String.fromCharCode(h, l), 16); a++;
          }
          this.m[a & 0xFFFF] = this.retbyte;
          this.push(a);
        } else { this.why = 'mc'; throw STOP; }    // no CPU here to run machine code
        break;
      }
    }
  }
}

// In play mode (test_games.py's Play), a ? with no keys left ends the run.
class Play extends B8 {
  step() {
    if (this.m[this.ip] === 63 && !this.inp.length) { this.why = 'input'; throw STOP; }
    super.step();
  }
}

if (typeof module !== 'undefined') module.exports = { B8, Play };
