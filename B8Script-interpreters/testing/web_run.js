// Runs web/b8s.js for test_web.py: one JSON request a line on stdin, one JSON
// answer a line on stdout. A request: {prog, inp (both base64), checked, play,
// steps}. An answer: {out (base64), error, why, ds (the data stack's depth)}.
'use strict';
const path = require('path');
const { B8, Play } = require(path.join(__dirname, '..', '..', 'web', 'b8s.js'));
const rl = require('readline').createInterface({ input: process.stdin });
rl.on('line', line => {
  const q = JSON.parse(line);
  const K = q.play ? Play : B8;
  const b = new K(Buffer.from(q.prog, 'base64'), { inp: Buffer.from(q.inp, 'base64'), checked: q.checked });
  b.run(q.steps);
  process.stdout.write(JSON.stringify({ out: Buffer.from(b.out).toString('base64'), error: b.error, why: b.why, ds: b.ds.length }) + '\n');
});
