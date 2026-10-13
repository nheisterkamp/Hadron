// Every tool gets the same panel. The tools file still accepts the fex flavor, but no
// row depends on which tool or fallback a game runs under.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: fex.js <emit>'); process.exit(2); }

const AVX = 'Advertise AVX2 to Rosetta';

const shape = ns => JSON.stringify(ns.map(x => [x.type, x.props.label || '',
  (x.props.rgOptions || []).map(o => o.data)]));

let failed = 0;
for (const form of Object.keys(FORMS)) {
  for (const options of ['', 'NOTPROTON_GRAPHICS=wined3d']) {
    const want = shape(walk(panel(emit, form).render({ details: details(options + ' %command%') })));
    for (const fallback of ['notproton', 'notproton-wine', 'notproton-fex']) {
      const t = runner(`${form}, ${options || 'default'}, fallback ${fallback}`);
      const { render: P } = panel(emit, form, undefined, { fallback });
      for (const tool of ['', 'notproton', 'notproton-wine', 'notproton-fex']) {
        const r = walk(P({ details: details(options + ' %command%', { strCompatToolName: tool }) }));
        t.ok(shape(r) === want, `tool ${JSON.stringify(tool)} renders the same rows`);
        t.ok(r.some(x => x.type === 'Toggle' && x.props.label === AVX), `tool ${JSON.stringify(tool)} keeps the AVX2 row`);
      }
      failed += t.failed;
    }
  }
}
console.log(failed ? `\n${failed} failure(s)` : '\nevery tool gets the same panel');
process.exit(failed ? 1 : 0);
