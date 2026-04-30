/* Blackjack — WASM bridge + game UI logic
 *
 * Pipeline: Ruby (blackjack.rb) → Spinel AOT → C → Emscripten → WASM
 * Each game action creates a fresh WASM instance (fast because the WASM
 * binary is pre-fetched and cached as an ArrayBuffer).
 */

const SUIT_SYMBOL = { S: '♠', H: '♥', D: '♦', C: '♣' };
const SUIT_CHARS  = ['S', 'H', 'D', 'C'];
const VAL_LABELS  = ['A','2','3','4','5','6','7','8','9','10','J','Q','K'];

// Pre-fetched WASM binary (ArrayBuffer) — avoids re-downloading per action
let wasmBinaryCache = null;

async function initWasm() {
  const resp        = await fetch('blackjack.wasm');
  wasmBinaryCache   = await resp.arrayBuffer();
}

// Run one blackjack command through a fresh WASM instance.
// stdin  = inputStr + newline
// stdout = captured into `output`
async function wasmRun(inputStr) {
  const bytes = new TextEncoder().encode(inputStr + '\n');
  let   pos   = 0;
  let   output = '';

  const opts = {
    noInitialRun: true,
    // stdin is read character-by-character; return null for EOF
    stdin:    () => pos < bytes.length ? bytes[pos++] : null,
    print:    (line) => { output = line; },
    printErr: () => {},
  };
  if (wasmBinaryCache) opts.wasmBinary = wasmBinaryCache;

  const M = await createBlackjack(opts);

  try {
    M.callMain([]);
  } catch (e) {
    // Emscripten throws ExitStatus when main() calls exit()
    if (!e || e.name !== 'ExitStatus') console.error('[wasm]', e);
  }

  return output;
}

// ── Card helpers ──────────────────────────────────────────────────────────────
function cardSuitChar(c)  { return SUIT_CHARS[Math.floor(c / 13)]; }
function cardValueLabel(c) { return VAL_LABELS[c % 13]; }
function isRedCard(c)     { const s = Math.floor(c / 13); return s === 1 || s === 2; }

function cardPoints(c) {
  const v = c % 13;
  if (v === 0) return 11;
  if (v >= 10) return 10;
  return v + 1;
}

function handScore(cards) {
  let total = 0, aces = 0;
  for (const c of cards) {
    const p = cardPoints(c);
    if (p === 11) aces++;
    total += p;
  }
  while (total > 21 && aces > 0) { total -= 10; aces--; }
  return total;
}

// ── State serialization ───────────────────────────────────────────────────────
function encodeCards(arr)  { return arr.join(','); }
function decodeCards(s)    { return s ? s.split(',').filter(Boolean).map(Number) : []; }

function buildInput(cmd, state) {
  const seed = Math.floor(Math.random() * 2_000_000_000) + 1;
  return [
    cmd,
    state.chips,
    state.bet,
    seed,
    encodeCards(state.playerCards),
    encodeCards(state.dealerCards),
    encodeCards(state.deck),
  ].join('|');
}

function parseOutput(line, fallback) {
  if (!line) return fallback;
  const p = line.split('|');
  return {
    phase:       p[0] || 'error',
    result:      p[1] || '',
    chips:       parseInt(p[2]) || fallback.chips,
    bet:         parseInt(p[3]) || fallback.bet,
    message:     p[4] || '',
    playerCards: decodeCards(p[5]),
    dealerCards: decodeCards(p[6]),
    deck:        decodeCards(p[7]),
  };
}

// ── Game state ────────────────────────────────────────────────────────────────
let state = {
  phase: 'idle', result: '', chips: 1000, bet: 100,
  message: '', playerCards: [], dealerCards: [], deck: [],
};

async function sendCommand(cmd) {
  setUI(false);
  try {
    const out  = await wasmRun(buildInput(cmd, state));
    state      = parseOutput(out, state);
  } catch (e) {
    console.error(e);
    state.message = 'Error: ' + e.message;
  }
  render();
}

