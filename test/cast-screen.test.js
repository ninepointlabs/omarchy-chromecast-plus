const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const childProcess = require('node:child_process');

const script = path.join(__dirname, '..', 'bin', 'cast-screen.sh');
const fakeHyprctl = path.join(__dirname, 'fixtures', 'fake-hyprctl');

function commandPath(name) {
  const found = childProcess.spawnSync('/bin/sh', ['-c', `command -v ${name}`], { encoding: 'utf8' });
  return found.status === 0 ? found.stdout.trim() : null;
}

const jqPath = commandPath('jq');
const flockPath = commandPath('flock');
const skip = !jqPath || !flockPath ? 'requires jq and flock' : false;

function writeExecutable(file, content) {
  fs.writeFileSync(file, content);
  fs.chmodSync(file, 0o755);
}

function physical(name, extra = {}) {
  return { name, width: 2256, height: 1504, refreshRate: 59.999, scale: 1.5666667, disabled: false, ...extra };
}

function setup(hypr = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'cast-screen-'));
  const fakeBin = path.join(home, 'bin');
  const runtime = path.join(home, 'run');
  fs.mkdirSync(fakeBin);
  fs.mkdirSync(runtime, { mode: 0o700 });
  writeExecutable(path.join(fakeBin, 'hyprctl'), `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(fakeHyprctl)} "$@"\n`);
  writeExecutable(path.join(fakeBin, 'notify-send'), `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(path.join(home, 'notify.log'))}\n`);

  const stateFile = path.join(home, 'hypr.json');
  fs.writeFileSync(stateFile, JSON.stringify({
    lua: true,
    ignoreName: false,
    monitors: [physical('eDP-1')],
    workspaces: [{ id: 1, monitor: 'eDP-1' }, { id: 2, monitor: 'eDP-1' }],
    ...hypr,
  }));

  const env = {
    HOME: home,
    PATH: `${fakeBin}:${path.dirname(jqPath || '/usr/bin/jq')}:/usr/bin:/bin`,
    XDG_RUNTIME_DIR: runtime,
    XDG_CONFIG_HOME: path.join(home, 'config'),
    FAKE_HYPR_STATE: stateFile,
  };

  return {
    home,
    env,
    stateFile: path.join(runtime, 'cast-screen', 'output'),
    run(args, extraEnv = {}) {
      return childProcess.spawnSync('/bin/bash', [script, ...args], {
        env: { ...env, ...extraEnv },
        encoding: 'utf8',
        timeout: 15000,
      });
    },
    hypr() {
      return JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    },
    notifications() {
      try {
        return fs.readFileSync(path.join(home, 'notify.log'), 'utf8');
      } catch {
        return '';
      }
    },
  };
}

function names(hypr) {
  return hypr.monitors.map((m) => m.name).sort();
}

test('on creates CAST, applies the rule via Lua eval, and records state', { skip }, () => {
  const t = setup();
  const result = t.run(['on']);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /TV screen active: CAST 1920x1080@60 scale 1.5/);
  assert.equal(fs.readFileSync(t.stateFile, 'utf8').trim(), 'CAST');
  assert.equal((fs.statSync(path.dirname(t.stateFile)).mode & 0o777), 0o700);
  assert.deepEqual(names(t.hypr()), ['CAST', 'eDP-1']);
  assert.match(t.notifications(), /TV screen on/);
});

test('on detects HEADLESS-N when Hyprland ignores the requested name', { skip }, () => {
  const t = setup({ ignoreName: true, monitors: [physical('eDP-1'), physical('HDMI-A-1')] });
  const result = t.run(['on']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(t.stateFile, 'utf8').trim(), 'HEADLESS-1');
  const headless = t.hypr().monitors.find((m) => m.name === 'HEADLESS-1');
  assert.equal(headless.width, 1920);
  assert.equal(headless.height, 1080);
});

test('on is idempotent and does not create a second output', { skip }, () => {
  const t = setup();
  assert.equal(t.run(['on']).status, 0);
  const second = t.run(['on']);
  assert.equal(second.status, 0, second.stderr);
  assert.match(second.stdout, /already active: CAST/);
  const creates = t.hypr().log.filter((args) => args[0] === 'output' && args[1] === 'create');
  assert.equal(creates.length, 1);
});

test('on honours config file values, env overrides, and moves the workspace', { skip }, () => {
  const t = setup();
  fs.mkdirSync(path.join(t.home, 'config'));
  fs.writeFileSync(path.join(t.home, 'config', 'cast-screen.conf'), '# TV\nRESOLUTION=2560x1440\nCAST_SCREEN_REFRESH="30"\nWORKSPACE=2\n');
  const result = t.run(['on'], { CAST_SCREEN_SCALE: '2' });
  assert.equal(result.status, 0, result.stderr);
  const hypr = t.hypr();
  const cast = hypr.monitors.find((m) => m.name === 'CAST');
  assert.deepEqual([cast.width, cast.height, cast.refreshRate, cast.scale], [2560, 1440, 30, 2]);
  assert.equal(hypr.workspaces.find((w) => w.id === 2).monitor, 'CAST');
});

