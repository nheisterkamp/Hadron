// A FEX tool runs arm64 Wine, which has DXVK 1.10 and WineD3D only and never runs under
// Rosetta. Its panel offers just those two, shows DXMT, D3DMetal and DXVK 3.1 as the DXVK
// 1.10 the game gets, and drops the AVX2 row. A Rosetta tool keeps every row.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: fex.js <emit>'); process.exit(2); }

const AVX = 'Advertise AVX2 to Rosetta';

// The hook passes only FEX tools; ROSETTA stands for a Rosetta tool next to them.
const FEX_TOOLS = ['hadron-proton-wine-11.19-fex'];
const ROSETTA = 'hadron-proton-wine-11.19';
const ALL = ['dxmt', 'd3dmetal', 'dxvk', 'dxvk1', 'wined3d'];

let failed = 0;
for (const form of Object.keys(FORMS)) {
  for (const fex of [false, true]) {
    const { render: P, written } = panel(emit, form, undefined, { fexTools: FEX_TOOLS });
    const t = runner(`${form}, ${fex ? 'FEX' : 'Rosetta'}`);
    const tool = fex ? FEX_TOOLS[0] : ROSETTA;
    const nodes = opts =>
      walk(P({ details: details(opts + ' %command%', { strCompatToolName: tool }) }));
    const toggles = ns => ns.filter(x => x.type === 'Toggle').map(x => x.props.label);
    const dropdown = ns => ns.find(x => x.type === 'Dropdown');
    const backends = ns => dropdown(ns).props.rgOptions.map(o => o.data);

    let r = nodes('');
    const want = fex ? ['dxvk1', 'wined3d'] : ALL;
    t.ok(backends(r).join() === want.join(), `offers ${want} (${backends(r)})`);
    t.ok(toggles(r).includes(AVX) === !fex, `the AVX2 row is ${fex ? 'hidden' : 'shown'}`);
    t.ok(dropdown(r).props.selectedOption === (fex ? 'dxvk1' : 'dxmt'),
         `the default shows as ${fex ? 'DXVK 1.10' : 'DXMT'}`);
    t.ok(toggles(r).includes('DLSS') === !fex, `the DXMT DLSS row is ${fex ? 'hidden' : 'shown'}`);

    for (const b of ['dxmt', 'd3dmetal', 'dxvk']) {
      const picked = dropdown(nodes('HADRON_GRAPHICS=' + b)).props.selectedOption;
      t.ok(picked === (fex ? 'dxvk1' : b), `a game set to ${b} shows ${picked}`);
    }
    r = nodes('HADRON_GRAPHICS=wined3d');
    t.ok(dropdown(r).props.selectedOption === 'wined3d', 'WineD3D shows as itself');
    for (const l of ['Metal HUD', 'High Resolution', 'cnc-ddraw (old DirectDraw games)'])
      t.ok(toggles(r).includes(l), `${l} stays`);

    // Only picking a FEX tool clears hidden values.
    written.length = 0;
    r = nodes('ROSETTA_ADVERTISE_AVX=1 HADRON_GRAPHICS=dxvk');
    r.find(x => x.type === 'Toggle' && x.props.label === 'Metal HUD').props.onChange(true);
    t.ok(written[written.length - 1].opts.includes('ROSETTA_ADVERTISE_AVX=1'),
         'editing another row keeps the AVX2 value');
    failed += t.failed;
  }

  // A game with no tool name runs under the fallback tool.
  for (const first of [false, true]) {
    const fallback = first ? FEX_TOOLS[0] : ROSETTA;
    const { render: P } = panel(emit, form, undefined, { fallback, fexTools: FEX_TOOLS });
    const t = runner(`${form}, unmapped, fallback ${fallback}`);
    const r = walk(P({ details: details('', { strCompatToolName: '' }) }));
    const offered = r.find(x => x.type === 'Dropdown').props.rgOptions.map(o => o.data);
    t.ok(offered.includes('dxmt') === !first, `DXMT is ${first ? 'not ' : ''}offered (${offered})`);
    failed += t.failed;
  }

  // A tool whose name only starts like a FEX tool is not one.
  {
    const { render: L } = panel(emit, form, undefined, { fexTools: FEX_TOOLS });
    const t = runner(`${form}, prefix`);
    const r = walk(L({ details: details('', { strCompatToolName: 'hadron-proton-wine-11.19-fe' }) }));
    t.ok(r.find(x => x.type === 'Dropdown').props.rgOptions.some(o => o.data === 'dxmt'),
         'a tool whose name prefixes a FEX tool keeps the Rosetta options');
    failed += t.failed;
  }
}

{
  const { pick, written } = panel(emit, 'component', undefined, { fexTools: FEX_TOOLS });
  const t = runner('component, picking a tool');
  const choose = (opts, tool) => {
    written.length = 0;
    pick(details(opts), tool);
    return written.length ? written[written.length - 1].opts : null;
  };
  const all = 'WINEDEBUG=-all HADRON_GRAPHICS=d3dmetal D3DM_ENABLE_METALFX=1 MTL_HUD_ENABLED=1 ' +
              "ROSETTA_ADVERTISE_AVX=0 DXMT_CONFIG='a;b' %command% -novid";
  const r = choose(all, FEX_TOOLS[0]);
  t.ok(r === "WINEDEBUG=-all MTL_HUD_ENABLED=1 DXMT_CONFIG='a;b' %command% -novid",
       `picking FEX drops only the D3DMetal and Rosetta entries (${r})`);
  t.ok(choose(all, ROSETTA) === null, 'picking a Rosetta tool writes nothing');
  t.ok(choose('D3DM_lower=1 %command%', FEX_TOOLS[0]) === null,
       'names the launch script does not forward are left alone');
  for (const o of ['>D3DM_LOG=1 %command%', "X=$'a\\'b D3DM_Y=1 c' %command%",
                   'wrapper <(x) D3DM_Y=1 %command%', 'D3DM_Y=1 \\\n%command%'])
    t.ok(choose(o, FEX_TOOLS[0]) === null, `text the parser does not model is left alone (${o})`);
  t.ok(choose('HADRON_GRAPHICS=dxmt %command%', FEX_TOOLS[0]) === null,
       'another backend is not a reason to write');
  t.ok(choose('-novid HADRON_GRAPHICS=d3dmetal', FEX_TOOLS[0]) === null,
       'text after the game, not set before %command%, is left alone');
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nFEX offers what arm64 Wine runs, Rosetta keeps everything');
process.exit(failed ? 1 : 0);
