// Tests for the web player's page, web/b8script.html, in Chromium (Playwright).
//
// usage: node test_page.js [SHOTDIR]     (with SHOTDIR, screenshots go there)
//
// The interpreter itself is checked against ref.py by test_web.py; this checks
// what the page adds: the screen (its rows must be the program's output lines),
// the keyboard (a computer's keys, a phone's text input, the on-screen keys),
// n?'s clock, the break key, checked reports, Edit and the menu.
'use strict';
const path = require('path');
const { chromium, devices } = require('playwright');
const { B8 } = require(path.join(__dirname, '..', '..', 'web', 'b8s.js'));
const fs = require('fs');

const ROOT = path.join(__dirname, '..', '..');
const URL = 'file://' + path.join(ROOT, 'web', 'b8script.html');
const shots = process.argv[2];
let bad = 0;
function ok(what, cond, extra) {
  bad += !cond;
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${what}${!cond && extra !== undefined ? '\n      ' + extra : ''}`);
}

// What a program prints with these keys (the core in test mode, as test_web.py checks it).
function expected(file, keys) {
  const b = new B8(fs.readFileSync(path.join(ROOT, file)), { inp: Buffer.from(keys) });
  b.run(400000000);
  return Buffer.from(b.out).toString('latin1');
}
const LINE = '-10? 13\'10\' :,#" "$1+:,#" "$1+,# ';   // reads a line, prints its first three codes
const rows = s => s.split('\r\n').map(l => l.replace(/\s+$/, ''));

async function screen(page) {
  return (await page.$eval('#screen', e => e.textContent)).split('\n').map(l => l.replace(/[\s ]+$/, ''));
}
// the whole 80 x 24 screen shows, inside its box, and the page doesn't scroll sideways
async function fits(p, tag) {
  const f = await p.evaluate(() => {
    const s = document.getElementById('screen').getBoundingClientRect(), w = document.getElementById('wrap').getBoundingClientRect();
    return { in: s.top >= w.top - 1 && s.bottom <= w.bottom + 1 && s.left >= w.left - 1 && s.right <= w.right + 1,
      fs: parseFloat(getComputedStyle(document.getElementById('screen')).fontSize),
      page: document.documentElement.scrollWidth <= innerWidth && document.documentElement.scrollHeight <= innerHeight + 1 };
  });
  ok(`${tag}: 80 x 24 fits (font ${f.fs}px), the page doesn't scroll`, f.in && f.page, JSON.stringify(f));
}
async function status(page) { return page.$eval('#st', e => e.textContent); }
async function until(page, re, ms = 20000) {
  await page.waitForFunction(r => new RegExp(r).test(document.getElementById('st').textContent), re.source, { timeout: ms });
}
async function runSrc(page, src) {
  await page.click('#edit');
  await page.fill('#src', src);
  await page.click('#erun');
}

