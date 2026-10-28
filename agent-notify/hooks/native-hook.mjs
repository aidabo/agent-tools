#!/usr/bin/env node
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import os from 'node:os';

const DEFAULT_CAPTURE_LINES = Math.max(parseIntegerish(process.env.CLAWHIP_TMUX_CAPTURE_LINES) ?? 400, 50);
const DEFAULT_CHUNK_SIZE = Math.min(Math.max(parseIntegerish(process.env.CLAWHIP_NOTIFY_CHUNK_SIZE) ?? 3200, 300), 3900);
const DEFAULT_CHUNK_DELAY_MS = Math.min(Math.max(parseIntegerish(process.env.CLAWHIP_NOTIFY_CHUNK_DELAY_MS) ?? 1000, 0), 5000);
const PRESERVE_ANSI = parseBoolish(process.env.CLAWHIP_PRESERVE_ANSI) === true;
const DEFAULT_DISCORD_WEBHOOK_URL =
  (process.env.CLAWHIP_DISCORD_WEBHOOK_URL || process.env.DISCORD_WEBHOOK_URL || '').trim();
const DEFAULT_DISCORD_MENTION =
  (process.env.CLAWHIP_DISCORD_MENTION || process.env.DISCORD_MENTION || '').trim();
const DEFAULT_DISCORD_MESSAGE_MODE = (
  process.env.CLAWHIP_DISCORD_MESSAGE_MODE || process.env.DISCORD_MESSAGE_MODE || 'content'
).trim().toLowerCase();
const DEFAULT_DISCORD_EMBED_COLOR = parseColorish(
  process.env.CLAWHIP_DISCORD_EMBED_COLOR || process.env.DISCORD_EMBED_COLOR,
  0x5865f2,
);
const DEFAULT_DISCORD_DRY_RUN =
  parseBoolish(process.env.CLAWHIP_DISCORD_DRY_RUN || process.env.DISCORD_DRY_RUN) === true;
const STOP_NOTIFY_CONFIG_PATH = resolve(
  process.env.CLAWHIP_STOP_NOTIFY_CONFIG || join(os.homedir(), '.notify', 'stop-notify.json'),
);
const STOP_NOTIFY_ENV_PATH = resolve(
  process.env.CLAWHIP_STOP_NOTIFY_ENV || join(os.homedir(), '.notify', 'stop-notify.env'),
);
const STOP_NOTIFY_ENV_FILE = loadSimpleEnvFile(STOP_NOTIFY_ENV_PATH);
const NOTIFY_PROJECT_ROOT = asNonEmptyString(
  process.env.CLAWHIP_NOTIFY_PROJECT_ROOT || STOP_NOTIFY_ENV_FILE.CLAWHIP_NOTIFY_PROJECT_ROOT,
);
const NOTIFY_STATE_ROOT = resolve(
  process.env.CLAWHIP_NOTIFY_STATE_ROOT ||
    STOP_NOTIFY_ENV_FILE.CLAWHIP_NOTIFY_STATE_ROOT ||
    join(os.homedir(), '.notify', 'state'),
);
const HOOK_INVOCATION_LOG_PATH = join(NOTIFY_STATE_ROOT, 'hook-invocations.log');
const DISCORD_DISPATCH_DIR = join(NOTIFY_STATE_ROOT, 'discord-dispatch');
const STOP_DISPATCH_DIR = join(NOTIFY_STATE_ROOT, 'stop-dispatch');
const LEGACY_PROMPT_STATE_PATH = join(os.homedir(), '.clawhip', 'state', 'prompt-submit.json');

function arg(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : '';
}

function readStdin() {
  return new Promise((resolveOut) => {
    const chunks = [];
    process.stdin.on('data', (chunk) => chunks.push(chunk));
    process.stdin.on('end', () => resolveOut(Buffer.concat(chunks).toString('utf8')));
    process.stdin.on('error', () => resolveOut(''));
  });
}

function parseJson(text, fallback = {}) {
  try {
    return text && text.trim() ? JSON.parse(text) : fallback;
  } catch {
    return fallback;
  }
}

function asNonEmptyString(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : '';
}

function sanitizeStateSegment(value) {
  const trimmed = asNonEmptyString(value);
  if (!trimmed) return 'unknown';
  return trimmed.replace(/[^A-Za-z0-9._-]+/g, '_');
}

function getPaneStateKey(tmuxMetadata) {
  return getPaneStateKeyCandidates(tmuxMetadata)[0];
}

function getPaneStateKeyCandidates(tmuxMetadata) {
  const candidates = [];
  const session = asNonEmptyString(tmuxMetadata?.tmux_session);
  const window = asNonEmptyString(tmuxMetadata?.tmux_window);
  const paneIndex = asNonEmptyString(tmuxMetadata?.tmux_pane_index);
  if (session && window && paneIndex) {
    candidates.push(`${session}.${window}.${paneIndex}`);
  }
  const paneId = asNonEmptyString(tmuxMetadata?.tmux_pane) || asNonEmptyString(tmuxMetadata?.tmux_pane_id);
  if (paneId && !candidates.includes(paneId)) {
    candidates.push(paneId);
  }
  return candidates.length > 0 ? candidates : [];
}

function describeTmuxTarget(tmuxMetadata) {
  const session = asNonEmptyString(tmuxMetadata?.tmux_session);
  const window = asNonEmptyString(tmuxMetadata?.tmux_window);
  const paneIndex = asNonEmptyString(tmuxMetadata?.tmux_pane_index);
  const paneId = asNonEmptyString(tmuxMetadata?.tmux_pane) || asNonEmptyString(tmuxMetadata?.tmux_pane_id);
  const paneTarget = session && window && paneIndex ? `${session}:${window}.${paneIndex}` : '';
  if (paneTarget && paneId) return `${paneTarget} pane_id=${paneId}`;
  if (paneTarget) return paneTarget;
  if (paneId) return `pane_id=${paneId}`;
  return '';
}

function writeJsonFile(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
}

function logHookInvocation(provider, eventName, tmuxMetadata, cwd, extra = {}) {
  try {
    const target = getPaneStateKey(tmuxMetadata);
    if (!target) return; // Skip logging if no pane identified
    const line = [
      new Date().toISOString(),
      `provider=${provider}`,
      `event=${String(eventName || 'unknown')}`,
      `target=${target}`,
      `cwd=${cwd}`,
      extra.projectRoot ? `project_root=${extra.projectRoot}` : '',
      extra.stateRoot ? `state_root=${extra.stateRoot}` : '',
      extra.repoRoot ? `repo_root=${extra.repoRoot}` : '',
      extra.worktreeRoot ? `worktree_root=${extra.worktreeRoot}` : '',
      extra.paneRole ? `pane_role=${extra.paneRole}` : '',
    ].join(' ');
    mkdirSync(dirname(HOOK_INVOCATION_LOG_PATH), { recursive: true });
    appendFileSync(HOOK_INVOCATION_LOG_PATH, `${line}\n`);
    console.error(`[notify] native-hook called ${line}`);
  } catch {}
}

function readJsonFile(path) {
  if (!existsSync(path)) return null;
  return parseJson(readFileSync(path, 'utf8'), null);
}

function normalizePaneMetadata(tmuxMetadata) {
  return {
    tmux_session: asNonEmptyString(tmuxMetadata?.tmux_session),
    tmux_window: asNonEmptyString(tmuxMetadata?.tmux_window),
    tmux_pane_index: asNonEmptyString(tmuxMetadata?.tmux_pane_index),
    tmux_pane: asNonEmptyString(tmuxMetadata?.tmux_pane) || asNonEmptyString(tmuxMetadata?.tmux_pane_id),
    tmux_title: asNonEmptyString(tmuxMetadata?.tmux_title),
    tmux_pane_tty: asNonEmptyString(tmuxMetadata?.tmux_pane_tty),
    tmux_client_count: tmuxMetadata?.tmux_client_count ?? null,
    tmux_attached: tmuxMetadata?.tmux_attached ?? null,
  };
}

function paneCapturePath(tmuxMetadata) {
  return join(
    NOTIFY_STATE_ROOT,
    'pane-output',
    `${sanitizeStateSegment(getPaneStateKey(tmuxMetadata))}.diff`,
  );
}

function findPromptSubmitState(tmuxMetadata) {
  for (const key of getPaneStateKeyCandidates(tmuxMetadata)) {
    const path = join(NOTIFY_STATE_ROOT, 'prompt-submit', `${sanitizeStateSegment(key)}.json`);
    const state = readJsonFile(path);
    if (state) {
      return { state, path };
    }
  }
  const legacyState = readJsonFile(LEGACY_PROMPT_STATE_PATH);
  if (legacyState) {
    return { state: legacyState, path: LEGACY_PROMPT_STATE_PATH };
  }
  return { state: null, path: '' };
}

function findPromptBoundaryState(tmuxMetadata) {
  for (const key of getPaneStateKeyCandidates(tmuxMetadata)) {
    const path = join(NOTIFY_STATE_ROOT, 'prompt-boundary', `${sanitizeStateSegment(key)}.json`);
    const state = readJsonFile(path);
    if (state) {
      return { state, path };
    }
  }
  return { state: null, path: '' };
}

function listPromptSubmitStates() {
  const promptSubmitDir = join(NOTIFY_STATE_ROOT, 'prompt-submit');
  if (!existsSync(promptSubmitDir)) return [];

  return readdirSync(promptSubmitDir)
    .filter((entry) => entry.endsWith('.json'))
    .map((entry) => {
      const path = join(promptSubmitDir, entry);
      let mtimeMs = 0;
      try {
        mtimeMs = statSync(path).mtimeMs || 0;
      } catch {}
      return {
        path,
        state: readJsonFile(path),
        mtimeMs,
      };
    })
    .filter((entry) => entry.state);
}

function promptStateMatchesInput(state, input) {
  if (!state || !input || typeof input !== 'object') return false;
  const sessionId = asNonEmptyString(input.session_id || input.sessionId);
  const turnId = asNonEmptyString(input.turn_id || input.turnId);
  if (sessionId && asNonEmptyString(state.session_id || state.sessionId) === sessionId) {
    return true;
  }
  if (turnId && asNonEmptyString(state.turn_id || state.turnId) === turnId) {
    return true;
  }
  return false;
}

function getPromptSessionId(input) {
  return input.session_id || input.sessionId || null;
}

