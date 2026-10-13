// What the panel renders, checked against both forms of the one payload.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: behavior.js <emit>'); process.exit(2); }

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const nodes = opts => walk(P({ details: details(opts + ' %command%') }));
  const toggles = ns => ns.filter(x => x.type === 'Toggle').map(x => x.props.label);
  const sections = ns => ns.filter(x => x.type === 'Section').map(x => x.props.label.split(' ')[0]);
  const last = () => (written.length ? written[written.length - 1].opts : '');

  t.ok(P({ details: details('', { vecPlatforms: ['osx'], strCompatToolName: '' }) }) === null,
       'a mac build with nothing pinned renders no panel');
  t.ok(P({ details: details('', { unAppID: 3420702832, vecPlatforms: ['osx'],
                                  strCompatToolName: '' }) }) !== null,
       'a shortcut renders the panel before a tool name reaches the page');

  let r = nodes('');
  t.ok(toggles(r).length === 5 && sections(r).length === 3, 'the default shows five toggles in three sections');
  t.ok(!toggles(r).includes('MSync'), 'there is no MSync row, Wine 11.15 has no msync');
  t.ok(r.filter(x => x.type === 'Dropdown').length === 2, 'two dropdowns');
  t.ok(!('label' in r.find(x => x.type === 'Dropdown').props), 'the graphics dropdown carries no label column');
  t.ok(r.find(x => x.type === 'Dropdown').props.selectedOption === 'dxmt', 'nothing set reads as DXMT');

  for (const o of ['', 'NOTPROTON_GRAPHICS=dxmt', 'NOTPROTON_GRAPHICS=']) {
    r = nodes(o);
    t.ok(toggles(r).filter(l => l === 'DLSS').length === 1 && sections(r).includes('MetalFX'),
         `${JSON.stringify(o)} keeps DLSS and MetalFX`);
  }
  r = nodes('NOTPROTON_GRAPHICS=wined3d');
  t.ok(!toggles(r).includes('DLSS') && !sections(r).includes('MetalFX') && toggles(r).length === 4,
       'wined3d hides DLSS and MetalFX, keeps the rest');
  // The run script overlays DXMT only for dxmt, so anything else is not DXMT either.
  r = nodes('NOTPROTON_GRAPHICS=other');
  t.ok(!toggles(r).includes('DLSS') && !sections(r).includes('MetalFX'),
       'an unknown value does not show the DXMT rows');
  t.ok(r.find(x => x.type === 'Dropdown').props.selectedOption === 'other',
       'an unknown value is shown as it is, not as a choice');

  written.length = 0;
  nodes('').find(x => x.props.label === 'DLSS').props.onChange(true);
  t.ok(last().includes('DXMT_ENABLE_NVEXT=1'), `DLSS writes DXMT_ENABLE_NVEXT (${last()})`);
  t.ok(nodes('DXMT_ENABLE_NVEXT=1').find(x => x.props.label === 'DLSS').props.checked === true,
       'the DLSS toggle reads as on from its argument');

  t.ok(nodes('NOTPROTON_GRAPHICS=wined3d').find(x => x.type === 'Dropdown').props.selectedOption === 'wined3d',
       'the graphics dropdown reflects the current value');
  written.length = 0;
  nodes('').find(x => x.type === 'Dropdown').props.onChange({ data: 'wined3d' });
  t.ok(last().trim() === 'NOTPROTON_GRAPHICS=wined3d %command%', `picking WineD3D writes it (${last()})`);
  written.length = 0;
  nodes('NOTPROTON_GRAPHICS=wined3d').find(x => x.type === 'Dropdown').props.onChange({ data: 'dxmt' });
  t.ok(last() === '', `picking DXMT clears the variable, it is the default (${last()})`);

  t.ok(nodes('MTL_HUD_ENABLED=1').find(x => x.props.label === 'Metal HUD').props.checked === true,
       'a toggle reads as on from its argument');

  nodes('').filter(x => x.type === 'Dropdown')[1].props.onChange({ data: '2.0' });
  t.ok(last().includes('metalSpatialUpscaleFactor=2.0'), 'the upscaler writes its factor');

  // The section names the factor, so a label promising a resolution to go and set in
  // the game is the wording this replaced.
  const upscaler = nodes('').find(x => x.type === 'Section' &&
    x.props.label.indexOf('MetalFX') === 0);
  t.ok(/Samples from the resolution the game is set to/.test(upscaler.props.label),
       'the upscaler section says where it samples from');
  const factors = nodes('').filter(x => x.type === 'Dropdown')[1]
    .props.rgOptions.map(o => o.label);
  t.ok(factors.join(',') === 'Off,1.5x,1.72x,2x,3x', `the factors name themselves (${factors.join(',')})`);

  // The value is what the run script reads from NOTPROTON_GRAPHICS.
  const choices = nodes('').find(x => x.type === 'Dropdown').props.rgOptions;
  t.ok(choices.map(o => o.label).join(',') === "DXMT,WineD3D (Wine's own Direct3D)",
       `the choices name themselves (${choices.map(o => o.label).join(',')})`);
  t.ok(choices.map(o => o.data).join(',') === 'dxmt,wined3d', 'the values stay as the run script reads them');

  const root = P({ details: details('') });
  t.ok(root.props.className === 'NPHadronPanel', 'the panel root carries its own class');
  const classes = nodes('').filter(x => x.type === 'Toggle').map(x => x.props.className);
  t.ok(classes.length === 5 && classes.every(c => c === 'NPHadronRow'), 'every checkbox carries the row class');
  const raw = o => nodes(o).find(x => x.props.label === 'Let games read controllers directly');
  t.ok(sections(nodes('')).includes('Controllers') && raw('').props.checked === false,
       'controller hiding is on unless the game says otherwise');
  t.ok(nodes('').some(x => x.type === 'Section' && x.props.label === 'Controllers (May break Steam Input. Not recommended)'),
       'the controller section warns what the row changes');
  written.length = 0;
  raw('').props.onChange(true);
  t.ok(last().trim() === 'NOTPROTON_RAW_CONTROLLERS=1 %command%', `the controller row writes its flag (${last()})`);
  t.ok(raw('NOTPROTON_RAW_CONTROLLERS=1').props.checked === true, 'the controller row reads its flag');
  written.length = 0;
  raw('NOTPROTON_RAW_CONTROLLERS=1 WINEDEBUG=-all').props.onChange(false);
  t.ok(last().trim() === 'WINEDEBUG=-all %command%', `turning the controller row off removes its flag (${last()})`);
  const css = nodes('').filter(x => x.type === 'style');
  t.ok(css.length === 1 && css[0].props.children.includes('.NPHadronPanel .NPHadronRow{'),
       'the panel carries one stylesheet defining the row rule');

  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nboth shapes pass');
process.exit(failed ? 1 : 0);
