const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('BlissMixerLab/strings.txt', 'utf8');
const match = source.match(/^BLISSMIXERLAB_ARTIST_REPEAT_MODE_DESC\n\tEN\t([^\n]*)\n\tDE\t([^\n]*)/m);
assert.ok(match, 'artist identity help has both translations');
for (const [text, options] of [[match[1], ['Any shared credited artist', 'Primary artist only', 'Exact Bliss artist credit']], [match[2], ['Jeder gemeinsame beteiligte Interpret', 'Nur Hauptinterpret', 'Exakte Bliss-Interpretenangabe']]]) {
  for (const option of options) assert.ok(text.includes('<b>' + option + ':</b>'), option + ' is described');
  for (const option of options.slice(1)) assert.ok(text.includes('<br/><br/><b>' + option + ':</b>'), option + ' begins a separate paragraph');
  assert.doesNotMatch(text, /previous default|früher|bisherig/i);
}
console.log('Bliss Mixer Lab choice explanations: ok');
