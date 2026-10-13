// An option belongs to the graphics path that reads it, and the control for it goes
// away with that path. An argument left behind is one the page can no longer switch
// off, so changing the path has to take it along.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: switching.js <emit>'); process.exit(2); }

const DXMT = ['DXMT_METALFX_SPATIAL_SWAPCHAIN', 'DXMT_CONFIG', 'DXMT_ENABLE_NVEXT'];
const UPSCALED = 'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2.0'
               + ' DXMT_ENABLE_NVEXT=1';

// Whichever choice is made, the arguments the other owns have to be gone and the
// arguments neither owns have to survive.
const CASES = [
  { to: 'wined3d', from: UPSCALED, gone: DXMT, kept: [] },
  { to: 'wined3d', from: 'NOTPROTON_GRAPHICS=dxmt ' + UPSCALED, gone: DXMT, kept: [] },
  { to: 'dxmt',    from: UPSCALED, gone: ['NOTPROTON_GRAPHICS'], kept: DXMT },
  { to: 'dxmt',    from: 'NOTPROTON_GRAPHICS=wined3d', gone: ['NOTPROTON_GRAPHICS'], kept: [] },
  // DXMT is the default, so picking it leaves no variable behind.
  { to: 'dxmt',    from: 'NOTPROTON_GRAPHICS=dxmt ' + UPSCALED, gone: ['NOTPROTON_GRAPHICS'], kept: DXMT },
  { to: 'wined3d', from: 'NOTPROTON_GRAPHICS=wined3d', gone: [], kept: ['NOTPROTON_GRAPHICS=wined3d'] },
  // Stripping arguments by name is the kind of thing that takes neighbours with it.
  { to: 'wined3d',
    from: 'MTL_HUD_ENABLED=1 WINEDEBUG=-all NOTPROTON_RETINA=1 ' + UPSCALED + ' %command% -novid',
    gone: DXMT,
    kept: ['-novid', 'MTL_HUD_ENABLED=1', 'WINEDEBUG=-all', 'NOTPROTON_RETINA=1', '%command%',
           'NOTPROTON_GRAPHICS=wined3d'] },
];

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  for (const c of CASES) {
    written.length = 0;
    const from = c.from.includes('%command%') ? c.from : c.from + ' %command%';
    const nodes = walk(P({ details: details(from) }));
    const backend = nodes.find(x => x.type === 'Dropdown' &&
      (x.props.rgOptions || []).some(o => o.data === 'wined3d'));
    backend.props.onChange({ data: c.to });
    const opts = written.length ? written[written.length - 1].opts : '';
    const stale = c.gone.filter(k => opts.indexOf(k + '=') >= 0);
    const lost = c.kept.filter(k => opts.indexOf(k) < 0);
    t.ok(stale.length === 0 && lost.length === 0,
         `switching to ${c.to} drops ${c.gone.length} and keeps ${c.kept.length}`
         + (stale.length ? ` [stale: ${stale}]` : '') + (lost.length ? ` [lost: ${lost}]` : ''));
  }
  // %command% has to stay last or Steam runs the game before the arguments.
  written.length = 0;
  const nodes = walk(P({ details: details(UPSCALED + ' %command%') }));
  nodes.find(x => x.type === 'Dropdown' &&
    (x.props.rgOptions || []).some(o => o.data === 'wined3d')).props.onChange({ data: 'wined3d' });
  const opts = written[written.length - 1].opts;
  t.ok(opts.trim().endsWith('%command%'), `%command% stays last (${opts})`);
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nno stale arguments, nothing lost');
process.exit(failed ? 1 : 0);