// ── DOM helpers ───────────────────────────────────────────────────────────────
function makeCardEl(cardIndex, hidden) {
  const el = document.createElement('div');
  el.className = 'card' + (hidden ? ' card-hidden' : '');
  if (hidden) {
    el.innerHTML = '<div class="card-back"></div>';
    return el;
  }
  const v   = cardValueLabel(cardIndex);
  const sym = SUIT_SYMBOL[cardSuitChar(cardIndex)];
  el.classList.add(isRedCard(cardIndex) ? 'card-red' : 'card-black');
  el.innerHTML =
    `<div class="card-corner top"><span class="cv">${v}</span><span class="cs">${sym}</span></div>` +
    `<div class="card-center">${sym}</div>` +
    `<div class="card-corner bot"><span class="cv">${v}</span><span class="cs">${sym}</span></div>`;
  return el;
}

function renderHand(id, cards, hideSecond) {
  const el = document.getElementById(id);
  el.innerHTML = '';
  cards.forEach((c, i) => {
    const card = makeCardEl(c, hideSecond && i === 1);
    card.style.animationDelay = (i * 0.12) + 's';
    el.appendChild(card);
  });
}

function renderScore(id, cards, hideSecond) {
  const el = document.getElementById(id);
  if (!cards.length) { el.textContent = ''; return; }
  const visible = hideSecond && cards.length >= 2 ? [cards[0]] : cards;
  el.textContent = handScore(visible);
}

function resultLabel(r) {
  const map = { win: 'You Win!', blackjack: 'Blackjack!', push: 'Push', bust: 'Bust', lose: 'Dealer Wins' };
  return map[r] || '';
}

// ── Render ────────────────────────────────────────────────────────────────────
function render() {
  const playing  = state.phase === 'playing';
  const gameover = state.phase === 'gameover';
  const idle     = state.phase === 'idle';

  renderHand('dealer-cards', state.dealerCards, playing);
  renderHand('player-cards', state.playerCards, false);
  renderScore('dealer-score', state.dealerCards, playing);
  renderScore('player-score', state.playerCards, false);

  document.getElementById('chips-display').textContent = state.chips;
  document.getElementById('bet-display').textContent   = state.bet;

  const msg     = document.getElementById('message');
  msg.textContent = state.message || '';
  msg.className   = 'message ' + (state.result || '');

  // Result overlay
  const overlay = document.getElementById('result-overlay');
  if (gameover && state.result) {
    overlay.className = 'result-overlay show ' + state.result;
    overlay.querySelector('.result-text').textContent = resultLabel(state.result);
    overlay.querySelector('.result-sub').textContent  = state.message;
  } else {
    overlay.className = 'result-overlay';
  }

  // Buttons
  $('btn-deal').style.display  = (idle || gameover) ? '' : 'none';
  $('btn-hit').style.display   = playing ? '' : 'none';
  $('btn-stand').style.display = playing ? '' : 'none';
  $('btn-bet-up').disabled     = playing;
  $('btn-bet-dn').disabled     = playing;
  $('btn-reset').style.display = (gameover && state.chips <= 0) ? '' : 'none';

  setUI(true);
}

function setUI(enabled) {
  ['btn-deal','btn-hit','btn-stand','btn-bet-up','btn-bet-dn'].forEach(id => {
    const el = $(id);
    if (el) el.disabled = !enabled;
  });
}

function changeBet(delta) {
  if (state.phase === 'playing') return;
  const next = state.bet + delta;
  if (next < 10 || next > state.chips) return;
  state.bet = next;
  $('bet-display').textContent = state.bet;
}

function resetGame() {
  state = { phase:'idle', result:'', chips:1000, bet:100,
            message:'', playerCards:[], dealerCards:[], deck:[] };
  render();
}

function $(id) { return document.getElementById(id); }

// ── Init ──────────────────────────────────────────────────────────────────────
window.addEventListener('DOMContentLoaded', async () => {
  $('loading').style.display = '';

  $('btn-deal') .addEventListener('click', () => sendCommand('new'));
  $('btn-hit')  .addEventListener('click', () => sendCommand('hit'));
  $('btn-stand').addEventListener('click', () => sendCommand('stand'));
  $('btn-bet-up').addEventListener('click', () => changeBet( 10));
  $('btn-bet-dn').addEventListener('click', () => changeBet(-10));
  $('btn-reset') .addEventListener('click', resetGame);

  try {
    await initWasm();
  } catch (e) {
    console.error('WASM load failed:', e);
    $('message').textContent = 'WASM load failed — see console.';
  }

  $('loading').style.display = 'none';
  render();
});