(async () => {
  const browser = await chromium.launch();

  // ------------------------------------------------------------ a computer
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  await page.goto(URL);
  const n = await page.$$eval('#prog option', o => o.length);
  ok(`the menu holds every program (${n})`, n === 5 + 21 + 10 + 10 + 11 + 1);

  await page.selectOption('#prog', 'programs/MANDEL.B8S');
  await page.click('#run');
  await until(page, /^Ended/);
  const want = rows(expected('programs/MANDEL.B8S', ''));
  let got = await screen(page);
  ok('MANDEL: the screen shows its picture', JSON.stringify(got.slice(0, 22)) === JSON.stringify(want.slice(0, 22)),
     JSON.stringify(got.slice(0, 3)));
  if (shots) await page.screenshot({ path: path.join(shots, 'desktop-mandel.png') });

  await page.selectOption('#prog', 'programs/PI.B8S');
  await page.click('#run');
  await until(page, /Waiting/);
  await page.keyboard.type('50');
  await page.keyboard.press('Enter');
  await until(page, /^Ended/);
  got = await screen(page);
  const pi = rows(expected('programs/PI.B8S', '50\r'));
  ok('PI: typed digits and Return; 50 digits shown', JSON.stringify(got.slice(0, pi.length - 1)) === JSON.stringify(pi.slice(0, -1)),
     JSON.stringify(got.slice(0, 4)) + ' / ' + JSON.stringify(pi.slice(0, 4)));

  // a line read with -n?: Backspace takes a typo back, and the echo shows it
  await runSrc(page, LINE);
  await until(page, /Waiting for a line/);
  await page.keyboard.type('5O');
  await page.keyboard.press('Backspace');
  await page.keyboard.type('0');
  await page.keyboard.press('Enter');
  await until(page, /^Ended/, 2000);
  got = await screen(page);
  ok('-n?: typed, Backspace, Return', got[0] === '50' && got[1] === '53 48 13', got.slice(0, 2).join('|'));

  // n? waits by the clock, and a key ends the wait
  await runSrc(page, '"a"$ 400?; "b"$ 3000? # "c"$');
  const t0 = Date.now();
  await page.waitForFunction(() => document.getElementById('screen').textContent.includes('ab'));
  const t1 = Date.now() - t0;
  ok(`400? waits about 400 ms (${t1} ms)`, t1 >= 350 && t1 < 900);
  await page.keyboard.press('x');
  await until(page, /^Ended/, 2000);
  got = await screen(page);
  ok('a key ends a wait and is its result', got[0] === 'ab120c', got[0]);

  // arrows send Esc [ letter; Ctrl-letters are control keys
  await runSrc(page, '0?# " "$ 0?# " "$ 0?# " "$ 0?#');
  await page.keyboard.press('ArrowUp');
  await page.keyboard.press('Control+b');
  await until(page, /^Ended/, 2000);
  got = await screen(page);
  ok('ArrowUp sends 27 91 65, Ctrl-B 2', got[0] === '27 91 65 2', (await status(page)) + ' | ' + got.slice(0, 3).join('|'));

  // the break key: unchecked stops quietly, checked reports B
  if ((await page.$eval('#chk', e => e.classList.contains('on')))) await page.click('#chk');
  await runSrc(page, '"x"$ 1(1)');
  await page.waitForTimeout(300);
  ok('a busy loop runs until stopped', /^Running/.test(await status(page)));
  await page.keyboard.press('Control+c');
  await until(page, /Ctrl-C/, 2000);
  ok('Ctrl-C stops it (unchecked: no report)', !(await screen(page)).join('').includes('Err'));
  await page.click('#chk');
  await runSrc(page, '"x"$ 1(1)');
  await page.waitForTimeout(200);
  await page.click('#stop');
  await until(page, /error B/, 2000);
  got = await screen(page);
  ok('Stop in a checked run: Err B with the place', /^Err B @ 1,[89]$/.test(got[1]), got.slice(0, 4).join('|'));

  // a checked error, as ref.py reports it
  await runSrc(page, '1 2\n3 0/');
  await until(page, /error Z/);
  got = await screen(page);
  ok('a checked error: the report', got.slice(1, 4).join('|') === 'Err Z @ 2,4|D:4: 1 2 3 0|R:0', got.slice(0, 4).join('|'));

  // machine code can't run, and says so
  await runSrc(page, '16_:x! `C9 ; x@`');
  await until(page, /machine code/);
  ok('executing machine code stops with a message', true);

  // pasting types the text: a BASIC program into Tiny BASIC
  await page.selectOption('#prog', 'programs/TINYBAS.B8S');
  await page.click('#run');
  await page.waitForTimeout(200);
  await page.evaluate(() => {
    const d = new DataTransfer(); d.setData('text/plain', '10 PRINT "HI"\n20 PRINT 6*7\nRUN\n');
    document.dispatchEvent(new ClipboardEvent('paste', { clipboardData: d, bubbles: true }));
  });
  await page.waitForFunction(() => document.getElementById('screen').textContent.includes('42'), null, { timeout: 5000 });
  got = await screen(page);
  ok('paste: a BASIC program typed into Tiny BASIC runs', got.includes('HI') && got.includes('42'), got.join('|'));
  await page.keyboard.press('Control+c');

  // a real-time game takes keys while it runs
  await page.selectOption('#prog', 'games/BREAKOUT.B8S');
  await page.click('#run');
  await page.waitForTimeout(500);
  await page.keyboard.press('Space');
  for (let i = 0; i < 8; i++) { await page.keyboard.press('d'); await page.waitForTimeout(40); }
  await page.waitForTimeout(500);
  ok('BREAKOUT runs and takes keys', /^Running/.test(await status(page)), await status(page));
  if (shots) await page.screenshot({ path: path.join(shots, 'desktop-breakout.png') });
  await page.keyboard.press('Control+c');
  ok('no errors in the page', errors.length === 0, errors.join(' | '));
  await page.close();

  // ------------------------------------------------------------ a phone
  for (const [dev, land] of [['Pixel 7', false], ['Pixel 7', true], ['iPhone 13', false]]) {
    const d = { ...devices[dev] };
    if (land) d.viewport = { width: d.viewport.height, height: d.viewport.width };
    const ctx = await browser.newContext(d);
    const p = await ctx.newPage();
    const errs = [];
    p.on('pageerror', e => errs.push(String(e)));
    await p.goto(URL);
    const tag = `${dev}${land ? ' sideways' : ''}`;
    ok(`${tag}: the on-screen keys show`, await p.$eval('#keys', e => getComputedStyle(e).display !== 'none'));
    await fits(p, tag);

    // a phone's keyboard: text arrives by input events, keydown says 'Unidentified'
    await runSrc(p, LINE);
    await until(p, /Waiting for a line/);
    await p.evaluate(() => {
      const k = document.getElementById('kbd');
      const typeText = (v, inputType) => {
        k.dispatchEvent(new KeyboardEvent('keydown', { key: 'Unidentified', keyCode: 229, bubbles: true }));
        k.value = v; k.dispatchEvent(new InputEvent('input', { inputType, bubbles: true }));
      };
      typeText('  ' + '3', 'insertText');
      typeText('  ' + '9', 'insertText');
      typeText(' ', 'deleteContentBackward');        // Backspace takes the 9 back
      typeText('  ' + '0', 'insertText');
    });
    await p.tap('#keys button[data-key="13"]');           // the on-screen Return
    await until(p, /^Ended/);
    const g = await screen(p);
    ok(`${tag}: typed by input events (Backspace too) and the on-screen Return`, g[0] === '30' && g[1] === '51 48 13', g.slice(0, 2).join('|'));

    // the pad: its keys reach the program
    await p.tap('#padb');
    ok(`${tag}: Pad shows the game keys`, await p.$eval('#mid .cross', e => getComputedStyle(e).display !== 'none'));
    await p.selectOption('#prog', 'games/G2048.B8S');          // a longer description
    await p.waitForTimeout(100);
    await fits(p, tag + ' with the pad');
    await runSrc(p, '0?# " "$ 0?# " "$ 0?#');
    await p.tap('#mid button[data-key="119"]');
    await p.tap('#mid button.space');
    await p.tap('#ctrlb');
    await p.evaluate(() => {
      const k = document.getElementById('kbd');
      k.value = '  b'; k.dispatchEvent(new InputEvent('input', { inputType: 'insertText', bubbles: true }));
    });
    await until(p, /^Ended/, 3000);
    ok(`${tag}: pad w, Space, and Ctrl then b`, (await screen(p))[0] === '119 32 2', (await screen(p))[0]);
    if (shots) {
      await p.selectOption('#prog', 'games/G2048.B8S');
      await p.tap('#run');
      await p.waitForTimeout(600);
      await p.screenshot({ path: path.join(shots, `${dev.replace(' ', '')}${land ? '-side' : ''}.png`) });
      await p.tap('#keys button[data-act="brk"]');
    }
    ok(`${tag}: no errors in the page`, errs.length === 0, errs.join(' | '));
    await ctx.close();
  }

  await browser.close();
  console.log('page:', bad ? `${bad} FAILED` : 'all pass');
  process.exit(bad ? 1 : 0);
})();