function writePromptBoundaryState(provider, eventName, input, tmuxMetadata) {
  const normalizedEvent = String(eventName || '').trim().toLowerCase();
  if (
    normalizedEvent !== 'userpromptsubmit' &&
    normalizedEvent !== 'user-prompt-submit' &&
    normalizedEvent !== 'prompt-submitted' &&
    normalizedEvent !== 'session.prompt-submitted'
  ) {
    return;
  }

  try {
    const promptText = input.prompt || input.user_prompt || input.message || '';
    const currentSessionId = getPromptSessionId(input);

    // Check if this is a new conversation session
    const existingState = findPromptBoundaryState(tmuxMetadata).state;
    const existingSessionId = existingState?.session_id || null;
    const isNewConversation = !existingState ||
      (currentSessionId !== null && existingSessionId !== null && existingSessionId !== currentSessionId);

    const state = {
      observed_at: new Date().toISOString(),
      provider,
      event_name: eventName,
      session_id: currentSessionId,
      turn_id: input.turn_id || input.turnId || null,
      prompt_summary: truncate(promptText),
      prompt_excerpt: truncate(promptText, 600),
      tmux_session: tmuxMetadata?.tmux_session || null,
      tmux_window: tmuxMetadata?.tmux_window || null,
      tmux_pane_index: tmuxMetadata?.tmux_pane_index || null,
      tmux_pane: tmuxMetadata?.tmux_pane || null,
      tmux_title: tmuxMetadata?.tmux_title || null,
      boundary_type: 'user_prompt_submit',
    };

    // On first prompt of a conversation, record the first prompt excerpt
    // so extractConversationTail can anchor to the conversation start.
    if (isNewConversation) {
      state.first_prompt_summary = truncate(promptText);
      state.first_prompt_excerpt = truncate(promptText, 600);
    } else {
      // Preserve the first prompt from the existing session
      state.first_prompt_summary = existingState.first_prompt_summary || state.prompt_summary;
      state.first_prompt_excerpt = existingState.first_prompt_excerpt || state.prompt_excerpt;
    }

    for (const key of getPaneStateKeyCandidates(tmuxMetadata)) {
      const path = join(NOTIFY_STATE_ROOT, 'prompt-boundary', `${sanitizeStateSegment(key)}.json`);
      writeJsonFile(path, state);
    }
  } catch {}
}

function findPromptSubmitStateForStop(input, tmuxMetadata) {
  const boundary = findPromptBoundaryState(tmuxMetadata);
  if (boundary.state) {
    return {
      ...boundary,
      tmuxMetadata: normalizePaneMetadata(boundary.state),
      recoveredFromPromptState: false,
      recoveredFromPromptBoundary: true,
    };
  }

  const direct = findPromptSubmitState(tmuxMetadata);
  if (direct.state) {
    return {
      ...direct,
      tmuxMetadata: normalizePaneMetadata(direct.state),
      recoveredFromPromptState: false,
    };
  }

  const entries = listPromptSubmitStates().sort((a, b) => b.mtimeMs - a.mtimeMs);
  if (entries.length === 0) {
    return { state: null, path: '', tmuxMetadata: null, recoveredFromPromptState: false };
  }

  const matchedByInput = entries.find((entry) => promptStateMatchesInput(entry.state, input));
  const chosen = matchedByInput || entries[0];
  return {
    state: chosen.state,
    path: chosen.path,
    tmuxMetadata: normalizePaneMetadata(chosen.state),
    recoveredFromPromptState: true,
  };
}

function loadSimpleEnvFile(filePath) {
  if (!existsSync(filePath)) return {};
  const text = readFileSync(filePath, 'utf8');
  const env = {};
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const idx = line.indexOf('=');
    if (idx <= 0) continue;
    const key = line.slice(0, idx).trim();
    let value = line.slice(idx + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (key) env[key] = value;
  }
  return env;
}

function resolveEnvValue(name, fileEnv = {}) {
  const direct = asNonEmptyString(process.env[name]);
  if (direct) return direct;
  return asNonEmptyString(fileEnv[name]);
}

function runGit(args, cwd) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  if (result.status === 0) {
    return result.stdout.trim();
  }
  return '';
}

function loadProjectMetadata(root) {
  const path = join(root, '.clawhip', 'project.json');
  if (!existsSync(path)) return null;
  return parseJson(readFileSync(path, 'utf8'), null);
}

function inferRepoRoot(cwd) {
  const commonDir = runGit(['rev-parse', '--path-format=absolute', '--git-common-dir'], cwd);
  if (commonDir) {
    return dirname(commonDir);
  }
  return runGit(['rev-parse', '--show-toplevel'], cwd) || cwd;
}

function inferWorktreeRoot(cwd) {
  return runGit(['rev-parse', '--show-toplevel'], cwd) || cwd;
}

function parseIntegerish(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!/^-?\d+$/.test(trimmed)) return null;
  return Number.parseInt(trimmed, 10);
}

function parseBoolish(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return value !== 0;
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toLowerCase();
  if (!normalized) return null;
  if (['1', 'true', 'yes', 'attached'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'detached'].includes(normalized)) return false;
  return null;
}

function clampIntegerish(value, fallback, min, max) {
  const parsed = parseIntegerish(value);
  if (parsed === null) return fallback;
  return Math.min(Math.max(parsed, min), max);
}

