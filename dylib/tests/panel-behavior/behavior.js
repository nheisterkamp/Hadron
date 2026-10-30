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
  t.ok(toggles(r).length === 6 && sections(r).length === 3, 'the default shows six toggles in three sections');
  t.ok(!toggles(r).includes('MSync'), 'there is no MSync row, Wine 11.15 has no msync');
  t.ok(r.filter(x => x.type === 'Dropdown').length === 2, 'two dropdowns');
  t.ok(!('label' in r.find(x => x.type === 'Dropdown').props), 'the graphics dropdown carries no label column');
  t.ok(r.find(x => x.type === 'Dropdown').props.selectedOption === 'dxmt', 'nothing set reads as DXMT');

  for (const o of ['', 'HADRON_GRAPHICS=dxmt', 'HADRON_GRAPHICS=']) {
    r = nodes(o);
    t.ok(toggles(r).filter(l => l === 'DLSS').length === 1 && sections(r).includes('MetalFX'),
         `${JSON.stringify(o)} keeps DLSS and MetalFX`);
  }
  for (const b of ['d3dmetal', 'dxvk', 'dxvk1', 'wined3d']) {
    r = nodes('HADRON_GRAPHICS=' + b);
    t.ok(!toggles(r).includes('DLSS') && !sections(r).includes('MetalFX') && toggles(r).length === 5,
         `${b} hides DLSS and MetalFX, keeps the rest`);
    t.ok(r.find(x => x.type === 'Dropdown').props.selectedOption === b, `${b} reads as itself`);
  }
  // The run script overlays DXMT only for dxmt, so anything else is not DXMT either.
  r = nodes('HADRON_GRAPHICS=other');
  t.ok(!toggles(r).includes('DLSS') && !sections(r).includes('MetalFX'),
       'an unknown value does not show the DXMT rows');
  t.ok(r.find(x => x.type === 'Dropdown').props.selectedOption === 'other',
       'an unknown value is shown as it is, not as a choice');

  written.length = 0;
  nodes('').find(x => x.props.label === 'DLSS').props.onChange(true);
  t.ok(last().includes('DXMT_ENABLE_NVEXT=1'), `DLSS writes DXMT_ENABLE_NVEXT (${last()})`);
  t.ok(nodes('DXMT_ENABLE_NVEXT=1').find(x => x.props.label === 'DLSS').props.checked === true,
       'the DLSS toggle reads as on from its argument');

  t.ok(nodes('HADRON_GRAPHICS=wined3d').find(x => x.type === 'Dropdown').props.selectedOption === 'wined3d',
       'the graphics dropdown reflects the current value');
  written.length = 0;
  nodes('').find(x => x.type === 'Dropdown').props.onChange({ data: 'wined3d' });
  t.ok(last().trim() === 'HADRON_GRAPHICS=wined3d %command%', `picking WineD3D writes it (${last()})`);
  written.length = 0;
  nodes('HADRON_GRAPHICS=wined3d').find(x => x.type === 'Dropdown').props.onChange({ data: 'dxmt' });
  t.ok(last() === '', `picking DXMT clears the variable, it is the default (${last()})`);
  for (const b of ['d3dmetal', 'dxvk', 'dxvk1']) {
    written.length = 0;
    nodes('DXMT_ENABLE_NVEXT=1').find(x => x.type === 'Dropdown').props.onChange({ data: b });
    t.ok(last().trim() === `HADRON_GRAPHICS=${b} %command%`, `picking ${b} writes it and drops DXMT's DLSS (${last()})`);
  }

  const ddraw = o => nodes(o).find(x => x.props.label === 'cnc-ddraw (old DirectDraw games)');
  t.ok(ddraw('').props.checked === false, 'cnc-ddraw is off unless the game says otherwise');
  t.ok(ddraw('HADRON_DDRAW=cnc-ddraw').props.checked === true, 'cnc-ddraw reads its value');
  t.ok(ddraw('HADRON_DDRAW=1').props.checked === false, 'only cnc-ddraw turns the row on');
  t.ok(ddraw('HADRON_GRAPHICS=wined3d') !== undefined, 'cnc-ddraw is offered with every backend');
  written.length = 0;
  ddraw('').props.onChange(true);
  t.ok(last().trim() === 'HADRON_DDRAW=cnc-ddraw %command%', `turning cnc-ddraw on writes it (${last()})`);
  written.length = 0;
  ddraw('HADRON_DDRAW=cnc-ddraw WINEDEBUG=-all').props.onChange(false);
  t.ok(last().trim() === 'WINEDEBUG=-all %command%', `turning cnc-ddraw off removes it (${last()})`);

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

  // The value is what the run script reads from HADRON_GRAPHICS.
  const choices = nodes('').find(x => x.type === 'Dropdown').props.rgOptions;
  t.ok(choices.map(o => o.label).join(',') === "DXMT (Metal),D3DMetal (CrossOver Wine),DXVK 3.1,DXVK 1.10,WineD3D (Wine's own)",
       `the choices name themselves (${choices.map(o => o.label).join(',')})`);
  t.ok(choices.map(o => o.data).join(',') === 'dxmt,d3dmetal,dxvk,dxvk1,wined3d', 'the values stay as the run script reads them');

  const root = P({ details: details('') });
  t.ok(root.props.className === 'NPHadronPanel', 'the panel root carries its own class');
  const classes = nodes('').filter(x => x.type === 'Toggle').map(x => x.props.className);
  t.ok(classes.length === 6 && classes.every(c => c === 'NPHadronRow'), 'every checkbox carries the row class');
  const raw = o => nodes(o).find(x => x.props.label === 'Let games read controllers directly (May break Steam Input. Not recommended)');
  t.ok(sections(nodes('')).includes('Controllers') && raw('').props.checked === false,
       'controller hiding is on unless the game says otherwise');
  written.length = 0;
  raw('').props.onChange(true);
  t.ok(last().trim() === 'HADRON_RAW_CONTROLLERS=1 %command%', `the controller row writes its flag (${last()})`);
  t.ok(raw('HADRON_RAW_CONTROLLERS=1').props.checked === true, 'the controller row reads its flag');
  written.length = 0;
  raw('HADRON_RAW_CONTROLLERS=1 WINEDEBUG=-all').props.onChange(false);
  t.ok(last().trim() === 'WINEDEBUG=-all %command%', `turning the controller row off removes its flag (${last()})`);
  const css = nodes('').filter(x => x.type === 'style');
  t.ok(css.length === 1 && css[0].props.children.includes('.NPHadronPanel .NPHadronRow{'),
       'the panel carries one stylesheet defining the row rule');
  t.ok(css[0].props.children.includes('.NPHadronPanel .NPHadronRowDesc>:last-child{flex-basis:100%}'),
       'and the rule that drops a description onto its own line');

  const FEATS = JSON.stringify([
    { k: 'HADRON_ALPHA', l: 'Alpha', on: '1', off: '', dep: '', d: '' },
    { k: 'HADRON_BETA', l: 'Beta', on: '1', off: '0', dep: '', d: 'Why Beta.' },
    { k: 'HADRON_BETA_SUB', l: 'Beta: extra', on: '1', off: '0',
      dep: 'HADRON_BETA', d: '' },
  ]).replace(/"(\w+)":/g, '$1:');

  t.ok(!sections(nodes('')).includes('Developer'),
       'no plugins means no Developer section');
  // rows.length && <jsx> puts a stray "0" on the page when there are no rows.
  const hasZero = n => {
    if (n === 0) return true;
    if (!n || typeof n !== 'object') return false;
    if (Array.isArray(n)) return n.some(hasZero);
    if (typeof n.type === 'function') return hasZero(n.type(n.props));
    return !!(n.props && n.props.children) && hasZero(n.props.children);
  };
  t.ok(hasZero({ props: { children: [1 && 'x', 0 && 'y'] } }),
       'the stray-zero scanner finds a zero when there is one');
  t.ok(!hasZero(P({ details: details('') })),
       'no plugins renders nothing rather than a literal 0');

  const { render: PF } = panel(emit, form, undefined,
                              { ready: '{"HADRON_ALPHA":0}', feats: FEATS });
  const fnodes = opts => walk(PF({ details: details(opts) }));
  const frows = opts => fnodes(opts).filter(x => x.type === 'Toggle');
  const flabels = opts => frows(opts).map(x => x.props.label);
  const alpha = o => frows(o).find(x => x.props.label.startsWith('Alpha'));

  t.ok(fnodes('').filter(x => x.type === 'Section')
         .some(x => x.props.label === 'Developer'),
       'plugins add a Developer section');
  t.ok(!flabels('').some(l => l.startsWith('Beta:')),
       'a dependent row stays hidden while its parent is off');
  t.ok(flabels('HADRON_BETA=1 %command%').some(l => l.startsWith('Beta:')),
       'a dependent row appears once its parent is on');
  t.ok(!flabels('HADRON_BETA=0 %command%').some(l => l.startsWith('Beta:')),
       'a parent at its off value does not count as on');
  t.ok(alpha('') && alpha('').props.disabled === true,
       'a plugin whose assets are missing renders disabled');
  t.ok(alpha('').props.label.endsWith('(not installed)'),
       'it says why it cannot be used');
  t.ok(alpha('HADRON_ALPHA=1 %command%').props.checked === false,
       'a stale launch option does not show it as on');
  t.ok(frows('').filter(x => x.props.disabled === true).length === 1,
       'only that one is disabled');
  t.ok(frows('').find(x => x.props.label === 'Beta').props.disabled === false,
       'a plugin with no readiness entry stays enabled');
  t.ok(frows('').find(x => x.props.label === 'Beta').props.className === 'NPHadronRow NPHadronRowDesc',
       'a row with a description opts out of the row-direction rule');
  t.ok(frows('').find(x => x.props.label.startsWith('Alpha')).props.className === 'NPHadronRow',
       'a row without one keeps the plain row class');
  t.ok(frows('').find(x => x.props.label === 'Beta').props.description === 'Why Beta.',
       "a plugin's description reaches the row");
  t.ok(frows('').find(x => x.props.label.startsWith('Alpha')).props.description === undefined,
       'a plugin without one passes no description at all');

  const CHAIN = JSON.stringify([
    { k: 'HADRON_BETA', l: 'Beta', on: '1', off: '0', dep: '', d: '' },
    { k: 'HADRON_BETA_SUB', l: 'Beta: extra', on: '1', off: '0',
      dep: 'HADRON_BETA', d: '' },
    { k: 'HADRON_BETA_SUB_SUB', l: 'Beta: more', on: '1', off: '0',
      dep: 'HADRON_BETA_SUB', d: '' },
  ]).replace(/"(\w+)":/g, '$1:');
  const chain = ready => {
    const { render } = panel(emit, form, undefined, { ready, feats: CHAIN });
    return o => walk(render({ details: details(o) }))
      .filter(x => x.type === 'Toggle').map(x => x.props.label);
  };
  t.ok(chain('{}')('HADRON_BETA_SUB=1 HADRON_BETA_SUB_SUB=1 %command%')
         .every(l => !l.startsWith('Beta:')),
       'a row stays hidden while any plugin above it is off');
  t.ok(chain('{}')('HADRON_BETA=1 HADRON_BETA_SUB=1 %command%').includes('Beta: more'),
       'and appears once the whole chain is on');
  t.ok(!chain('{"HADRON_BETA":0}')('HADRON_BETA=1 %command%').includes('Beta: extra'),
       'a parent that is not installed does not count as on');
  const { render: PB } = panel(emit, form, undefined,
                              { ready: '{"HADRON_RAW_CONTROLLERS":0}', feats: CHAIN });
  t.ok(walk(PB({ details: details('') })).filter(x => x.type === 'Toggle')
         .every(x => x.props.disabled !== true),
       'readiness never disables a built-in row');

  const rowless = nodes('').filter(x => x.type === 'div' && typeof x.props.ref === 'function');
  t.ok(rowless.length === 0, 'no prefix row before the page defines one');
  const rowsFor = [];
  global.NPHadronPrefixRow = (e, id) => rowsFor.push(id);
  const prefix = nodes('').filter(x => x.type === 'div' && typeof x.props.ref === 'function');
  if (prefix.length === 1) prefix[0].props.ref({});
  delete global.NPHadronPrefixRow;
  t.ok(prefix.length === 1 && rowsFor[0] === 287700, 'the panel hosts the prefix row for its game');

  const { render: S } = panel(emit, form, undefined, { names: ['o', 't'] });
  const shadowed = walk(S({ details: details('HADRON_GRAPHICS=dxvk1 %command%') }));
  t.ok(JSON.stringify(shadowed) === JSON.stringify(nodes('HADRON_GRAPHICS=dxvk1')),
       'a page naming its runtime and barrel o and t renders the same panel');

  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nboth shapes pass');
process.exit(failed ? 1 : 0);