test('on uses keyword monitor rules on legacy hyprlang configs', { skip }, () => {
  const t = setup({ lua: false });
  const result = t.run(['on']);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(t.hypr().log.some((args) => args[0] === 'keyword' && args[2] === 'CAST,1920x1080@60,auto,1.5'));
});

test('on rejects config values that are not plain numbers without running them', { skip }, () => {
  const t = setup();
  fs.mkdirSync(path.join(t.home, 'config'));
  const marker = path.join(t.home, 'pwned');
  fs.writeFileSync(path.join(t.home, 'config', 'cast-screen.conf'), `RESOLUTION=$(touch ${marker})\n`);
  const result = t.run(['on']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /invalid resolution/);
  assert.equal(fs.existsSync(marker), false);
  assert.deepEqual(names(t.hypr()), ['eDP-1']);
  assert.match(t.notifications(), /TV screen: start failed/);
});

test('off moves workspaces back to the laptop panel before removing the recorded output', { skip }, () => {
  const t = setup({ monitors: [physical('HDMI-A-1'), physical('eDP-1')] });
  assert.equal(t.run(['on'], { CAST_SCREEN_WORKSPACE: '2' }).status, 0);
  const result = t.run(['off']);
  assert.equal(result.status, 0, result.stderr);
  const hypr = t.hypr();
  assert.deepEqual(names(hypr), ['HDMI-A-1', 'eDP-1']);
  const ws = hypr.workspaces.find((w) => w.id === 2);
  assert.equal(ws.monitor, 'eDP-1');
  assert.equal(ws.orphaned, undefined);
  assert.equal(fs.existsSync(t.stateFile), false);
  assert.match(t.notifications(), /TV screen off/);
});

test('off without a state file removes only CAST/HEADLESS-* outputs', { skip }, () => {
  const t = setup({
    monitors: [physical('eDP-1'), physical('HDMI-A-1'), physical('DP-1'), physical('CAST'), physical('HEADLESS-3')],
  });
  const result = t.run(['off']);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(names(t.hypr()), ['DP-1', 'HDMI-A-1', 'eDP-1']);
  const removes = t.hypr().log.filter((args) => args[0] === 'output' && args[1] === 'remove').map((args) => args[2]);
  assert.deepEqual(removes.sort(), ['CAST', 'HEADLESS-3']);
});

test('off with a stale state file falls back to removing leftover outputs', { skip }, () => {
  const t = setup({ monitors: [physical('eDP-1'), physical('HEADLESS-2')] });
  fs.mkdirSync(path.dirname(t.stateFile), { mode: 0o700 });
  fs.writeFileSync(t.stateFile, 'HEADLESS-9\n');
  const result = t.run(['off']);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(names(t.hypr()), ['eDP-1']);
  assert.equal(fs.existsSync(t.stateFile), false);
});

test('off ignores a state file naming a physical monitor', { skip }, () => {
  const t = setup({ monitors: [physical('eDP-1'), physical('HDMI-A-1')] });
  fs.mkdirSync(path.dirname(t.stateFile), { mode: 0o700 });
  fs.writeFileSync(t.stateFile, 'HDMI-A-1\n');
  const result = t.run(['off']);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /already off/);
  assert.deepEqual(names(t.hypr()), ['HDMI-A-1', 'eDP-1']);
});

test('off refuses when no physical monitor could receive the windows', { skip }, () => {
  const t = setup({ monitors: [physical('CAST')], workspaces: [{ id: 1, monitor: 'CAST' }] });
  const result = t.run(['off']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /no physical monitor/);
  assert.deepEqual(names(t.hypr()), ['CAST']);
});

test('status reports plain and JSON forms', { skip }, () => {
  const t = setup();
  const idle = t.run(['status']);
  assert.equal(idle.status, 3);
  assert.equal(idle.stdout.trim(), 'inactive');
  assert.deepEqual(JSON.parse(t.run(['status', '--json']).stdout), { active: false, count: 0 });

  assert.equal(t.run(['on']).status, 0);
  const active = t.run(['status']);
  assert.equal(active.status, 0);
  assert.match(active.stdout, /^active CAST 1920x1080@60/);
  const json = JSON.parse(t.run(['status', '--json']).stdout);
  assert.deepEqual(json, { active: true, name: 'CAST', width: 1920, height: 1080, refreshRate: 60, scale: 1.5, count: 1 });
});

test('toggle switches between on and off', { skip }, () => {
  const t = setup();
  assert.equal(t.run(['toggle']).status, 0);
  assert.deepEqual(names(t.hypr()), ['CAST', 'eDP-1']);
  assert.equal(t.run(['toggle']).status, 0);
  assert.deepEqual(names(t.hypr()), ['eDP-1']);
});

test('fails clearly when jq is missing', () => {
  const t = setup();
  const result = childProcess.spawnSync('/bin/bash', [script, 'on'], {
    env: { ...t.env, PATH: path.join(t.home, 'bin') },
    encoding: 'utf8',
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /jq is required but not installed/);
});