function parseColorish(value, fallback) {
  if (typeof value !== 'string' || !value.trim()) return fallback;
  const trimmed = value.trim().toLowerCase();
  if (/^#?[0-9a-f]{6}$/i.test(trimmed)) {
    return Number.parseInt(trimmed.replace(/^#/, ''), 16);
  }
  if (/^0x[0-9a-f]{6}$/i.test(trimmed)) {
    return Number.parseInt(trimmed.slice(2), 16);
  }
  const parsed = Number.parseInt(trimmed, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function mergeAdditive(base, extra) {
  if (!extra || typeof extra !== 'object' || Array.isArray(extra)) return base;
  const output = { ...base };
  for (const [key, value] of Object.entries(extra)) {
    if (!(key in output)) {
      output[key] = value;
      continue;
    }
    if (Array.isArray(output[key]) && Array.isArray(value)) {
      output[key] = [...output[key], ...value];
      continue;
    }
    if (
      output[key] &&
      value &&
      typeof output[key] === 'object' &&
      typeof value === 'object' &&
      !Array.isArray(output[key]) &&
      !Array.isArray(value)
    ) {
      output[key] = mergeAdditive(output[key], value);
    }
  }
  return output;
}

// Augment modules are code that runs on every hook, so they load only from the user's own
// ~/.notify/augment — never from the repo being worked on (a cloned repo could plant one).
const AUGMENT_DIR = join(os.homedir(), '.notify', 'augment');

async function collectAugmentation(payload) {
  const augmentDir = AUGMENT_DIR;
  if (!existsSync(augmentDir)) return null;

  let merged = {};
  for (const entry of readdirSync(augmentDir)) {
    if (!entry.endsWith('.mjs') && !entry.endsWith('.js') && !entry.endsWith('.cjs')) continue;
    const modulePath = join(augmentDir, entry);
    const module = await import(pathToFileURL(modulePath).href);
    const fn = module.default || module.augment;
    if (typeof fn !== 'function') continue;
    const result = await fn(payload);
    if (result && typeof result === 'object') {
      merged = mergeAdditive(merged, result);
    }
  }

  return Object.keys(merged).length > 0 ? merged : null;
}

function loadStopNotifyConfig() {
  if (!existsSync(STOP_NOTIFY_CONFIG_PATH)) return null;
  return parseJson(readFileSync(STOP_NOTIFY_CONFIG_PATH, 'utf8'), null);
}

function parseStablePaneTarget(target) {
  const value = asNonEmptyString(target);
  if (!value) return null;
  const match = value.match(/^([^:]+):([0-9]+)\.([0-9]+)$/);
  if (!match) return null;
  return {
    tmux_session: match[1],
    tmux_window: match[2],
    tmux_pane_index: match[3],
  };
}

function collectStablePaneMetadataFromEnv() {
  const direct = {};
  const stableTarget = parseStablePaneTarget(process.env.CLAWHIP_NOTIFY_PANE_TARGET);
  if (stableTarget) {
    Object.assign(direct, stableTarget);
  }

  const stablePaneId = asNonEmptyString(process.env.CLAWHIP_NOTIFY_PANE_ID);
  if (stablePaneId) direct.tmux_pane = stablePaneId;

  const stableTitle = asNonEmptyString(process.env.CLAWHIP_NOTIFY_PANE_TITLE);
  if (stableTitle) direct.tmux_title = stableTitle;

  const stableSession = asNonEmptyString(process.env.CLAWHIP_NOTIFY_SESSION);
  if (stableSession && !direct.tmux_session) direct.tmux_session = stableSession;

  const stableWindow = asNonEmptyString(process.env.CLAWHIP_NOTIFY_WINDOW_INDEX);
  if (stableWindow && !direct.tmux_window) direct.tmux_window = stableWindow;

  const stablePaneIndex = asNonEmptyString(process.env.CLAWHIP_NOTIFY_PANE_INDEX);
  if (stablePaneIndex && !direct.tmux_pane_index) direct.tmux_pane_index = stablePaneIndex;

  return Object.keys(direct).length > 0 ? direct : null;
}

function hasDirectTmuxEvidence(input) {
  if (collectStablePaneMetadataFromEnv()) return true;
  if (asNonEmptyString(process.env.TMUX_PANE)) return true;

  const sources = [input, input?.context, input?.event_payload, input?.payload]
    .filter((value) => value && typeof value === 'object');
  const tmuxSources = [
    ...sources,
    ...sources
      .map((value) => value.tmux)
      .filter((value) => value && typeof value === 'object'),
  ];

  for (const source of tmuxSources) {
    if (
      asNonEmptyString(source.tmux_session || source.tmuxSession || source.session) ||
      asNonEmptyString(source.tmux_window || source.tmuxWindow || source.window) ||
      asNonEmptyString(source.tmux_pane || source.tmuxPane || source.pane || source.tmux_pane_id || source.pane_id)
    ) {
      return true;
    }
  }

  return false;
}

function collectTmuxMetadata(input, cwd) {
  const sources = [input, input?.context, input?.event_payload, input?.payload]
    .filter((value) => value && typeof value === 'object');
  const tmuxSources = [
    ...sources,
    ...sources
      .map((value) => value.tmux)
      .filter((value) => value && typeof value === 'object'),
  ];

  function pickString(keys) {
    for (const source of tmuxSources) {
      for (const key of keys) {
        const value = source[key];
        if (typeof value === 'string' && value.trim()) {
          return value.trim();
        }
      }
    }
    return '';
  }

  function pickInteger(keys) {
    for (const source of tmuxSources) {
      for (const key of keys) {
        const value = parseIntegerish(source[key]);
        if (value !== null) return value;
      }
    }
    return null;
  }

  function pickBoolean(keys) {
    for (const source of tmuxSources) {
      for (const key of keys) {
        const value = parseBoolish(source[key]);
        if (value !== null) return value;
      }
    }
    return null;
  }

  const direct = {};
  const tmuxSession = pickString(['tmux_session', 'tmuxSession', 'session']);
  const tmuxWindow = pickString(['tmux_window', 'tmuxWindow', 'window']);
  const tmuxPane = pickString(['tmux_pane', 'tmuxPane', 'pane', 'tmux_pane_id', 'tmuxPaneId', 'pane_id', 'paneId']);
  const tmuxPaneIndex = pickString(['tmux_pane_index', 'tmuxPaneIndex', 'pane_index', 'paneIndex']);
  const tmuxTitle = pickString(['tmux_title', 'tmuxTitle', 'title']);
  const tmuxPaneTty = pickString(['tmux_pane_tty', 'tmuxPaneTty', 'pane_tty', 'paneTty']);
  const tmuxClientCount = pickInteger(['tmux_client_count', 'tmuxClientCount', 'client_count', 'clientCount']);
  const tmuxAttached = pickBoolean(['tmux_attached', 'tmuxAttached', 'attached']);

  if (tmuxSession) direct.tmux_session = tmuxSession;
  if (tmuxWindow) direct.tmux_window = tmuxWindow;
  if (tmuxPane) direct.tmux_pane = tmuxPane;
  if (tmuxPaneIndex) direct.tmux_pane_index = tmuxPaneIndex;
  if (tmuxTitle) direct.tmux_title = tmuxTitle;
  if (tmuxPaneTty) direct.tmux_pane_tty = tmuxPaneTty;
  if (tmuxClientCount !== null) direct.tmux_client_count = tmuxClientCount;
  if (tmuxAttached !== null) direct.tmux_attached = tmuxAttached;

  const stablePaneMetadata = collectStablePaneMetadataFromEnv();
  if (stablePaneMetadata) {
    for (const [key, value] of Object.entries(stablePaneMetadata)) {
      if (!direct[key] && value) {
        direct[key] = value;
      }
    }
  }

  const tmuxTarget = asNonEmptyString(process.env.TMUX_PANE);
  if (tmuxTarget) {
    const result = spawnSync(
      'tmux',
      [
        'display-message',
        '-p',
        '-t',
        tmuxTarget,
        '#{session_name}\u001f#{window_index}\u001f#{pane_id}\u001f#{pane_index}\u001f#{pane_title}\u001f#{pane_tty}\u001f#{session_attached}',
      ],
      { cwd, encoding: 'utf8' },
    );
    if (result.status === 0) {
      const [session, window, pane, paneIndex, paneTitle, paneTty, attachedCount] = result.stdout.trim().split('\u001f');
      const clientCount = parseIntegerish(attachedCount);
      if (session && !direct.tmux_session) direct.tmux_session = session;
      if (window && !direct.tmux_window) direct.tmux_window = window;
      if (pane && !direct.tmux_pane) direct.tmux_pane = pane;
      if (paneIndex && !direct.tmux_pane_index) direct.tmux_pane_index = paneIndex;
      if (paneTitle && !direct.tmux_title) direct.tmux_title = paneTitle;
      if (paneTty && !direct.tmux_pane_tty) direct.tmux_pane_tty = paneTty;
      if (clientCount !== null) {
        if (direct.tmux_client_count === undefined) direct.tmux_client_count = clientCount;
        if (direct.tmux_attached === undefined) direct.tmux_attached = clientCount > 0;
      }
    }
  }

  const allowPathFallback =
    !!collectStablePaneMetadataFromEnv() ||
    !!asNonEmptyString(process.env.TMUX_PANE) ||
    !!tmuxSession ||
    !!tmuxWindow ||
    !!tmuxPane ||
    !!tmuxPaneIndex;

  if (allowPathFallback && (!direct.tmux_session || !direct.tmux_window || !direct.tmux_pane_index || !direct.tmux_pane)) {
    const pathResult = spawnSync(
      'tmux',
      ['list-panes', '-a', '-F', '#{session_name}\u001f#{window_index}\u001f#{pane_id}\u001f#{pane_index}\u001f#{pane_title}\u001f#{pane_tty}\u001f#{pane_current_path}'],
      { cwd, encoding: 'utf8' },
    );
    if (pathResult.status === 0 && pathResult.stdout) {
      const wanted = String(cwd || '').trim();
      const panes = pathResult.stdout
        .split('\n')
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => {
          const [session, window, pane, paneIndex, paneTitle, paneTty, panePath] = line.split('\u001f');
          return { session, window, pane, paneIndex, paneTitle, paneTty, panePath };
        });
      const exactMatch = panes.find((pane) => pane.panePath === wanted);
      const prefixMatch = panes.find((pane) => wanted && pane.panePath && wanted.startsWith(`${pane.panePath}/`));
      const selected = exactMatch || prefixMatch || null;
      if (selected) {
        if (selected.session && !direct.tmux_session) direct.tmux_session = selected.session;
        if (selected.window && !direct.tmux_window) direct.tmux_window = selected.window;
        if (selected.pane && !direct.tmux_pane) direct.tmux_pane = selected.pane;
        if (selected.paneIndex && !direct.tmux_pane_index) direct.tmux_pane_index = selected.paneIndex;
        if (selected.paneTitle && !direct.tmux_title) direct.tmux_title = selected.paneTitle;
        if (selected.paneTty && !direct.tmux_pane_tty) direct.tmux_pane_tty = selected.paneTty;
      }
    }
  }

  return Object.keys(direct).length > 0 ? normalizePaneMetadata(direct) : null;
}

function matchesStopRoute(route, tmuxMetadata) {
  const match = route?.match;
  if (!match || typeof match !== 'object') return true;

  const session = asNonEmptyString(tmuxMetadata?.tmux_session);
  const window = asNonEmptyString(tmuxMetadata?.tmux_window);
  const pane = asNonEmptyString(tmuxMetadata?.tmux_pane) || asNonEmptyString(tmuxMetadata?.tmux_pane_id);
  const paneIndex = asNonEmptyString(tmuxMetadata?.tmux_pane_index);
  const paneTarget = session && window && paneIndex ? `${session}:${window}.${paneIndex}` : '';
  const matchPaneId = asNonEmptyString(match.pane_id);

  if (matchPaneId) {
    if (pane && matchPaneId !== pane) return false;
    if (asNonEmptyString(match.session) && session && asNonEmptyString(match.session) !== session) return false;
    if (asNonEmptyString(match.window) && window && asNonEmptyString(match.window) !== window) return false;
    if (
      asNonEmptyString(match.pane_index) &&
      paneIndex &&
      asNonEmptyString(match.pane_index) !== paneIndex
    ) return false;
    if (
      asNonEmptyString(match.pane_target) &&
      paneTarget &&
      asNonEmptyString(match.pane_target) !== paneTarget
    ) return false;
    return true;
  }

  if (asNonEmptyString(match.session) && asNonEmptyString(match.session) !== session) return false;
  if (asNonEmptyString(match.window) && asNonEmptyString(match.window) !== window) return false;
  if (asNonEmptyString(match.pane) && asNonEmptyString(match.pane) !== pane) return false;
  if (asNonEmptyString(match.pane_index) && asNonEmptyString(match.pane_index) !== paneIndex) return false;
  if (asNonEmptyString(match.pane_target) && asNonEmptyString(match.pane_target) !== paneTarget) return false;
  return true;
}

function resolveStopRoute(tmuxMetadata) {
  const config = loadStopNotifyConfig();
  const fileEnv = loadSimpleEnvFile(STOP_NOTIFY_ENV_PATH);
  const routes = Array.isArray(config?.routes) ? config.routes : [];
  const matchedRoute = routes.find((route) => route && typeof route === 'object' && matchesStopRoute(route, tmuxMetadata)) || null;
  const defaults = config?.default && typeof config.default === 'object' ? config.default : {};

  const webhookEnvName = asNonEmptyString(matchedRoute?.webhook_env) || asNonEmptyString(defaults.webhook_env);
  const mention = asNonEmptyString(matchedRoute?.mention) || asNonEmptyString(defaults.mention) || DEFAULT_DISCORD_MENTION;
  const derivedPaneTarget =
    asNonEmptyString(tmuxMetadata?.tmux_session) &&
    asNonEmptyString(tmuxMetadata?.tmux_window) &&
    asNonEmptyString(tmuxMetadata?.tmux_pane_index)
      ? `${tmuxMetadata.tmux_session}:${tmuxMetadata.tmux_window}.${tmuxMetadata.tmux_pane_index}`
      : '';
  const derivedPaneId = asNonEmptyString(tmuxMetadata?.tmux_pane) || asNonEmptyString(tmuxMetadata?.tmux_pane_id);
  const captureTarget =
    asNonEmptyString(matchedRoute?.capture_target) ||
    asNonEmptyString(defaults.capture_target) ||
    derivedPaneTarget ||
    derivedPaneId ||
    '';
  const webhookUrl =
    (webhookEnvName && resolveEnvValue(webhookEnvName, fileEnv)) ||
    asNonEmptyString(matchedRoute?.webhook) ||
    asNonEmptyString(defaults.webhook) ||
    DEFAULT_DISCORD_WEBHOOK_URL;
  const captureLines = clampIntegerish(
    matchedRoute?.capture_lines ?? defaults.capture_lines,
    DEFAULT_CAPTURE_LINES,
    50,
    5000,
  );
  const chunkSize = clampIntegerish(
    matchedRoute?.chunk_size ?? defaults.chunk_size,
    DEFAULT_CHUNK_SIZE,
    300,
    3900,
  );
  const chunkDelayMs = clampIntegerish(
    matchedRoute?.chunk_delay_ms ?? defaults.chunk_delay_ms,
    DEFAULT_CHUNK_DELAY_MS,
    0,
    5000,
  );
  const enabled = parseBoolish(matchedRoute?.enabled ?? defaults.enabled);

  return {
    config,
    matchedRoute,
    routeName: asNonEmptyString(matchedRoute?.name) || 'default',
    enabled: enabled !== false,
    webhookEnvName,
    webhookUrl,
    mention,
    captureTarget,
    fallbackCaptureTarget: captureTarget === derivedPaneTarget ? derivedPaneId : derivedPaneTarget,
    captureLines,
    chunkSize,
    chunkDelayMs,
    envPath: STOP_NOTIFY_ENV_PATH,
    configPath: STOP_NOTIFY_CONFIG_PATH,
  };
}

function truncate(text, maxLen = 200) {
  if (!text || typeof text !== 'string') return '';
  const trimmed = text.trim();
  return trimmed.length <= maxLen ? trimmed : trimmed.slice(0, maxLen) + '…';
}

function isStopEvent(eventName) {
  const normalizedEvent = String(eventName || '').trim().toLowerCase();
  return normalizedEvent === 'stop' || normalizedEvent === 'sessionstop' || normalizedEvent === 'session-stopped';
}

function isPromptBoundaryEvent(eventName) {
  const normalizedEvent = String(eventName || '').trim().toLowerCase();
  return (
    normalizedEvent === 'userpromptsubmit' ||
    normalizedEvent === 'user-prompt-submit' ||
    normalizedEvent === 'prompt-submitted' ||
    normalizedEvent === 'session.prompt-submitted'
  );
}

function normalizeWhitespace(text) {
  return String(text || '')
    .replace(/\s+/g, ' ')
    .trim();
}

function stripAnsi(text) {
  return String(text || '')
    .replace(/\u001b\[[0-9;]*m/g, '');
}

function stripCodexBoilerplate(text) {
  return String(text || '')
    .split('\n')
    .filter((line) => {
      const trimmed = line.trim();
      if (!trimmed) return true;
      if (/^(PreToolUse|PostToolUse|SessionStart|Stop|UserPromptSubmit)\s*$/u.test(trimmed)) return false;
      if (/^Ran\s+.+$/u.test(trimmed)) return false;
      if (/^›\s+/u.test(trimmed)) return false;
      if (/^•\s*(SessionStart|UserPromptSubmit) hook \(completed\)$/u.test(trimmed)) return false;
      if (/^hook context:/iu.test(trimmed)) return false;
      if (/^─+\s*Worked for .*?\s*─+$/u.test(trimmed)) return false;
      if (/^Worked for\b/u.test(trimmed)) return false;
      if (/^[•*-]\s*Mode:\s*/u.test(trimmed)) return false;
      if (/^[•*-]\s*(Current mode|Action\/result|Evidence|Blocker|Next step):/iu.test(trimmed)) return false;
      // Japanese UI boilerplate
      if (/^(クリックしてリアクション|リアクションを付ける|返信|転送|その他)$/u.test(trimmed)) return false;
      if (/^\[\d{1,2}:\d{2}\]20\d{2}年\d{1,2}月\d{1,2}日/u.test(trimmed)) return false;
      if (/^\d{1,2}:\d{2}\s*$/.test(trimmed)) return false; // timestamp-only lines
      if (/^:\w[\w+-]*:$/u.test(trimmed)) return false;
      // Context status lines (Japanese/English)
      if (/^[\w.-]+(?:\s+[\w.-]+)?\s+·\s+Context\s+\d+%.*\b(?:in|out)\b.*$/u.test(trimmed)) return false;
      if (/^Context\s+\d+%\s+left\b/u.test(trimmed)) return false;
      if (/^(コンテキスト|Context)[：:]\s*\d+%/u.test(trimmed)) return false;
      if (/^\d+% of context used/u.test(trimmed)) return false;
      // Working status indicators
      if (/^(⏺|⏹|▶|⏸)\s*/.test(trimmed)) return false;
      if (/^Working on it/u.test(trimmed)) return false;
      if (/^処理中|^考え中|^準備中/u.test(trimmed)) return false;
      return true;
    })
    .join('\n');
}

function unwrapListContinuations(text) {
  const lines = String(text || '').split('\n');
  const merged = [];

  for (const line of lines) {
    const trimmed = line.trimEnd();
    const isContinuation = /^\s{2,}\S/.test(line);
    const previous = merged.length > 0 ? merged[merged.length - 1] : '';
    const previousLooksListLike = /^\s*[-*]\s+/.test(previous) || /^\s*(?:[$>#]|[A-Za-z0-9_./-]+)\S*$/.test(previous);
    const previousTrimmed = previous.trim();
    const continuationTrimmed = trimmed.trim();
    const shouldMergeWrappedPath =
      /\/$/.test(previousTrimmed) &&
      /^[A-Za-z0-9_.-]+$/.test(continuationTrimmed);
    const shouldMergeWrappedCommand =
      /(?:--config|--filter|--grep|--project|--cwd|--file|--path|--test|vite\.config\.ts|package\.json|tsconfig\.json)$/.test(previousTrimmed) &&
      /^[A-Za-z0-9_./:@-]+(?:\s+[A-Za-z0-9_./:@-]+)*$/.test(continuationTrimmed);

    if (isContinuation && previous && previousLooksListLike && (shouldMergeWrappedPath || shouldMergeWrappedCommand)) {
      const joiner = shouldMergeWrappedPath ? '' : ' ';
      merged[merged.length - 1] = `${previous}${joiner}${trimmed.trim()}`.replace(/\s+/g, ' ').trimEnd();
    } else {
      merged.push(trimmed);
    }
  }

  return merged.join('\n');
}

function isDiffLikeBodyLine(line) {
  return (
    /^\s*\d+\s+[ +-](?:\s+\S|$)/.test(line) ||
    /^\s*[ +-](?:\s+\S|$)/.test(line) ||
    /^\s*\d+\s{2,}\S/.test(line)
  );
}

function isWrappedDiffContinuation(previous, line) {
  const previousTrimmed = String(previous || '').trimEnd();
  const trimmed = String(line || '').trim();
  if (!previousTrimmed || !trimmed) return false;
  if (!isDiffLikeBodyLine(previous)) return false;
  if (/^\s*\d+\s+/.test(line)) return false;
  if (/^(Edited|Added|Deleted)\s+.+\(\+\d+\s+-\d+\)\s*$/u.test(trimmed)) return false;
  if (/^[•*-]\s+/u.test(trimmed)) return false;

  const previousBody = previousTrimmed.replace(/^\s*\d+\s+/, '');
  const continuesToken =
    /[A-Za-z0-9_./-]$/.test(previousBody) &&
    /^[_A-Za-z0-9./-]/u.test(trimmed) &&
    (/["'`[\](){},:=;]/u.test(trimmed) || /[_./-]/u.test(trimmed) || !/\s/u.test(trimmed));
  const continuesPath = /\/$/.test(previousBody) && /^[A-Za-z0-9_.-]+$/u.test(trimmed);
  const continuesFlag =
    /--?[A-Za-z0-9][\w-]*$/.test(previousBody) &&
    /^[A-Za-z0-9_./:@-]+(?:\s+[A-Za-z0-9_./:@-]+)*$/u.test(trimmed);

  return continuesToken || continuesPath || continuesFlag;
}

function isIndentedDiffContinuation(line) {
  return /^\s{2,}\S/.test(line) && !/^\s*\d+\s+/.test(line);
}

function diffWrapJoiner(previous, line) {
  const previousBody = String(previous || '')
    .trimEnd()
    .replace(/^\s*\d+\s+/, '');
  const trimmed = String(line || '').trim();
  if (
    (/[A-Za-z0-9_./-]$/.test(previousBody) && /^[_A-Za-z0-9./-]/u.test(trimmed)) ||
    /\/$/.test(previousBody)
  ) {
    return '';
  }
  return ' ';
}

function repairNumberedDiffWraps(text) {
  const lines = String(text || '').split('\n');
  const repaired = [];

  for (const line of lines) {
    const previous = repaired.length > 0 ? repaired[repaired.length - 1] : '';
    const trimmed = line.trim();
    const isStandaloneTimestamp = /^\[\d{1,2}:\d{2}\]20\d{2}年\d{1,2}月\d{1,2}日/u.test(trimmed);
    if (isStandaloneTimestamp) {
      continue;
    }

    const previousLooksNumberedDiff = isDiffLikeBodyLine(previous);
    const isIndentedContinuation = /^\s{5,}\S/.test(line);
    const isNewNumberedLine = /^\s*\d+\s+/.test(line);

    if (
      previous &&
      previousLooksNumberedDiff &&
      !isNewNumberedLine &&
      (isIndentedContinuation || isWrappedDiffContinuation(previous, line))
    ) {
      const joiner = diffWrapJoiner(previous, line);
      repaired[repaired.length - 1] = `${previous}${joiner}${trimmed}`.trimEnd();
      continue;
    }

    repaired.push(line);
  }

  return repaired.join('\n');
}

function splitIntoChunks(text, maxLen) {
  const lines = String(text || '').split('\n');
  const chunks = [];
  let current = '';
  let inFence = false;

  for (const line of lines) {
    // Track code fence boundaries
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
    }

    const candidate = current ? `${current}\n${line}` : line;
    if (candidate.length <= maxLen) {
      current = candidate;
      continue;
    }
    // Never split inside a code fence; close the fence first
    if (inFence && current) {
      // Keep adding to current even if it exceeds maxLen
      current = candidate;
      continue;
    }
    if (current) {
      chunks.push(current);
      current = '';
    }

    if (line.length <= maxLen) {
      current = line;
      continue;
    }

    let remaining = line;
    while (remaining.length > maxLen) {
      chunks.push(remaining.slice(0, maxLen));
      remaining = remaining.slice(maxLen);
    }
    current = remaining;
  }

  if (current) chunks.push(current);
  return chunks.length > 0 ? chunks : [''];
}

function splitIntoSections(text) {
  const lines = String(text || '').split('\n');
  const sections = [];
  let current = [];
  let currentKind = 'generic';

  for (const line of lines) {
    const trimmed = line.trim();
    const startsCodexDiffSection = /^(Edited|Added|Deleted)\s+.+\(\+\d+\s+-\d+\)\s*$/.test(trimmed);
    const startsNumberedDiffSection =
      /^\s*\d+\s+[+-](?![+-])/.test(line) ||
      /^\s*\d+\s{2,}\S/.test(line);
    const isLikelyDiffBodyLine =
      /^\s*\d+\s+[+-](?![+-])/.test(line) ||
      /^\s*\d+\s{2,}\S/.test(line) ||
      /^\s*⋮\s*$/.test(line);

    if (startsCodexDiffSection && current.length > 0) {
      sections.push(current.join('\n'));
      current = [];
      currentKind = 'generic';
    }
    if (startsNumberedDiffSection && currentKind === 'generic' && current.length > 0) {
      const previousLine = current[current.length - 1]?.trim() || '';
      const previousLooksLikeHeading =
        /^(Edited|Added|Deleted)\s+.+\(\+\d+\s+-\d+\)\s*$/.test(previousLine) ||
        /^[•*-]\s*(Edited|Added|Deleted)\s+.+\(\+\d+\s+-\d+\)\s*$/.test(previousLine);
      if (!previousLooksLikeHeading) {
        sections.push(current.join('\n'));
        current = [];
      }
    }
    if (line.trim() === '') {
      if (current.length > 0) {
        sections.push(current.join('\n'));
        current = [];
        currentKind = 'generic';
      }
      continue;
    }
    if (startsCodexDiffSection) {
      currentKind = 'codex-diff';
      current.push(line);
      continue;
    }
    if (startsNumberedDiffSection && currentKind === 'generic') {
      currentKind = 'numbered-diff';
      current.push(line);
      continue;
    }
    if (currentKind === 'codex-diff') {
      if (
        isLikelyDiffBodyLine ||
        isIndentedDiffContinuation(line) ||
        isWrappedDiffContinuation(current[current.length - 1] || '', line)
      ) {
        current.push(line);
        continue;
      }
      sections.push(current.join('\n'));
      current = [];
      currentKind = 'generic';
    }
    if (currentKind === 'numbered-diff') {
      if (
        isLikelyDiffBodyLine ||
        isIndentedDiffContinuation(line) ||
        isWrappedDiffContinuation(current[current.length - 1] || '', line)
      ) {
        current.push(line);
        continue;
      }
      sections.push(current.join('\n'));
      current = [];
      currentKind = 'generic';
    }
    current.push(line);
  }

  if (current.length > 0) {
    sections.push(current.join('\n'));
  }

  return sections.filter(Boolean);
}

function normalizeDiffContent(text) {
  return String(text || '')
    .split('\n')
    .flatMap((line) => {
      if (/^\s*⋮\s*$/.test(line)) {
        return [];
      }
      if (/^\s*\d+\s*$/.test(line)) {
        return [];
      }
      const codexEditedMatch = line.match(/^\s*(?:[•*-]\s*)?Edited\s+(.+?)\s+\(\+\d+\s+-\d+\)\s*$/);
      if (codexEditedMatch) {
        return [`--- a/${codexEditedMatch[1]}`, `+++ b/${codexEditedMatch[1]}`];
      }
      const codexAddedMatch = line.match(/^\s*(?:[•*-]\s*)?Added\s+(.+?)\s+\(\+\d+\s+-\d+\)\s*$/);
      if (codexAddedMatch) {
        return ['--- /dev/null', `+++ b/${codexAddedMatch[1]}`];
      }
      const codexDeletedMatch = line.match(/^\s*(?:[•*-]\s*)?Deleted\s+(.+?)\s+\(\+\d+\s+-\d+\)\s*$/);
      if (codexDeletedMatch) {
        return [`--- a/${codexDeletedMatch[1]}`, '+++ /dev/null'];
      }
      const numberedDiffMatch = line.match(/^\s*\d+\s+([+-](?![+-]).*)$/);
      if (numberedDiffMatch) {
        return [numberedDiffMatch[1]];
      }
      if (/^\s+[+-](?![+-])/.test(line)) {
        return [line.trimStart()];
      }
      const contextLineMatch = line.match(/^\s*\d+\s{2,}(.*)$/);
      if (contextLineMatch) {
        return [` ${contextLineMatch[1]}`];
      }
      return [line];
    })
    .join('\n');
}

function prepareFenceContent(text, fence) {
  if (fence === 'diff') {
    return normalizeDiffContent(text);
  }
  return text;
}

function escapeDiscordFenceContent(text) {
  return String(text || '').replace(/```/g, '`' + '\u200b' + '``');
}

function wrapDiscordMarkdownSection(section) {
  const text = String(section || '').trim();
  if (!text) return '';

  const language = detectCodeFenceLanguage(text);
  if (language === 'text') {
    return text;
  }

  const content = prepareFenceContent(text, language);
  return `\`\`\`${language}\n${escapeDiscordFenceContent(content)}\n\`\`\``;
}

function formatDiscordMarkdown(text) {
  const sections = splitIntoSections(text)
    .map(wrapDiscordMarkdownSection)
    .filter(Boolean);

  return sections.length > 0 ? sections.join('\n\n') : String(text || '').trim();
}

function detectCodeFenceLanguage(text) {
  const sample = unwrapListContinuations(String(text || ''));
  if (/(^|\n)\s*(?:[•*-]\s*)?(Edited|Added|Deleted)\s+.+\(\+\d+\s+-\d+\)\s*$/m.test(sample)) {
    return 'diff';
  }
  if (/^(diff --git|index [0-9a-f]+\.\.[0-9a-f]+|@@ |--- |\+\+\+ )/m.test(sample)) {
    return 'diff';
  }
  const nonEmptyLines = sample.split('\n').map((line) => line.trimEnd()).filter((line) => line.trim().length > 0);
  const numberedAddedLines = nonEmptyLines.filter((line) => /^\s*\d+\s+\+(?!\+)(?:\s|\S)/.test(line)).length;
  const numberedRemovedLines = nonEmptyLines.filter((line) => /^\s*\d+\s+-(?!--)(?:\s|\S)/.test(line)).length;
  if (numberedAddedLines >= 3 || numberedRemovedLines >= 3) {
    return 'diff';
  }
  const addedLines = nonEmptyLines.filter((line) => /^\+(?!\+\+)(?:\s|\S)/.test(line)).length;
  const removedLines = nonEmptyLines.filter((line) => /^-(?!--)(?:\s|\S)/.test(line)).length;
  if (addedLines >= 2 && removedLines >= 2 && addedLines + removedLines >= 4) {
    return 'diff';
  }
  if (/\u001b\[[0-9;]*m/.test(sample)) {
    return 'ansi';
  }
  if (/^\s*[\[{]/.test(sample) && /["'][^"']+["']\s*:/.test(sample)) {
    return 'json';
  }
  if (/(^|\n)\s*(import .+ from |export (async )?(function|const|class)|const |let |var |interface |type |async function |function )/m.test(sample)) {
    return 'ts';
  }
  if (/^\s*#!/.test(sample)) {
    return 'bash';
  }
  if (/(^|\n)\s*(curl |git |npm |yarn |pnpm |node |python3? |bash |sh )/m.test(sample)) {
    return 'bash';
  }
  if (/(^|\n)\s*<\w+[^>]*>/.test(sample) && /<\/\w+>/.test(sample)) {
    return 'html';
  }
  if (/(^|\n)\s*[.#]?[A-Za-z0-9_-]+\s*\{[^}]*$/.test(sample) || /(^|\n)\s*[A-Za-z-]+\s*:\s*[^;]+;/.test(sample)) {
    return 'css';
  }
  if (/(^|\n)\s*(SELECT|INSERT|UPDATE|DELETE|WITH|CREATE TABLE|ALTER TABLE)\b/i.test(sample)) {
    return 'sql';
  }
  if (/(^|\n)\s*def \w+\(|(^|\n)\s*import \w+|(^|\n)\s*from \w+ import /m.test(sample)) {
    return 'python';
  }
  const normalizedLines = sample.split('\n').map((line) => line.trim()).filter(Boolean);
  const pathLikeCount = normalizedLines.filter((line) =>
    /(?:^[-*]\s+)?(?:\.\.?\/|\/)?[\w.@-]+(?:\/[\w.@-]+)+(?:\.[A-Za-z0-9_-]+)?$/.test(line)
  ).length;
  const commandLikeCount = normalizedLines.filter((line) =>
    /(?:^[-*]\s+)?(?:\.\.?\/)?[\w./-]+(?:\s+--?[\w-]+|\s+[\w./:@-]+)+$/.test(line)
  ).length;
  const bulletLikeCount = normalizedLines.filter((line) => /^[•*-]\s+/u.test(line)).length;
  if (normalizedLines.length > 0 && bulletLikeCount === normalizedLines.length) {
    return 'text';
  }
  if (normalizedLines.length > 0 && pathLikeCount + commandLikeCount >= Math.max(2, Math.ceil(normalizedLines.length * 0.5))) {
    return 'bash';
  }
  return 'text';
}

function sleepMs(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function buildDiscordWebhookPayload(message, { isFirstMessage, mention, mode, embedColor }) {
  if (mode === 'embed') {
    const messageText = String(message || '');
    const description = isFirstMessage && mention ? `${mention}\n${messageText}` : messageText;
    const payload = {
      embeds: [
        {
          description,
          color: embedColor,
        },
      ],
    };
    if (isFirstMessage && mention) {
      payload.content = mention;
    }
    return payload;
  }

  return {
    content: isFirstMessage && mention ? `${mention}\n${String(message || '')}` : String(message || ''),
  };
}

function postDiscordWebhook(webhookUrl, payload, cwd) {
  return spawnSync(
    'curl',
    [
      '-sS',
      '-X',
      'POST',
      '--connect-timeout',
      '5',
      '--max-time',
      '30',
      '-H',
      'Content-Type: application/json',
      '--data-binary',
      JSON.stringify(payload),
      webhookUrl,
    ],
    { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 35000 },
  );
}

function appendDiscordDispatchLog(message) {
  try {
    mkdirSync(DISCORD_DISPATCH_DIR, { recursive: true });
    appendFileSync(join(DISCORD_DISPATCH_DIR, 'dispatch.log'), `${new Date().toISOString()} ${message}\n`);
  } catch {}
}

function appendStopDispatchLog(message) {
  try {
    mkdirSync(STOP_DISPATCH_DIR, { recursive: true });
    appendFileSync(join(STOP_DISPATCH_DIR, 'dispatch.log'), `${new Date().toISOString()} ${message}\n`);
  } catch {}
}

// Job files carry the webhook URL, so only the owner may read them.
function writePrivateJob(dir, job) {
  const jobId = `${Date.now()}-${process.pid}-${Math.random().toString(16).slice(2)}`;
  const jobPath = join(dir, `${jobId}.json`);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  try { chmodSync(dir, 0o700); } catch {}
  writeFileSync(jobPath, JSON.stringify(job, null, 2) + '\n', { mode: 0o600 });
  return jobPath;
}

function writeDiscordDispatchJob(job) {
  return writePrivateJob(DISCORD_DISPATCH_DIR, job);
}

function writeStopDispatchJob(job) {
  return writePrivateJob(STOP_DISPATCH_DIR, job);
}

function launchDiscordDispatchWorker(jobPath) {
  const workerScript = String.raw`
const { appendFileSync, readFileSync } = require('node:fs');
const { spawnSync } = require('node:child_process');

function sleepMs(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function appendLog(path, message) {
  try {
    appendFileSync(path, new Date().toISOString() + ' ' + message + '\n');
  } catch {}
}

function sendWithRetry(webhookUrl, payload, cwd, maxRetries) {
  maxRetries = Math.min(maxRetries || 3, 5);
  let lastError = null;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    const result = spawnSync(
      'curl',
      [
        '-sS', '-w', '\\n%{http_code}',
        '-X', 'POST',
        '--connect-timeout', '10',
        '--max-time', '30',
        '-H', 'Content-Type: application/json',
        '--data-binary', JSON.stringify(payload),
        webhookUrl,
      ],
      { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 35000 },
    );

    if (result.error) {
      lastError = result.error.message || String(result.error);
      if (attempt < maxRetries) sleepMs(1000 * attempt);
      continue;
    }

    const stdout = String(result.stdout || '');
    const lines = stdout.trim().split('\\n');
    const httpCode = parseInt(lines[lines.length - 1], 10);
    const body = lines.slice(0, -1).join('\\n');

    if (httpCode === 429) {
      let retryAfter = 5;
      try {
        const parsed = JSON.parse(body);
        retryAfter = Math.min((parsed.retry_after || 5) * 1.2, 30);
      } catch {}
      appendLog(jobPath.replace(/\\.json$/, '.log'),
        'rate-limited (429), waiting ' + retryAfter.toFixed(1) + 's before retry ' + attempt + '/' + maxRetries);
      sleepMs(retryAfter * 1000);
      continue;
    }

    if (httpCode >= 200 && httpCode < 300) {
      return { ok: true, code: httpCode };
    }

    if (httpCode >= 500) {
      lastError = 'HTTP ' + httpCode;
      if (attempt < maxRetries) sleepMs(2000 * attempt);
      continue;
    }

    lastError = 'HTTP ' + httpCode + ': ' + (body || '').slice(0, 200);
    break;
  }
  return { ok: false, error: lastError || 'unknown error' };
}

function send(webhookUrl, payload, cwd) {
  return sendWithRetry(webhookUrl, payload, cwd, 3);
}

const jobPath = process.argv[1];
let job = null;
try {
  job = JSON.parse(readFileSync(jobPath, 'utf8'));
} catch (error) {
  appendLog(jobPath.replace(/\.json$/, '.log'), 'failed to read job: ' + (error?.message || error));
  process.exit(1);
}

const logPath = job.log_path || jobPath.replace(/\.json$/, '.log');
// Write PID file for liveness check
const pidPath = jobPath.replace(/\.json$/, '.pid');
try { require('node:fs').writeFileSync(pidPath, String(process.pid)); } catch {}

appendLog(logPath, 'dispatch start payloads=' + (Array.isArray(job.payloads) ? job.payloads.length : 0));
let okCount = 0;
let failCount = 0;
for (const [index, payload] of (Array.isArray(job.payloads) ? job.payloads.entries() : [])) {
  const result = send(job.webhook_url, payload, job.cwd || process.cwd());
  if (result.ok) {
    okCount++;
    appendLog(logPath, 'payload ' + (index + 1) + ' sent (HTTP ' + result.code + ')');
  } else {
    failCount++;
    appendLog(logPath, 'payload ' + (index + 1) + ' FAILED: ' + result.error);
  }
  const delay = Number(job.chunk_delay_ms || 0);
  if (index < job.payloads.length - 1 && Number.isFinite(delay) && delay > 0) {
    sleepMs(delay);
  }
}
appendLog(logPath, 'dispatch complete ok=' + okCount + ' failed=' + failCount);
// Clean up PID file on completion; drop the job (it holds the webhook URL) once everything was sent
try { require('node:fs').unlinkSync(pidPath); } catch {}
if (failCount === 0) {
  try { require('node:fs').unlinkSync(jobPath); } catch {}
}
`;

  const child = spawn(
    process.execPath,
    ['-e', workerScript, jobPath],
    { cwd: dirname(jobPath), detached: true, stdio: 'ignore' },
  );
  child.unref();
  return child.pid || null;
}

function launchStopDispatchWorker(jobPath) {
  const provider = arg('--provider') || process.env.CLAWHIP_PROVIDER || 'unknown';
  const child = spawn(
    process.execPath,
    [process.argv[1], '--provider', provider, '--run-stop-job', jobPath],
    { cwd: dirname(jobPath), detached: true, stdio: 'ignore' },
  );
  child.unref();
  return child.pid || null;
}

function queueStopDispatch({ provider, input, cwd }) {
  const job = {
    created_at: new Date().toISOString(),
    provider,
    input,
    cwd,
    log_path: join(STOP_DISPATCH_DIR, 'dispatch.log'),
  };
  const jobPath = writeStopDispatchJob(job);
  const pid = launchStopDispatchWorker(jobPath);
  appendStopDispatchLog(`queued job=${basename(jobPath)} worker_pid=${pid || 'unknown'}`);
  return { jobPath, pid };
}

function queuePreparedStopDispatch(job) {
  const jobPath = writeStopDispatchJob(job);
  const pid = launchStopDispatchWorker(jobPath);
  appendStopDispatchLog(`queued prepared job=${basename(jobPath)} worker_pid=${pid || 'unknown'}`);
  return { jobPath, pid };
}

function processPreparedStopJob(preparedStop) {
  const messages = formatStopMessages({
    outputText: preparedStop.output_text || '',
    chunkSize: preparedStop.chunk_size,
    mention: preparedStop.mention,
  });
  if (messages.length === 0) {
    appendStopDispatchLog('prepared stop produced empty conversation output; skipping Discord send');
    process.exit(0);
  }

  const payloads = messages.map((message, index) =>
    buildDiscordWebhookPayload(message, {
      isFirstMessage: index === 0,
      mention: preparedStop.mention,
      mode: preparedStop.mode || DEFAULT_DISCORD_MESSAGE_MODE,
      embedColor: DEFAULT_DISCORD_EMBED_COLOR,
    }),
  );

  if (DEFAULT_DISCORD_DRY_RUN) {
    writeDryRunPreview(payloads, {
      webhookUrl: preparedStop.webhook_url,
      tmuxTarget: preparedStop.tmux_target,
      mode: preparedStop.mode || DEFAULT_DISCORD_MESSAGE_MODE,
    });
    process.exit(0);
  }

  if (!preparedStop.webhook_url) {
    appendStopDispatchLog('prepared stop missing webhook url; skipping Discord send');
    process.exit(0);
  }

  const dispatch = queueDiscordDispatch({
    webhookUrl: preparedStop.webhook_url,
    payloads,
    cwd: preparedStop.cwd || process.cwd(),
    chunkDelayMs: preparedStop.chunk_delay_ms,
    tmuxTarget: preparedStop.tmux_target,
    mode: preparedStop.mode || DEFAULT_DISCORD_MESSAGE_MODE,
  });
  appendStopDispatchLog(
    `prepared stop queued discord payloads=${payloads.length}${dispatch.pid ? ` worker_pid=${dispatch.pid}` : ''}`,
  );
  process.exit(0);
}

function queueDiscordDispatch({ webhookUrl, payloads, cwd, chunkDelayMs, tmuxTarget, mode }) {
  const job = {
    created_at: new Date().toISOString(),
    cwd,
    tmux_target: tmuxTarget,
    mode,
    webhook_url: webhookUrl,
    payloads,
    chunk_delay_ms: chunkDelayMs,
    log_path: join(DISCORD_DISPATCH_DIR, 'dispatch.log'),
  };
  const jobPath = writeDiscordDispatchJob(job);
  const pid = launchDiscordDispatchWorker(jobPath);
  appendDiscordDispatchLog(
    `queued job=${basename(jobPath)} target=${tmuxTarget} payloads=${payloads.length} worker_pid=${pid || 'unknown'}`,
  );
  return { jobPath, pid };
}

function writeDryRunPreview(payloads, { webhookUrl, tmuxTarget, mode }) {
  console.error('[clawhip] stop-notify dry-run');
  console.error(`[clawhip] target=${tmuxTarget}`);
  console.error(`[clawhip] webhook=${webhookUrl ? 'present' : 'missing'}`);
  console.error(`[clawhip] mode=${mode}`);
  console.error(JSON.stringify(payloads, null, 2));
}

function capturePaneOutput(tmuxTarget, cwd, lines) {
  const result = spawnSync(
    'tmux',
    ['capture-pane', '-e', '-p', '-t', tmuxTarget, '-S', `-${lines}`],
    { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000 },
  );

  if (result.error && result.error.code === 'ETIMEDOUT') {
    return { ok: false, error: 'tmux capture timed out after 15s' };
  }
  if (result.status !== 0) {
    const detail = result.stderr?.trim() || result.stdout?.trim() || 'unknown tmux capture failure';
    return { ok: false, error: detail };
  }

  return { ok: true, text: result.stdout || '' };
}

function capturePaneOutputWithFallback(primaryTarget, fallbackTarget, cwd, lines) {
  try {
    let primary = capturePaneOutput(primaryTarget, cwd, lines);
    // Retry once on empty output
    if (primary.ok && !String(primary.text || '').trim()) {
      primary = capturePaneOutput(primaryTarget, cwd, lines);
    }
    if (primary.ok || !fallbackTarget || fallbackTarget === primaryTarget) {
      return { ...primary, target: primaryTarget };
    }

    const fallback = capturePaneOutput(fallbackTarget, cwd, lines);
    if (fallback.ok) {
      return { ...fallback, target: fallbackTarget, fallback_from: primaryTarget };
    }

    // Last resort: try full scrollback
    const lastResort = capturePaneOutput(primaryTarget, cwd, Math.max(lines, 10000));
    if (lastResort.ok) {
      return { ...lastResort, target: primaryTarget, fallback_from: fallbackTarget };
    }

    return {
      ok: false,
      target: primaryTarget,
      error: `${primary.error}; fallback ${fallbackTarget}: ${fallback.error}`,
    };
  } catch (err) {
    return { ok: false, target: primaryTarget, error: `capture exception: ${err.message}` };
  }
}

function writePaneCaptureState(tmuxMetadata, tmuxTarget, outputText, captureOk) {
  try {
    const path = paneCapturePath(tmuxMetadata);
    writeJsonFile(`${path}.json`, {
      saved_at: new Date().toISOString(),
      tmux_target: tmuxTarget,
      tmux_session: tmuxMetadata?.tmux_session || null,
      tmux_window: tmuxMetadata?.tmux_window || null,
      tmux_pane_index: tmuxMetadata?.tmux_pane_index || null,
      tmux_pane: tmuxMetadata?.tmux_pane || null,
      tmux_title: tmuxMetadata?.tmux_title || null,
      capture_ok: captureOk,
      content_path: path,
    });
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, `${String(outputText || '').replace(/\n?$/, '\n')}`);
    return path;
  } catch {
    return '';
  }
}

function isVisiblePromptBoundaryLine(line) {
  const trimmed = String(line || '').trim();
  return (
    /^\s*\*\*Assistant\*\*\s*$/u.test(trimmed) ||
    /^\s*•\s*UserPromptSubmit hook \(completed\)\s*$/u.test(trimmed) ||
    /^\s*UserPromptSubmit hook \(completed\)\s*$/u.test(trimmed) ||
    /^\s*UserPromptSubmit\s*-\s*Recording OMX prompt boundary\s*$/u.test(trimmed) ||
    /^\s*UserPromptSubmit\s*$/u.test(trimmed)
  );
}

function stripTrailingEllipsis(text) {
  return String(text || '').replace(/[….]{2,}\s*$/g, '').trimEnd();
}

function normalizePromptLine(line) {
  return stripTrailingEllipsis(normalizeWhitespace(line.replace(/^›\s+/u, '')));
}

function matchesPromptExcerpt(normalizedPromptLine, normalizedExcerpt) {
  return (
    normalizedPromptLine === normalizedExcerpt ||
    normalizedPromptLine.includes(normalizedExcerpt) ||
    normalizedExcerpt.includes(normalizedPromptLine)
  );
}

function findLastPromptLine(lines) {
  return lines.findLastIndex((line) => /^\s*›\s+/.test(line.trim()));
}

function extractConversationTail(capturedText, promptState) {
  const text = stripAnsi(String(capturedText || '')).trim();
  if (!text) return '';

  const lines = text.split('\n');
  const firstPromptExcerpt = String(promptState?.first_prompt_excerpt || '').trim();
  const lastPromptExcerpt = String(promptState?.prompt_excerpt || promptState?.prompt_summary || '').trim();

  // Priority 1: Use first_prompt_excerpt to find the conversation START.
  // This captures the full conversation (all turns) from the first prompt to Stop.
  if (firstPromptExcerpt) {
    const normalizedFirst = normalizeWhitespace(firstPromptExcerpt);
    const firstIndex = lines.findIndex((line) => {
      const trimmed = line.trim();
      if (!/^›\s+/u.test(trimmed)) return false;
      return matchesPromptExcerpt(normalizePromptLine(trimmed), normalizedFirst);
    });
    if (firstIndex !== -1) {
      const result = lines.slice(firstIndex + 1).join('\n').trim();
      if (result) return result;
    }

    // Try word-based matching for first prompt
    const firstWords = normalizeWhitespace(firstPromptExcerpt)
      .split(' ').filter(Boolean).slice(0, 12);
    if (firstWords.length > 0) {
      for (let i = 0; i < lines.length; i += 1) {
        const trimmed = lines[i].trim();
        if (!/^›\s+/u.test(trimmed)) continue;
        const hay = normalizeWhitespace(trimmed);
        if (firstWords.every((word) => hay.includes(word) || word.length < 3)) {
          const result = lines.slice(i + 1).join('\n').trim();
          if (result) return result;
        }
      }
    }
  }

  // Priority 2: Use last prompt excerpt (existing behavior) to find the last turn.
  if (lastPromptExcerpt) {
    const normalizedLast = normalizeWhitespace(lastPromptExcerpt);
    const lastIndex = lines.findLastIndex((line) => {
      const trimmed = line.trim();
      if (!/^›\s+/u.test(trimmed)) return false;
      return matchesPromptExcerpt(normalizePromptLine(trimmed), normalizedLast);
    });
    if (lastIndex !== -1) {
      const result = lines.slice(lastIndex + 1).join('\n').trim();
      if (result) return result;
    }

    // Direct text search fallback
    for (const candidate of [lastPromptExcerpt, lastPromptExcerpt.slice(0, 160)]) {
      const directIndex = text.lastIndexOf(candidate);
      if (directIndex !== -1) {
        const matchedLineIndex = lines.findLastIndex((line) =>
          normalizeWhitespace(line).includes(candidate),
        );
        if (matchedLineIndex !== -1) {
          const result = lines.slice(matchedLineIndex + 1).join('\n').trim();
          if (result) return result;
        }
      }
    }

    // Word-based fallback for last prompt
    const lastWords = normalizeWhitespace(lastPromptExcerpt)
      .split(' ').filter(Boolean).slice(0, 12);
    if (lastWords.length > 0) {
      for (let i = lines.length - 1; i >= 0; i -= 1) {
        const trimmed = lines[i].trim();
        if (!/^›\s+/u.test(trimmed)) continue;
        const hay = normalizeWhitespace(trimmed);
        if (lastWords.every((word) => hay.includes(word) || word.length < 3)) {
          const result = lines.slice(i + 1).join('\n').trim();
          if (result) return result;
        }
      }
    }
  }

  // Priority 3: Visible boundary markers (UserPromptSubmit / **Assistant**)
  const promptBoundaryIndex = lines.findLastIndex((line) => isVisiblePromptBoundaryLine(line));
  if (promptBoundaryIndex !== -1) {
    const afterBoundary = lines.slice(promptBoundaryIndex + 1).join('\n').trim();
    if (afterBoundary) return afterBoundary;
  }

  // Priority 4: Any last › line
  const lastPromptIndex = findLastPromptLine(lines);
  if (lastPromptIndex !== -1) {
    const afterPrompt = lines.slice(lastPromptIndex + 1).join('\n').trim();
    if (afterPrompt) return afterPrompt;
  }

  // Priority 5: Bounded tail
  return lines.slice(Math.max(0, lines.length - 120)).join('\n').trim() || text;
}

function formatStopMessages({ outputText, chunkSize, mention }) {
  const normalizedOutput = PRESERVE_ANSI ? String(outputText || '') : stripAnsi(outputText);
  const cleanedOutput = stripCodexBoilerplate(normalizedOutput);
  const safeOutput = repairNumberedDiffWraps(unwrapListContinuations(String(cleanedOutput || '').trim()));
  if (!safeOutput.trim()) {
    return [];
  }
  const preparedOutput = formatDiscordMarkdown(safeOutput);
  const messages = [];
  const mentionOverhead = mention ? mention.length + 1 : 0;
  const chunkBudget = Math.max(1200, chunkSize - mentionOverhead);
  const chunks = splitIntoChunks(preparedOutput, chunkBudget);
  for (const chunk of chunks) {
    messages.push(chunk);
  }

  return messages;
}

function maybeWritePromptSubmitState(provider, eventName, input, tmuxMetadata) {
  const normalizedEvent = String(eventName || '').trim().toLowerCase();
  if (
    normalizedEvent !== 'userpromptsubmit' &&
    normalizedEvent !== 'user-prompt-submit' &&
    normalizedEvent !== 'prompt-submitted' &&
    normalizedEvent !== 'session.prompt-submitted'
  ) {
    return;
  }

  try {
    const promptText = input.prompt || input.user_prompt || input.message || '';
    const currentSessionId = getPromptSessionId(input);

    // Preserve first_prompt fields across turns
    const existingState = findPromptSubmitState(tmuxMetadata).state;
    const existingSessionId = existingState?.session_id || null;
    const isNewConversation = !existingState ||
      (currentSessionId !== null && existingSessionId !== null && existingSessionId !== currentSessionId);

    const state = {
      observed_at: new Date().toISOString(),
      provider,
      event_name: eventName,
      session_id: currentSessionId,
      turn_id: input.turn_id || input.turnId || null,
      prompt_summary: truncate(promptText),
      prompt_excerpt: truncate(promptText, 600),
      tmux_session: tmuxMetadata?.tmux_session || null,
      tmux_window: tmuxMetadata?.tmux_window || null,
      tmux_pane_index: tmuxMetadata?.tmux_pane_index || null,
      tmux_pane: tmuxMetadata?.tmux_pane || null,
      tmux_title: tmuxMetadata?.tmux_title || null,
    };

    if (isNewConversation) {
      state.first_prompt_summary = truncate(promptText);
      state.first_prompt_excerpt = truncate(promptText, 600);
    } else {
      state.first_prompt_summary = existingState.first_prompt_summary || state.prompt_summary;
      state.first_prompt_excerpt = existingState.first_prompt_excerpt || state.prompt_excerpt;
    }

    for (const key of getPaneStateKeyCandidates(tmuxMetadata)) {
      const path = join(NOTIFY_STATE_ROOT, 'prompt-submit', `${sanitizeStateSegment(key)}.json`);
      writeJsonFile(path, state);
    }
  } catch {}
}

function maybeEnrichStopEvent(payload, eventName, tmuxMetadata) {
  if (!isStopEvent(eventName)) {
    return;
  }
  try {
    const { state, path } = findPromptSubmitState(tmuxMetadata);
    if (!state) return;
    payload.stop_context = {
      last_prompt_at: state.observed_at || null,
      last_prompt_summary: state.prompt_summary || null,
      last_prompt_excerpt: state.prompt_excerpt || null,
      last_turn_id: state.turn_id || null,
      prompt_state_path: path,
    };
  } catch {}
}

function readPromptSubmitState(tmuxMetadata) {
  try {
    return findPromptSubmitState(tmuxMetadata).state;
  } catch {
    return null;
  }
}

function handleStopEvent({ cwd, input, tmuxMetadata, effectiveTmuxMetadata, promptStateContext, payload }) {
  // ── Stage 0: Resolve route ──────────────────────────────
  const stopRoute = resolveStopRoute(effectiveTmuxMetadata || {});
  if (!effectiveTmuxMetadata) {
    console.error('[clawhip] stop-notify: no tmux pane found');
    process.exit(0);
  }
  if (!stopRoute.matchedRoute) {
    const paneLabel = describeTmuxTarget(effectiveTmuxMetadata);
    console.error(`[clawhip] stop-notify: no matching pane route found${paneLabel ? ` for ${paneLabel}` : ''}`);
    process.exit(0);
  }
  if (!stopRoute.enabled) {
    process.exit(0);
  }

  let tmuxTarget = stopRoute.captureTarget || '';
  if (!tmuxTarget) {
    const paneLabel = describeTmuxTarget(effectiveTmuxMetadata);
    console.error(`[clawhip] stop-notify: no tmux pane found${paneLabel ? ` for ${paneLabel}` : ''}`);
    process.exit(0);
  }

  const webhookUrl = stopRoute.webhookUrl;
  const promptState = promptStateContext.state || readPromptSubmitState(effectiveTmuxMetadata);

  // ── Stage 1: Capture (decoupled — failure doesn't block send) ──
  let captureText = '';
  let captureOk = false;
  let paneCaptureStatePath = '';
  try {
    const captureDelay = Math.max(0, parseIntegerish(process.env.CLAWHIP_STOP_CAPTURE_DELAY_MS) || 400);
    if (captureDelay > 0) {
      sleepMs(Math.min(captureDelay, 2000)); // Cap at 2s to not block Codex
    }
    // When first_prompt_excerpt is available, capture more lines so we can find
    // the conversation start (including all turns), not just the last response.
    const effectiveCaptureLines = promptState?.first_prompt_excerpt
      ? Math.min(stopRoute.captureLines * 2, 5000)
      : stopRoute.captureLines;
    const capture = capturePaneOutputWithFallback(
      tmuxTarget,
      stopRoute.fallbackCaptureTarget,
      cwd,
      effectiveCaptureLines,
    );
    tmuxTarget = capture.target || tmuxTarget;
    if (capture.ok) {
      captureText = String(capture.text || '');
      captureOk = true;
    }
    paneCaptureStatePath = writePaneCaptureState(
      effectiveTmuxMetadata,
      tmuxTarget,
      capture.ok ? captureText : `tmux capture failed for ${tmuxTarget}: ${capture.error}`,
      capture.ok,
    );
    if (!capture.ok) {
      console.error(`[clawhip] stop-notify: tmux capture failed for ${tmuxTarget}: ${capture.error}`);
    }
  } catch (err) {
    console.error(`[clawhip] stop-notify: capture stage exception: ${err.message}`);
    try {
      writePaneCaptureState(effectiveTmuxMetadata, tmuxTarget, `capture exception: ${err.message}`, false);
    } catch {}
  }

  // ── Stage 2: Format (decoupled — failure uses raw text) ──
  let outputText = '';
  try {
    outputText = captureOk ? extractConversationTail(captureText, promptState) : captureText;
  } catch (err) {
    console.error(`[clawhip] stop-notify: extract conversation tail failed: ${err.message}`);
    outputText = captureText; // Fall back to raw capture
  }

  let messages = [];
  try {
    messages = formatStopMessages({
      outputText: outputText || captureText,
      chunkSize: stopRoute.chunkSize,
      mention: stopRoute.mention,
    });
  } catch (err) {
    console.error(`[clawhip] stop-notify: format messages failed: ${err.message}`);
    // Last resort: send raw text as single chunk
    const rawText = String(outputText || captureText || '').trim();
    if (rawText) {
      messages = [rawText.slice(0, stopRoute.chunkSize || DEFAULT_CHUNK_SIZE)];
    }
  }

  if (paneCaptureStatePath) {
    payload.stop_context = {
      ...(payload.stop_context || {}),
      pane_capture_path: paneCaptureStatePath,
    };
  }
  if (!tmuxMetadata && promptStateContext.recoveredFromPromptState) {
    payload.stop_context = {
      ...(payload.stop_context || {}),
      tmux_recovered_from_prompt_state: true,
      prompt_state_path: promptStateContext.path || null,
    };
  }

  // ── Stage 3: Send (fire-and-forget — never blocks Codex) ──
  try {
    const payloads = messages.length > 0
      ? messages.map((message, index) =>
          buildDiscordWebhookPayload(message, {
            isFirstMessage: index === 0,
            mention: stopRoute.mention,
            mode: DEFAULT_DISCORD_MESSAGE_MODE,
            embedColor: DEFAULT_DISCORD_EMBED_COLOR,
          }),
        )
      : [];

    if (payloads.length === 0) {
      console.error('[clawhip] stop-notify: no content to send after format stage');
      process.exit(0);
    }

    if (DEFAULT_DISCORD_DRY_RUN) {
      writeDryRunPreview(payloads, {
        webhookUrl: stopRoute.webhookUrl,
        tmuxTarget,
        mode: DEFAULT_DISCORD_MESSAGE_MODE,
      });
      process.exit(0);
    }

    if (!webhookUrl) {
      const envDetail = stopRoute.webhookEnvName
        ? stopRoute.webhookEnvName
        : 'CLAWHIP_DISCORD_WEBHOOK_URL or DISCORD_WEBHOOK_URL';
      console.error(`[clawhip] stop-notify: missing webhook env (${envDetail})`);
      process.exit(0);
    }

    const dispatch = queueDiscordDispatch({
      webhookUrl,
      payloads,
      cwd,
      chunkDelayMs: stopRoute.chunkDelayMs,
      tmuxTarget,
      mode: DEFAULT_DISCORD_MESSAGE_MODE,
    });
    console.error(
      `[clawhip] stop-notify: queued ${payloads.length} payload(s) for background delivery${dispatch.pid ? ` (pid=${dispatch.pid})` : ''}`,
    );
  } catch (err) {
    console.error(`[clawhip] stop-notify: send stage exception: ${err.message}`);
  }
  process.exit(0);
}

async function main() {
  const stopJobPath = arg('--run-stop-job');
  if (stopJobPath) {
    const stopJob = readJsonFile(stopJobPath);
    if (!stopJob) {
      appendStopDispatchLog(`failed to read stop job=${stopJobPath}`);
      process.exit(1);
    }
    if (stopJob.prepared_stop && typeof stopJob.prepared_stop === 'object') {
      appendStopDispatchLog(`worker start prepared job=${basename(stopJobPath)}`);
      processPreparedStopJob(stopJob.prepared_stop);
      return;
    }
    const provider = asNonEmptyString(stopJob.provider) || process.env.CLAWHIP_PROVIDER || 'unknown';
    const cwd = asNonEmptyString(stopJob.cwd) || process.cwd();
    const input = stopJob.input && typeof stopJob.input === 'object' ? stopJob.input : {};
    const eventCwd = input.cwd || input.directory || cwd;
    const worktreeRoot = inferWorktreeRoot(eventCwd);
    const repoRoot = inferRepoRoot(eventCwd);
    const projectMetadata =
      loadProjectMetadata(repoRoot) ||
      loadProjectMetadata(worktreeRoot) ||
      loadProjectMetadata(eventCwd);
    const tmuxMetadata = collectTmuxMetadata(input, cwd);
    const promptStateContext = findPromptSubmitStateForStop(input, tmuxMetadata);
    const effectiveTmuxMetadata = tmuxMetadata || promptStateContext.tmuxMetadata;
    const eventName =
      input.hook_event_name || input.hookEventName || input.event_name || input.event || 'unknown';
    appendStopDispatchLog(`worker start job=${basename(stopJobPath)} event=${eventName}`);
    const payload = {
      provider,
      source: provider,
      directory: eventCwd,
      repo_path: repoRoot,
      worktree_path: worktreeRoot,
      repo_name: basename(repoRoot),
      event_name: eventName,
      hook_event_name: eventName,
      session_id: input.session_id || input.sessionId,
      turn_id: input.turn_id || input.turnId,
      transcript_path: input.transcript_path || input.transcriptPath,
      model: input.model,
      tool_name: input.tool_name || input.toolName,
      tool_input: input.tool_input,
      tool_response: input.tool_response,
      prompt: input.prompt,
      notify_project_root: NOTIFY_PROJECT_ROOT || null,
      notify_state_root: NOTIFY_STATE_ROOT || null,
      event_payload: input,
    };
    const stablePaneRole = asNonEmptyString(process.env.CLAWHIP_NOTIFY_PANE_ROLE);
    if (stablePaneRole) {
      payload.pane_role = stablePaneRole;
    }
    if (effectiveTmuxMetadata) {
      Object.assign(payload, effectiveTmuxMetadata);
    }
    if (projectMetadata && typeof projectMetadata === 'object') {
      payload.project_metadata = projectMetadata;
      if (projectMetadata.name) payload.project = payload.project_name = projectMetadata.name;
      if (projectMetadata.id) payload.project_id = projectMetadata.id;
      if (projectMetadata.repo_name) payload.repo_name = projectMetadata.repo_name;
    }
    appendStopDispatchLog(`worker handling stop job=${basename(stopJobPath)} target=${describeTmuxTarget(effectiveTmuxMetadata)}`);
    handleStopEvent({cwd, input, tmuxMetadata, effectiveTmuxMetadata, promptStateContext, payload});
    return;
  }

  const provider = arg('--provider') || process.env.CLAWHIP_PROVIDER || 'unknown';
  const cwd = process.cwd();
  const raw = await readStdin();
  const input = parseJson(raw, {});
  const eventCwd = input.cwd || input.directory || cwd;
  const worktreeRoot = inferWorktreeRoot(eventCwd);
  const repoRoot = inferRepoRoot(eventCwd);
  const directTmuxEvidence = hasDirectTmuxEvidence(input);
  const projectMetadata =
    loadProjectMetadata(repoRoot) ||
    loadProjectMetadata(worktreeRoot) ||
    loadProjectMetadata(eventCwd);
  const tmuxMetadata = collectTmuxMetadata(input, cwd);
  const promptStateContext = directTmuxEvidence ? findPromptSubmitStateForStop(input, tmuxMetadata) : {
    state: null,
    path: '',
    tmuxMetadata: null,
    recoveredFromPromptState: false,
  };
  const effectiveTmuxMetadata = tmuxMetadata || promptStateContext.tmuxMetadata;
  const eventName =
    input.hook_event_name || input.hookEventName || input.event_name || input.event || 'unknown';
  logHookInvocation(provider, eventName, effectiveTmuxMetadata || tmuxMetadata, cwd, {
    projectRoot: NOTIFY_PROJECT_ROOT || '',
    stateRoot: NOTIFY_STATE_ROOT || '',
    repoRoot,
    worktreeRoot,
    paneRole: asNonEmptyString(process.env.CLAWHIP_NOTIFY_PANE_ROLE),
  });

  const payload = {
    provider,
    source: provider,
    directory: eventCwd,
    repo_path: repoRoot,
    worktree_path: worktreeRoot,
    repo_name: basename(repoRoot),
    event_name: eventName,
    hook_event_name: eventName,
    session_id: input.session_id || input.sessionId,
    turn_id: input.turn_id || input.turnId,
    transcript_path: input.transcript_path || input.transcriptPath,
    model: input.model,
    tool_name: input.tool_name || input.toolName,
    tool_input: input.tool_input,
    tool_response: input.tool_response,
    prompt: input.prompt,
    notify_project_root: NOTIFY_PROJECT_ROOT || null,
    notify_state_root: NOTIFY_STATE_ROOT || null,
    event_payload: input,
  };
  const stablePaneRole = asNonEmptyString(process.env.CLAWHIP_NOTIFY_PANE_ROLE);
  if (stablePaneRole) {
    payload.pane_role = stablePaneRole;
  }
  if (effectiveTmuxMetadata) {
    Object.assign(payload, effectiveTmuxMetadata);
  }

  if (projectMetadata && typeof projectMetadata === 'object') {
    payload.project_metadata = projectMetadata;
    if (projectMetadata.name) {
      payload.project = projectMetadata.name;
      payload.project_name = projectMetadata.name;
    }
    if (projectMetadata.id) {
      payload.project_id = projectMetadata.id;
    }
    if (projectMetadata.repo_name) {
      payload.repo_name = projectMetadata.repo_name;
    }
  }

  const augmentation = await collectAugmentation(payload);
  if (augmentation) {
    payload.augmentation = augmentation;
  }

  maybeWritePromptSubmitState(provider, eventName, input, effectiveTmuxMetadata);
  writePromptBoundaryState(provider, eventName, input, effectiveTmuxMetadata);
  maybeEnrichStopEvent(payload, eventName, effectiveTmuxMetadata);

  if (isPromptBoundaryEvent(eventName)) {
    process.exit(0);
  }

  if (isStopEvent(eventName)) {
    handleStopEvent({
      cwd: eventCwd,
      input,
      tmuxMetadata,
      effectiveTmuxMetadata,
      promptStateContext,
      payload,
    });
    return;
  }

  // Clawhip bridge has been removed — all notify logic now runs directly in this script.
  // The UserPromptSubmit and Stop events are handled above; other events fall through to here
  // and exit cleanly without needing an external bridge.
  process.exit(0);
}

main().catch((error) => {
  const detail =
    typeof error?.stack === 'string' && error.stack.trim()
      ? error.stack.trim()
      : typeof error?.message === 'string' && error.message.trim()
        ? error.message.trim()
        : String(error);
  console.error(`[clawhip] native hook wrapper failed: ${detail}`);
  process.exit(1);
});
