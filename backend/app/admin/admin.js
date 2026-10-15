/* Hausgeist Verwaltung: Räume, Geräte, Tablets und Display-Verhalten. Ohne Build-Schritt, ohne Fremd-Bibliotheken. */
'use strict';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const DOMAINS = {
  light: 'Licht', switch: 'Schalter', climate: 'Klima', cover: 'Rollos', fan: 'Ventilatoren',
  media_player: 'Medien', lock: 'Schlösser', scene: 'Szenen', input_boolean: 'Helfer',
  sensor: 'Sensoren', binary_sensor: 'Melder',
};
const PRESENCE_CLASSES = ['occupancy', 'presence', 'motion'];
const PROVIDERS = { openai: 'OpenAI', xai: 'Grok (xAI)', custom: 'Eigener Server', elevenlabs: 'ElevenLabs' };
const WAKE_MODES ={ both: 'Kamera und Präsenzmelder', camera: 'Nur Kamera', sensor: 'Nur Präsenzmelder' };

// Display-Felder: [Schlüssel, Beschriftung, Einheit, Hilfe, min, max, Prozent?]
const DISPLAY_FIELDS = [
  ['dim_after', 'Dimmen nach', 's', 'Ohne Berührung, solange jemand im Raum ist', 5, 3600],
  ['sleep_after', 'Ausschalten nach', 's', 'Ohne Berührung und ohne Bewegung', 10, 7200],
  ['presence_hold', 'Raum gilt besetzt für', 's', 'Nach der letzten erkannten Bewegung', 10, 3600],
  ['near_motion_area', 'Annäherung ab', '%', 'Bildanteil der Bewegung, ab dem es hell wird', 1, 100, true],
  ['min_brightness', 'Mindesthelligkeit', '%', 'Bei Dunkelheit im Raum', 0, 100, true],
  ['max_brightness', 'Höchsthelligkeit', '%', 'Bei hellem Raum', 0, 100, true],
  ['idle_factor', 'Gedimmt auf', '%', 'Anteil der normalen Helligkeit', 0, 100, true],
  ['night_start', 'Nacht ab', 'Uhr', 'Dunkles Design und Helligkeitsgrenze', 0, 23],
  ['night_end', 'Nacht bis', 'Uhr', '', 0, 23],
  ['night_max_brightness', 'Nachts höchstens', '%', 'Damit nachts nichts blendet', 0, 100, true],
];
const DISPLAY_DEFAULTS = {
  wake_mode: 'both', dim_after: 30, sleep_after: 120, presence_hold: 90, near_motion_area: 0.2,
  min_brightness: 0.02, max_brightness: 1, idle_factor: 0.35, night_start: 22, night_end: 6, night_max_brightness: 0.15,
  voice_wake: true,
};

// ---------- API ----------
// Sitzungs-Token aus der Anmeldung (oder der ADMIN_KEY des Containers)
let key = sessionStorage.getItem('hg-key') || localStorage.getItem('hg-key') || '';

class AuthError extends Error {
  constructor(msg, setup = false) {
    super(msg);
    this.setup = setup; // Server ist noch nicht eingerichtet
  }
}

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: { 'x-admin-key': key, ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401 && !path.startsWith('/api/admin/login')) throw new AuthError('Bitte erneut anmelden.');
  if (res.status === 503) throw new AuthError('Hausgeist ist noch nicht eingerichtet.', true);
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const detail = data?.detail;
    throw new Error(Array.isArray(detail) ? detail.map((d) => d.msg).join(', ') : detail || `Fehler ${res.status}`);
  }
  return data;
}

// ---------- Rahmen ----------
function toast(msg, bad = false) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.toggle('bad', bad);
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), bad ? 6000 : 3000);
}

function showOnly(id) {
  for (const x of ['setup', 'login', 'app']) $(`#${x}`).hidden = x !== id;
}

function showLogin(error) {
  showOnly('login');
  $('#login-error').hidden = !error;
  $('#login-error').textContent = error || '';
  $('#login-key').focus();
}

function showSetup() {
  showOnly('setup');
  $('#setup-form').password.focus();
}

function forgetKey() {
  key = '';
  sessionStorage.removeItem('hg-key');
  localStorage.removeItem('hg-key');
}

function storeKey(token, remember) {
  key = token;
  (remember ? localStorage : sessionStorage).setItem('hg-key', token);
}

/** Abgelaufene Anmeldung oder noch nicht eingerichteter Server. */
function authFailed(err) {
  forgetKey();
  err.setup ? showSetup() : showLogin(err.message);
}

$('#login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = $('button[type=submit]', e.target);
  btn.disabled = true;
  try {
    const r = await api('POST', '/api/admin/login', { password: $('#login-key').value });
    storeKey(r.token, $('#login-remember').checked);
    $('#login-key').value = '';
    start();
  } catch (err) {
    err instanceof AuthError && err.setup ? showSetup() : showLogin(err.message);
  } finally {
    btn.disabled = false;
  }
});

$('#setup-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const f = e.target;
  const error = (msg) => { $('#setup-error').textContent = msg; $('#setup-error').hidden = !msg; };
  if (f.password.value !== f.repeat.value) return error('Die beiden Passwörter sind nicht gleich.');
  try {
    const r = await api('POST', '/api/setup', { password: f.password.value });
    storeKey(r.token, true);
    f.reset();
    error('');
    location.hash = '#/einrichtung/1';
    start();
  } catch (err) {
    error(err.message);
  }
});

$('#logout').addEventListener('click', () => {
  fetch('/api/admin/logout', { method: 'POST', headers: { 'x-admin-key': key } }).catch(() => {});
  forgetKey();
  showLogin();
});

function start() {
  showOnly('app');
  route();
}

// Ein einfacher Hash-Router: #/raeume/<id>, #/einstellungen/sprache usw.
const routes = {
  uebersicht: viewOverview,
  raeume: (id) => (id ? viewRoom(id) : viewRooms()),
  tablets: (id) => (id ? viewTablet(id) : viewTablets()),
  einstellungen: (id) => viewSettings(id),
  einrichtung: (id) => viewWizard(id),
};
let renderId = 0;

async function route() {
  const [name = 'uebersicht', id] = location.hash.replace(/^#\/?/, '').split('/');
  const view = routes[name] ? name : 'uebersicht';
  $$('[data-nav]').forEach((a) => a.classList.toggle('on', a.dataset.nav === view));
  const el = $('#view');
  const mine = ++renderId;
  el.innerHTML = '<p class="muted">Lade …</p>';
  try {
    const html = await routes[view](id ? decodeURIComponent(id) : undefined);
    if (mine !== renderId) return; // inzwischen weiternavigiert
    el.innerHTML = html.html ?? html;
    html.bind?.(el);
  } catch (err) {
    if (err instanceof AuthError) return authFailed(err);
    el.innerHTML = `<div class="glass card"><h3>Das hat nicht geklappt</h3><p class="error">${esc(err.message)}</p></div>`;
  }
  if (document.activeElement === document.body) el.focus({ preventScroll: true });
}
window.addEventListener('hashchange', () => {
  if ($('#dialog').open) $('#dialog').close(); // z. B. Zurück-Taste: Dialog gehört zur alten Seite
  route();
});

/** Führt eine Aktion aus und zeigt Fehler als Hinweis. */
async function run(fn, okMsg) {
  try {
    const r = await fn();
    if (okMsg) toast(okMsg);
    return r ?? true;
  } catch (err) {
    if (err instanceof AuthError) return authFailed(err), false;
    toast(err.message, true);
    return false;
  }
}

// Abbrechen-Knöpfe in Dialogen schließen ohne Absenden (Enter löst so immer die Hauptaktion aus).
$('#dialog').addEventListener('click', (e) => {
  if (e.target.closest('[data-close]')) $('#dialog').close();
});

function dialog(html, bind) {
  const d = $('#dialog');
  d.innerHTML = html;
  bind?.(d);
  d.showModal();
  return d;
}

const entityName = (s) => s.attributes?.friendly_name || s.entity_id;
const domainOf = (id) => id.split('.')[0];
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

// ---------- Übersicht ----------
async function viewOverview() {
  const [st, rooms, tablets] = await Promise.all([api('GET', '/api/status'), api('GET', '/api/rooms'), api('GET', '/api/tablets')]);
  const okDot = (ok, yes, no) => `<span class="dot ${ok ? 'ok' : ''}">${ok ? yes : no}</span>`;
  const voiceOk = st.voice.stt_ok && st.voice.llm_ok && st.voice.tts_ok;
  const steps = [
    [st.ha.connected, 'Home Assistant verbinden', '#/einrichtung/1'],
    [voiceOk, 'Sprachassistent einrichten', '#/einrichtung/2'],
    [rooms.some((r) => r.entity_ids.length), 'Räume und Geräte anlegen', '#/einrichtung/3'],
    [tablets.length > 0, 'Tablet koppeln', '#/einrichtung/4'],
  ];
  const next = steps.find((s) => !s[0]);
  return `
    <div class="head"><div><h1>Übersicht</h1><p class="muted small">Hausgeist ${esc(st.version)}</p></div></div>
    ${next ? `
      <section class="glass card"><h2>Einrichtung</h2><ol class="steps">
        ${steps.map(([done, t, href]) => `<li>${done ? '✓ ' : ''}<a href="${href}"><b>${t}</b></a></li>`).join('')}
        </ol>
        <div style="margin-top:14px"><a class="btn primary" href="${next[2]}">${steps.some((s) => s[0]) ? 'Einrichtung fortsetzen' : 'Einrichtung starten'}</a></div>
      </section>` : ''}
    <div class="cards">
      <a class="glass card" href="#/einstellungen/homeassistant"><h2>Home Assistant</h2>
        <div class="kv"><span>Verbindung</span>${okDot(st.ha.connected, 'Verbunden', st.ha.token_set ? (st.ha.error || 'Getrennt') : 'Token fehlt')}</div>
        <div class="kv"><span>Adresse</span><span>${esc(st.ha.url)}</span></div>
        <div class="kv"><span>Geräte</span><span>${st.ha.entities ?? '–'}</span></div>
      </a>
      <a class="glass card" href="#/einstellungen/sprache"><h2>Sprachassistent</h2>
        <div class="kv"><span>Spracherkennung</span>${okDot(st.voice.stt_ok, PROVIDERS[st.voice.stt] || st.voice.stt, 'nicht eingerichtet')}</div>
        <div class="kv"><span>Antworten</span>${okDot(st.voice.llm_ok, PROVIDERS[st.voice.llm] || st.voice.llm, 'nicht eingerichtet')}</div>
        <div class="kv"><span>Stimme</span>${okDot(st.voice.tts_ok, PROVIDERS[st.voice.tts] || st.voice.tts, 'nicht eingerichtet')}</div>
      </a>
      <section class="glass card"><h2>Tablets</h2>
        <div class="kv"><span>Online</span><span>${st.tablets_online} von ${tablets.length}</span></div>
        <div class="kv"><span>Räume</span><span>${rooms.length}</span></div>
        <div class="kv"><span>Ohne Raum</span><span>${tablets.filter((t) => !t.room_id).length}</span></div>
      </section>
    </div>`;
}

// ---------- Räume ----------
async function viewRooms() {
  const [rooms, tablets] = await Promise.all([api('GET', '/api/rooms'), api('GET', '/api/tablets')]);
  const cards = rooms.map((r) => {
    const tabs = tablets.filter((t) => t.room_id === r.id);
    return `<a class="glass card" href="#/raeume/${encodeURIComponent(r.id)}">
      <h3>${esc(r.name)}</h3>
      <div class="muted small">${plural(r.entity_ids.length, 'Gerät', 'Geräte')}${r.presence_entity ? ' · Präsenzmelder' : ''}${r.ha_area_id ? ' · aus Home Assistant' : ''}</div>
      <div class="chips">${tabs.map((t) => `<span class="chip">${esc(t.name)}</span>`).join('') || '<span class="chip">Kein Tablet</span>'}</div>
    </a>`;
  });
  return {
    html: `
      <div class="head"><h1>Räume</h1><div class="actions">
        <button class="btn" id="import">Aus Home Assistant übernehmen</button>
        <button class="btn primary" id="add">Raum anlegen</button></div></div>
      ${cards.length ? `<div class="cards">${cards.join('')}</div>` : '<div class="glass card empty">Noch keine Räume. Lege einen an oder übernimm die Bereiche aus Home Assistant.</div>'}`,
    bind(el) {
      $('#add', el).onclick = addRoomDialog;
      $('#import', el).onclick = importAreasDialog;
    },
  };
}

function addRoomDialog() {
  dialog(`<form method="dialog"><h2>Raum anlegen</h2>
      <label class="field"><span>Name</span><input type="text" name="name" required maxlength="60" placeholder="z. B. Wohnzimmer"></label>
      <div class="actions"><button type="button" class="btn" data-close>Abbrechen</button><button class="btn primary">Anlegen</button></div></form>`,
  (d) => {
    $('form', d).onsubmit = async (e) => {
      e.preventDefault();
      const r = await run(() => api('POST', '/api/rooms', { name: e.target.name.value.trim() }));
      if (r) {
        d.close();
        location.hash = `#/raeume/${r.id}`;
      }
    };
  });
}

async function importAreasDialog() {
  const d = dialog('<h2>Bereiche aus Home Assistant</h2><p class="muted">Lade …</p>');
  let areas;
  try {
    areas = await api('GET', '/api/ha/areas');
  } catch (err) {
    d.innerHTML = `<form method="dialog"><h2>Bereiche aus Home Assistant</h2><p class="error">${esc(err.message)}</p>
      <div class="actions"><button class="btn">Schließen</button></div></form>`;
    return;
  }
  d.innerHTML = `<form method="dialog"><h2>Bereiche aus Home Assistant</h2>
    <p class="muted small">Für jeden Bereich wird ein Raum angelegt (oder der verknüpfte aktualisiert) und die Geräte darin werden zugewiesen.</p>
    ${areas.length ? `<div class="picker" style="max-height:44vh">${areas.map((a) => `
      <label class="ent"><input type="checkbox" name="area" value="${esc(a.area_id)}" ${a.entity_ids.length ? 'checked' : ''}>
        <span>${esc(a.name)}<small>${plural(a.entity_ids.length, 'Gerät', 'Geräte')}${a.room_id ? ' · schon verknüpft' : ''}</small></span><span></span></label>`).join('')}</div>`
    : '<p class="empty">In Home Assistant sind keine Bereiche angelegt.</p>'}
    <label class="check"><input type="checkbox" name="replace"> Geräteliste ersetzen statt ergänzen</label>
    <div class="actions"><button type="button" class="btn" data-close>Abbrechen</button><button class="btn primary" ${areas.length ? '' : 'disabled'}>Übernehmen</button></div></form>`;
  $('form', d).onsubmit = async (e) => {
    e.preventDefault();
    const ids = $$('input[name=area]:checked', d).map((i) => i.value);
    const r = await run(() => api('POST', '/api/rooms/import-areas', { area_ids: ids, replace_entities: e.target.replace.checked }));
    if (r) {
      d.close();
      toast(`${plural(r.created.length, 'Raum', 'Räume')} angelegt, ${r.updated.length} aktualisiert`);
      route();
    }
  };
}

async function viewRoom(id) {
  const [rooms, states, tablets] = await Promise.all([api('GET', '/api/rooms'), api('GET', '/api/entities'), api('GET', '/api/tablets')]);
  const room = rooms.find((r) => r.id === id);
  if (!room) throw new Error('Raum nicht gefunden');
  const selected = new Set(room.entity_ids);
  const known = new Set(states.map((s) => s.entity_id));
  const missing = room.entity_ids.filter((e) => !known.has(e));
  // Präsenzmelder: binary_sensor zuerst nach Gerätetyp sortiert
  const presence = states.filter((s) => domainOf(s.entity_id) === 'binary_sensor')
    .sort((a, b) => (PRESENCE_CLASSES.includes(b.attributes.device_class) - PRESENCE_CLASSES.includes(a.attributes.device_class)) || entityName(a).localeCompare(entityName(b)));
  const tabs = tablets.filter((t) => t.room_id === id);
  let onlySelected = false;
  let filter = '';
  let dirty = false;

  function renderPicker() {
    const q = filter.toLowerCase();
    const list = states.filter((s) => (!onlySelected || selected.has(s.entity_id))
      && (!q || entityName(s).toLowerCase().includes(q) || s.entity_id.includes(q)));
    const groups = Object.keys(DOMAINS).map((dom) => [dom, list.filter((s) => domainOf(s.entity_id) === dom)
      .sort((a, b) => selected.has(b.entity_id) - selected.has(a.entity_id) || entityName(a).localeCompare(entityName(b)))]).filter(([, l]) => l.length);
    return groups.map(([dom, l]) => `<div class="group">${DOMAINS[dom]}</div>${l.map((s) => `
      <label class="ent"><input type="checkbox" value="${esc(s.entity_id)}" ${selected.has(s.entity_id) ? 'checked' : ''}>
        <span>${esc(entityName(s))}<small>${esc(s.entity_id)}</small></span><span class="state">${esc(s.state)}${s.attributes.unit_of_measurement ? ' ' + esc(s.attributes.unit_of_measurement) : ''}</span></label>`).join('')}`).join('')
      || '<p class="empty">Keine passenden Geräte.</p>';
  }

  return {
    html: `
      <a class="back" href="#/raeume">‹ Räume</a>
      <div class="head"><h1>${esc(room.name)}</h1><div class="actions"><button class="btn danger" id="del">Raum löschen</button></div></div>
      <div class="cols">
        <section class="glass card">
          <h2>Geräte im Raum</h2>
          <div class="picker-tools">
            <input type="search" id="q" placeholder="Suchen nach Name oder entity_id" aria-label="Geräte suchen">
            <label class="check small"><input type="checkbox" id="only"> Nur ausgewählte</label>
          </div>
          <div class="picker" id="picker">${renderPicker()}</div>
          ${missing.length ? `<p class="muted small">Nicht mehr in Home Assistant: ${missing.map(esc).join(', ')}</p>` : ''}
          <div class="savebar glass"><span class="small" id="count">${plural(selected.size, 'Gerät', 'Geräte')} ausgewählt</span>
            <button class="btn primary" id="save" disabled>Speichern</button></div>
        </section>
        <div class="stack">
          <section class="glass card"><h2>Name</h2>
            <form class="row-inline" id="rename"><label class="field"><span>Raumname</span><input type="text" name="name" value="${esc(room.name)}" required maxlength="60"></label>
              <button class="btn">Umbenennen</button></form>
          </section>
          <section class="glass card"><h2>Präsenzmelder</h2>
            <p class="muted small" style="margin-top:0">Meldet er Anwesenheit, wachen die Tablets im Raum auf, auch ohne Kamera.</p>
            <select id="presence" aria-label="Präsenzmelder"><option value="">Keiner</option>
              ${presence.map((s) => `<option value="${esc(s.entity_id)}" ${s.entity_id === room.presence_entity ? 'selected' : ''}>${esc(entityName(s))}${s.attributes.device_class ? ` (${esc(s.attributes.device_class)})` : ''}</option>`).join('')}
            </select>
          </section>
          <section class="glass card"><h2>Tablets</h2>
            ${tabs.length ? tabs.map((t) => `<div class="kv"><a href="#/tablets/${encodeURIComponent(t.id)}">${esc(t.name)}</a><span class="dot ${t.online ? 'ok' : ''}">${t.online ? 'Online' : 'Offline'}</span></div>`).join('')
              : '<p class="muted small" style="margin:0">Noch kein Tablet in diesem Raum. <a href="#/tablets">Tablet zuweisen</a></p>'}
          </section>
        </div>
      </div>`,
    bind(el) {
      const picker = $('#picker', el);
      const save = $('#save', el);
      const refresh = () => (picker.innerHTML = renderPicker());
      $('#q', el).oninput = (e) => { filter = e.target.value; refresh(); };
      $('#only', el).onchange = (e) => { onlySelected = e.target.checked; refresh(); };
      picker.onchange = (e) => {
        if (e.target.type !== 'checkbox') return;
        e.target.checked ? selected.add(e.target.value) : selected.delete(e.target.value);
        dirty = true;
        save.disabled = false;
        $('#count', el).textContent = `${plural(selected.size, 'Gerät', 'Geräte')} ausgewählt`;
      };
      save.onclick = async () => {
        if (await run(() => api('PUT', `/api/rooms/${id}/entities`, { entity_ids: [...selected] }), 'Geräte gespeichert')) {
          dirty = false;
          save.disabled = true;
        }
      };
      window.onbeforeunload = () => (dirty ? true : undefined);
      $('#rename', el).onsubmit = async (e) => {
        e.preventDefault();
        if (await run(() => api('PATCH', `/api/rooms/${id}`, { name: e.target.name.value.trim() }), 'Umbenannt')) {
          $('h1', el).textContent = e.target.name.value.trim();
        }
      };
      $('#presence', el).onchange = (e) => run(() => api('PUT', `/api/rooms/${id}/presence`, { entity_id: e.target.value || null }), 'Präsenzmelder gespeichert');
      $('#del', el).onclick = async () => {
        if (!confirm(`Raum „${room.name}“ löschen? Tablets darin haben danach keinen Raum mehr.`)) return;
        if (await run(() => api('DELETE', `/api/rooms/${id}`), 'Raum gelöscht')) {
          dirty = false;
          location.hash = '#/raeume';
        }
      };
    },
  };
}

// ---------- Tablets ----------
function roomOptions(rooms, current) {
  return `<option value="" ${current ? '' : 'selected'}>Kein Raum</option>` + rooms.map((r) => `<option value="${esc(r.id)}" ${r.id === current ? 'selected' : ''}>${esc(r.name)}</option>`).join('');
}

async function viewTablets() {
  const [tablets, rooms] = await Promise.all([api('GET', '/api/tablets'), api('GET', '/api/rooms')]);
  const rows = tablets.map((t) => `
    <div class="trow">
      <div><a href="#/tablets/${encodeURIComponent(t.id)}"><b>${esc(t.name)}</b></a>
        <small>${t.pair_code ? `Kopplungscode ${esc(t.pair_code.replace(/(\d{3})(\d{3})/, '$1 $2'))}` : WAKE_MODES[t.display.wake_mode]}</small></div>
      <select data-id="${esc(t.id)}" aria-label="Raum für ${esc(t.name)}">${roomOptions(rooms, t.room_id)}</select>
      <span class="dot ${t.online ? 'ok' : t.pair_code ? 'warn' : ''}">${t.online ? 'Online' : t.pair_code ? 'Wartet' : 'Offline'}</span>
      <a class="btn" href="#/tablets/${encodeURIComponent(t.id)}">Einstellungen</a>
    </div>`);
  return {
    html: `
      <div class="head"><h1>Tablets</h1><div class="actions"><button class="btn primary" id="add">Tablet hinzufügen</button></div></div>
      <section class="glass card">${rows.length ? `<div class="list">${rows.join('')}</div>` : '<p class="empty">Noch keine Tablets. Füge eins hinzu und gib den Kopplungscode in der App ein.</p>'}</section>`,
    bind(el) {
      $('#add', el).onclick = () => addTabletDialog(rooms);
      $$('select[data-id]', el).forEach((s) => (s.onchange = () => run(() => api('PATCH', `/api/tablets/${s.dataset.id}`, { room_id: s.value || null }), 'Raum zugewiesen')));
    },
  };
}

function addTabletDialog(rooms) {
  dialog(`<form method="dialog"><h2>Tablet hinzufügen</h2>
      <label class="field"><span>Name</span><input type="text" name="name" required maxlength="60" placeholder="z. B. Wand Wohnzimmer"></label>
      <label class="field"><span>Raum</span><select name="room">${roomOptions(rooms, rooms[0]?.id)}</select></label>
      <div class="actions"><button type="button" class="btn" data-close>Abbrechen</button><button class="btn primary">Hinzufügen</button></div></form>`,
  (d) => {
    $('form', d).onsubmit = async (e) => {
      e.preventDefault();
      const r = await run(() => api('POST', '/api/tablets', { name: e.target.name.value.trim(), room_id: e.target.room.value || null }));
      if (r) {
        pairDialog(e.target.name.value.trim(), r);
        route();
      }
    };
  });
}

/** Zeigt Kopplungscode (und optional den Token) für die Einrichtung am Tablet. */
function pairDialog(name, { pair_code: code, pair_expires: expires, token }) {
  const d = dialog(`<form method="dialog"><h2>${esc(name)} koppeln</h2>
      <ol class="steps">
        <li>Hausgeist-App auf dem Tablet öffnen</li>
        <li>Server: <b>${esc(location.origin)}</b></li>
        <li>Diesen Code eingeben:</li>
      </ol>
      <div class="code" aria-label="Kopplungscode">${esc(code.replace(/(\d{3})(\d{3})/, '$1 $2'))}</div>
      <p class="muted small" id="expires" style="margin:0;text-align:center"></p>
      ${token ? `<details><summary>Stattdessen Token eintragen</summary><p class="token">${esc(token)}</p>
        <button type="button" class="btn small" id="copy">Token kopieren</button></details>` : ''}
      <div class="actions"><button class="btn primary">Fertig</button></div></form>`,
  (dlg) => {
    $('#copy', dlg)?.addEventListener('click', () => navigator.clipboard?.writeText(token).then(() => toast('Token kopiert')));
  });
  const tick = () => {
    const left = Math.round(expires - Date.now() / 1000);
    const el = $('#expires', d);
    if (!el) return clearInterval(timer);
    el.textContent = left > 0 ? `Gültig noch ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')} min` : 'Abgelaufen, bitte neuen Code erzeugen';
  };
  const timer = setInterval(tick, 1000);
  tick();
  d.addEventListener('close', () => { clearInterval(timer); route(); }, { once: true });
}

async function viewTablet(id) {
  const [tablets, rooms] = await Promise.all([api('GET', '/api/tablets'), api('GET', '/api/rooms')]);
  const t = tablets.find((x) => x.id === id);
  if (!t) throw new Error('Tablet nicht gefunden');
  const disp = t.display;
  const field = ([k, label, unit, help, min, max, pct]) => `
    <label class="field"><span>${label} (${unit})</span>
      <input type="number" name="${k}" min="${min}" max="${max}" step="${pct ? 1 : 1}" value="${pct ? Math.round(disp[k] * 100) : disp[k]}" required>
      ${help ? `<small>${help}</small>` : ''}</label>`;
  return {
    html: `
      <a class="back" href="#/tablets">‹ Tablets</a>
      <div class="head"><div><h1>${esc(t.name)}</h1><span class="dot ${t.online ? 'ok' : ''}">${t.online ? 'Online' : 'Offline'}</span></div>
        <div class="actions"><button class="btn" id="pair">Neuer Kopplungscode</button><button class="btn" id="rotate">Token erneuern</button><button class="btn danger" id="del">Entfernen</button></div></div>
      <div class="cols">
        <section class="glass card"><h2>Display</h2>
          <form id="display">
            <label class="field" style="margin-bottom:14px"><span>Aufwecken durch</span>
              <select name="wake_mode">${Object.entries(WAKE_MODES).map(([v, l]) => `<option value="${v}" ${v === disp.wake_mode ? 'selected' : ''}>${l}</option>`).join('')}</select>
              <small>Kamera: Bewegung vor dem Tablet. Präsenzmelder: der Melder des Raums.</small></label>
            <div class="form-grid">${DISPLAY_FIELDS.map(field).join('')}</div>
            <label class="check" style="margin-top:16px"><input type="checkbox" name="voice_wake" ${disp.voice_wake ? 'checked' : ''}> Auf das Aktivierungswort hören</label>
            <small class="muted small" style="display:block;margin:4px 0 0 28px">Wort und Empfindlichkeit unter <a href="#/einstellungen/sprache">Einstellungen → Sprachassistent</a></small>
            <div class="row-inline" style="justify-content:flex-end;margin-top:16px">
              <button type="button" class="btn" id="defaults">Standardwerte</button><button class="btn primary">Speichern</button></div>
          </form>
        </section>
        <div class="stack">
          <section class="glass card"><h2>Allgemein</h2>
            <form class="stack" id="general" style="gap:12px">
              <label class="field"><span>Name</span><input type="text" name="name" value="${esc(t.name)}" required maxlength="60"></label>
              <label class="field"><span>Raum</span><select name="room">${roomOptions(rooms, t.room_id)}</select></label>
              <div><button class="btn primary">Speichern</button></div>
            </form>
          </section>
          <section class="glass card"><h2>So verhält sich das Display</h2>
            <p class="muted small" style="margin:0">Das Tablet bleibt wach. Ist jemand im Raum, wird es nach der Dimmzeit dunkler; ist niemand mehr da, geht es aus. Kommt jemand näher, wird es ohne Antippen wieder hell. Nachts begrenzt es die Helligkeit und schaltet auf das dunkle Design. Änderungen übernimmt das Tablet sofort.</p>
          </section>
        </div>
      </div>`,
    bind(el) {
      const form = $('#display', el);
      form.onsubmit = async (e) => {
        e.preventDefault();
        const body = { wake_mode: form.wake_mode.value, voice_wake: form.voice_wake.checked };
        for (const [k, , , , , , pct] of DISPLAY_FIELDS) body[k] = pct ? Number(form[k].value) / 100 : Number(form[k].value);
        if (body.sleep_after <= body.dim_after) return toast('„Ausschalten nach“ sollte länger sein als „Dimmen nach“.', true);
        if (body.min_brightness > body.max_brightness) return toast('Mindesthelligkeit ist größer als die Höchsthelligkeit.', true);
        await run(() => api('PUT', `/api/tablets/${id}/display`, body), 'Display-Einstellungen gespeichert');
      };
      $('#defaults', el).onclick = () => {
        form.wake_mode.value = DISPLAY_DEFAULTS.wake_mode;
        form.voice_wake.checked = DISPLAY_DEFAULTS.voice_wake;
        for (const [k, , , , , , pct] of DISPLAY_FIELDS) form[k].value = pct ? Math.round(DISPLAY_DEFAULTS[k] * 100) : DISPLAY_DEFAULTS[k];
      };
      $('#general', el).onsubmit = async (e) => {
        e.preventDefault();
        const name = e.target.name.value.trim();
        if (await run(() => api('PATCH', `/api/tablets/${id}`, { name, room_id: e.target.room.value || null }), 'Gespeichert')) $('h1', el).textContent = name;
      };
      $('#pair', el).onclick = async () => {
        const r = await run(() => api('POST', `/api/tablets/${id}/pair`));
        if (r) pairDialog(t.name, r);
      };
      $('#rotate', el).onclick = async () => {
        if (!confirm('Neuen Token erzeugen? Das Tablet wird getrennt und muss neu gekoppelt werden.')) return;
        const r = await run(() => api('POST', `/api/tablets/${id}/token`));
        if (r) pairDialog(t.name, r);
      };
      $('#del', el).onclick = async () => {
        if (!confirm(`Tablet „${t.name}“ entfernen? Es wird sofort getrennt.`)) return;
        if (await run(() => api('DELETE', `/api/tablets/${id}`), 'Tablet entfernt')) location.hash = '#/tablets';
      };
    },
  };
}

// ---------- Einstellungen: Felder ----------
// type: text (Standard) | url | secret | select | textarea | voice; list = Vorschläge; show = nur sichtbar, wenn …
const FIELDS = {
  ha_url: { label: 'Adresse', type: 'url', placeholder: 'http://192.168.1.10:8123', help: 'So, wie du Home Assistant im Browser aufrufst.' },
  ha_token: { label: 'Langlebiger Zugriffstoken', type: 'secret', help: 'In Home Assistant unten links auf dein Profil → Sicherheit → Langlebige Zugriffstoken → Token erstellen.' },
  openai_api_key: { label: 'OpenAI-Schlüssel', type: 'secret', help: 'Für Spracherkennung, und je nach Auswahl für Antworten und Stimme. platform.openai.com → API keys' },
  xai_api_key: { label: 'xAI-Schlüssel (Grok)', type: 'secret', help: 'Nur für Antworten mit Grok. console.x.ai → API Keys' },
  elevenlabs_api_key: { label: 'ElevenLabs-Schlüssel', type: 'secret', help: 'Nur für die Stimme von ElevenLabs. elevenlabs.io → Profil → API Keys' },
  llm_provider: { label: 'Anbieter', type: 'select', options: { openai: 'OpenAI', xai: 'Grok (xAI)', custom: 'Eigener Server (OpenAI-kompatibel)' } },
  openai_llm_model: { label: 'Modell', list: ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini', 'gpt-4.1'], show: 'llm_provider=openai' },
  xai_llm_model: { label: 'Modell', list: ['grok-3-mini', 'grok-3'], show: 'llm_provider=xai' },
  custom_llm_url: { label: 'Adresse des Servers', type: 'url', placeholder: 'http://192.168.1.20:11434/v1', help: 'Zum Beispiel Ollama oder LM Studio. Das Modell muss Werkzeug-Aufrufe (Tools) beherrschen.', show: 'llm_provider=custom' },
  custom_llm_api_key: { label: 'Schlüssel (falls nötig)', type: 'secret', show: 'llm_provider=custom' },
  custom_llm_model: { label: 'Modell', placeholder: 'z. B. qwen2.5:7b', show: 'llm_provider=custom' },
  stt_provider: { label: 'Anbieter', type: 'select', options: { openai: 'OpenAI' } },
  stt_model: { label: 'Modell', list: ['gpt-4o-mini-transcribe', 'gpt-4o-transcribe', 'whisper-1'] },
  stt_language: { label: 'Sprache', type: 'select', options: { de: 'Deutsch', en: 'Englisch', '': 'Automatisch erkennen' } },
  tts_provider: { label: 'Anbieter', type: 'select', options: { elevenlabs: 'ElevenLabs', openai: 'OpenAI' } },
  elevenlabs_voice_id: { label: 'Stimme', type: 'voice', help: 'Nach dem Eintragen des Schlüssels erscheint hier die Liste deiner Stimmen.', show: 'tts_provider=elevenlabs' },
  elevenlabs_model: { label: 'Modell', list: ['eleven_multilingual_v2', 'eleven_flash_v2_5', 'eleven_turbo_v2_5'], help: 'Flash und Turbo antworten schneller, Multilingual klingt am natürlichsten.', show: 'tts_provider=elevenlabs' },
  openai_tts_voice: { label: 'Stimme', type: 'select', options: Object.fromEntries(['alloy', 'ash', 'ballad', 'coral', 'echo', 'fable', 'nova', 'onyx', 'sage', 'shimmer'].map((v) => [v, v[0].toUpperCase() + v.slice(1)])), show: 'tts_provider=openai' },
  openai_tts_model: { label: 'Modell', list: ['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd'], show: 'tts_provider=openai' },
  assistant_instructions: { label: 'Zusätzliche Anweisungen', type: 'textarea', placeholder: 'z. B. Sprich mich mit Du an. Sag nach dem Schalten nur kurz „Erledigt“.', help: 'Wird jedem Gespräch mitgegeben. Gerätegrenzen pro Raum gelten trotzdem.' },
  wake_word: { label: 'Aktivierungswort', placeholder: 'z. B. Computer', help: 'Mehrere mit Komma trennen. Leer = aus. Wird ein deutsches Wort schlecht erkannt, schreib dahinter in Klammern, wie es auf Englisch klingt: Hey Hausgeist (hey house guyst).' },
  wake_sensitivity: { label: 'Empfindlichkeit', type: 'select', options: { niedrig: 'Niedrig (seltener Fehlalarm)', mittel: 'Mittel', hoch: 'Hoch (reagiert leichter)' } },
  update_repo: { label: 'GitHub-Repo für App-Updates', placeholder: 'gottschalkfelix4-source/hausgeist', help: 'Die Tablets zeigen einen Hinweis, sobald dort ein neueres Release liegt. Leer = kein Hinweis.' },
};

const SOURCE = { admin: 'hier gespeichert', env: 'aus der Container-Variable' };

function fieldHtml(name, s, showOverride) {
  const f = FIELDS[name];
  const cur = s[name];
  const show = showOverride ?? f.show;
  const attrs = `name="${name}" data-key="${name}" id="f-${name}"`;
  let input;
  if (f.type === 'secret') {
    input = `<input type="password" ${attrs} autocomplete="off" spellcheck="false" placeholder="${cur.set ? '•••••••• gespeichert, leer lassen zum Behalten' : 'Nicht eingetragen'}">`;
  } else if (f.type === 'select') {
    input = `<select ${attrs}>${Object.entries(f.options).map(([v, l]) => `<option value="${esc(v)}" ${v === cur.value ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select>`;
  } else if (f.type === 'textarea') {
    input = `<textarea ${attrs} rows="4" placeholder="${esc(f.placeholder || '')}">${esc(cur.value)}</textarea>`;
  } else {
    input = `<input type="${f.type === 'url' ? 'url' : 'text'}" ${attrs} value="${esc(cur.value)}" spellcheck="false" placeholder="${esc(f.placeholder || '')}" ${f.list ? `list="l-${name}"` : ''}>
      ${f.list ? `<datalist id="l-${name}">${f.list.map((v) => `<option value="${esc(v)}">`).join('')}</datalist>` : ''}`;
  }
  const origin = cur.source === 'admin'
    ? `${SOURCE.admin} · <button type="button" class="link" data-reset="${name}">${cur.secret ? 'Entfernen' : 'Zurücksetzen'}</button>`
    : cur.source === 'default' ? '' : SOURCE[cur.source];
  return `<label class="field" ${show ? `data-show="${show}"` : ''}><span>${f.label}</span>${input}
    ${f.help ? `<small>${esc(f.help)}</small>` : ''}${origin ? `<small class="origin">${origin}</small>` : ''}</label>`;
}

const fields = (names, s, show = {}) => names.map((n) => fieldHtml(n, s, show[n])).join('');

/** Geänderte Felder im Formular: Schlüssel nur, wenn etwas eingetippt wurde. */
function collect(root, s) {
  const out = {};
  for (const el of $$('[data-key]', root)) {
    const k = el.dataset.key;
    if (el.closest('[data-show]')?.hidden) continue;
    const v = el.value.trim();
    if (s[k].secret ? v : v !== (s[k].value ?? '')) out[k] = v;
  }
  return out;
}

function applyShow(root) {
  for (const el of $$('[data-show]', root)) {
    el.hidden = !el.dataset.show.split(' ').every((cond) => {
      const [k, vals] = cond.split('=');
      const ctl = $(`[data-key="${k}"]`, root);
      return ctl && vals.split('|').includes(ctl.value);
    });
  }
}

function result(el, r) {
  el.hidden = false;
  el.className = `test-result ${r.ok ? 'ok' : 'bad'}`;
  el.textContent = r.message;
}

function play(r) {
  if (r.audio_base64) new Audio(`data:${r.mime};base64,${r.audio_base64}`).play().catch(() => toast('Der Browser hat die Wiedergabe blockiert.', true));
}

/**
 * Verdrahtet ein Einstellungsformular: Sichtbarkeit, Testknöpfe, Stimmenliste, Speichern.
 * onSaved bekommt die neuen Einstellungen.
 */
function bindSettingsForm(root, s, { onSaved, saveBtn } = {}) {
  const save = saveBtn || $('[data-save]', root);
  const dirty = () => Object.keys(collect(root, s)).length > 0;
  const update = () => {
    applyShow(root);
    const changed = dirty();
    if (save) save.disabled = !changed;
    const note = save?.closest('.savebar')?.querySelector('span');
    if (note) note.textContent = changed ? 'Ungespeicherte Änderungen' : 'Gespeicherte Werte gehen den Container-Variablen vor.';
    window.onbeforeunload = changed ? () => true : null;
  };
  root.addEventListener('input', update);
  root.addEventListener('change', update);
  update();

  for (const btn of $$('[data-test]', root)) {
    btn.onclick = async () => {
      const out = $(`[data-result="${btn.dataset.test}"]`, root);
      btn.disabled = true;
      out.hidden = false;
      out.className = 'test-result';
      out.textContent = 'Prüfe …';
      const r = await run(() => api('POST', `/api/settings/test/${btn.dataset.test}`, collect(root, s)));
      btn.disabled = false;
      if (!r) return (out.hidden = true);
      result(out, r);
      play(r);
      if (btn.dataset.test === 'voices' && r.ok) fillVoices(root, r.voices);
    };
  }

  for (const b of $$('[data-reset]', root)) {
    b.onclick = async () => {
      const ns = await run(() => api('PUT', '/api/settings', { [b.dataset.reset]: null }), 'Zurückgesetzt');
      if (ns) onSaved?.(ns);
    };
  }

  // ElevenLabs-Stimmen laden, sobald ein Schlüssel da ist
  const voice = $('[data-key="elevenlabs_voice_id"]', root);
  if (voice) {
    const loadVoices = async () => {
      const r = await api('POST', '/api/settings/test/voices', collect(root, s)).catch(() => null);
      if (r?.ok) fillVoices(root, r.voices);
    };
    if (s.elevenlabs_api_key.set) loadVoices();
    $('[data-key="elevenlabs_api_key"]', root)?.addEventListener('change', loadVoices);
  }

  if (save) {
    save.onclick = async (e) => {
      e.preventDefault();
      const body = collect(root, s);
      for (const el of $$('input[type=url]', root)) {
        if (!el.closest('[data-show]')?.hidden && el.value.trim() && !el.checkValidity()) return toast(`Bitte eine vollständige Adresse mit http:// eintragen (${FIELDS[el.dataset.key].label}).`, true);
      }
      const ns = await run(() => api('PUT', '/api/settings', body), 'Gespeichert');
      if (!ns) return false;
      window.onbeforeunload = null;
      onSaved?.(ns);
      return ns;
    };
  }
}

/** Aktivierungswort: Vorschläge zum Antippen und Vorschau, wie der Erkenner die Wörter zerlegt. */
function bindWakePreview(root) {
  const input = $('[data-key="wake_word"]', root);
  const out = $('#wake-preview', root);
  const chips = $('#wake-suggest', root);
  let timer;
  const refresh = async () => {
    const r = await api('GET', `/api/wake/preview?word=${encodeURIComponent(input.value)}`).catch(() => null);
    if (!r) return;
    chips.innerHTML = r.suggestions.map((w) => `<button type="button" class="chip" data-word="${esc(w)}">+ ${esc(w.replace(/\s*\(.*\)/, ''))}</button>`).join('');
    out.innerHTML = r.words.length
      ? `Erkannt wird: ${r.words.map((w) => `<b>${esc(w.name)}</b> <code>${esc(w.tokens.join(' ').replaceAll('▁', '·'))}</code>`).join(', ')}`
      : 'Kein Aktivierungswort: Die Tablets hören nicht mit, sprechen geht dann nur über das Mikrofon-Symbol.';
  };
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(refresh, 250); });
  chips.addEventListener('click', (e) => {
    const word = e.target.closest('[data-word]')?.dataset.word;
    if (!word) return;
    const have = input.value.split(',').map((x) => x.trim()).filter(Boolean);
    if (!have.some((x) => x.toLowerCase() === word.toLowerCase())) input.value = [...have, word].join(', ');
    input.dispatchEvent(new Event('input', { bubbles: true }));
  });
  refresh();
}

function fillVoices(root, voices) {
  const old = $('[data-key="elevenlabs_voice_id"]', root);
  if (!old || !voices.length) return;
  const cur = old.value;
  const known = voices.some((v) => v.voice_id === cur);
  const sel = document.createElement('select');
  sel.name = sel.id = old.id;
  sel.dataset.key = 'elevenlabs_voice_id';
  sel.innerHTML = (cur && !known ? `<option value="${esc(cur)}">Eigene ID: ${esc(cur)}</option>` : '')
    + (cur ? '' : '<option value="">Bitte wählen</option>')
    + voices.map((v) => `<option value="${esc(v.voice_id)}" ${v.voice_id === cur ? 'selected' : ''}>${esc(v.name)}${v.description ? ` (${esc(v.description)})` : ''}</option>`).join('');
  old.replaceWith(sel);
  sel.dispatchEvent(new Event('change', { bubbles: true }));
}

const testBtn = (kind, label) => `<button type="button" class="btn" data-test="${kind}">${label}</button>`;
const testOut = (kind) => `<p class="test-result" data-result="${kind}" hidden></p>`;

// ---------- Einstellungen: Seiten ----------
const SETTINGS_TABS = { homeassistant: 'Home Assistant', sprache: 'Sprachassistent', system: 'System' };

async function viewSettings(tab = 'homeassistant') {
  if (!SETTINGS_TABS[tab]) tab = 'homeassistant';
  const tabs = `<nav class="tabs" aria-label="Einstellungen">${Object.entries(SETTINGS_TABS).map(([k, l]) => `<a href="#/einstellungen/${k}" class="${k === tab ? 'on' : ''}">${l}</a>`).join('')}</nav>`;
  const page = await { homeassistant: settingsHa, sprache: settingsVoice, system: settingsSystem }[tab]();
  return { html: `<div class="head"><h1>Einstellungen</h1></div>${tabs}${page.html}`, bind: page.bind };
}

const rerender = () => route();
const saveBar = `<div class="savebar glass"><span class="small muted">Container-Variablen gelten, bis hier etwas gespeichert wird.</span><button class="btn primary" data-save disabled>Speichern</button></div>`;

async function settingsHa() {
  const [s, st] = await Promise.all([api('GET', '/api/settings'), api('GET', '/api/status')]);
  return {
    html: `<div class="cols">
      <form class="glass card stack" id="form" style="gap:14px">
        <h2>Verbindung</h2>
        <div class="kv" style="padding-top:0"><span>Status</span><span class="dot ${st.ha.connected ? 'ok' : ''}">${st.ha.connected ? `Verbunden, ${st.ha.entities} Geräte` : esc(st.ha.error || 'Getrennt')}</span></div>
        ${fields(['ha_url', 'ha_token'], s)}
        <div class="row-inline">${testBtn('ha', 'Verbindung testen')}</div>${testOut('ha')}
        ${saveBar}
      </form>
      <section class="glass card"><h2>So geht's</h2><ol class="steps">
        <li>Home Assistant im Browser öffnen</li>
        <li>Unten links auf deinen <b>Namen</b> klicken, dann oben <b>Sicherheit</b></li>
        <li>Ganz unten bei <b>Langlebige Zugriffstoken</b> auf <b>Token erstellen</b>, Name z. B. „Hausgeist“</li>
        <li>Den Token kopieren und hier eintragen. Home Assistant zeigt ihn nur einmal an.</li>
      </ol><p class="muted small">Nach dem Speichern verbindet sich Hausgeist sofort neu.</p></section>
    </div>`,
    bind(el) {
      bindSettingsForm($('#form', el), s, { onSaved: () => setTimeout(rerender, 1200) });
    },
  };
}

async function settingsVoice() {
  const [s, rooms] = await Promise.all([api('GET', '/api/settings'), api('GET', '/api/rooms')]);
  return {
    html: `<form id="form" class="stack">
      <div class="cols">
        <div class="stack">
          <section class="glass card stack" style="gap:14px"><h2>Antworten (Sprachmodell)</h2>
            ${fields(['llm_provider', 'openai_llm_model', 'xai_llm_model', 'custom_llm_url', 'custom_llm_api_key', 'custom_llm_model'], s)}
            <div class="row-inline">${testBtn('llm', 'Testen')}</div>${testOut('llm')}
          </section>
          <section class="glass card stack" style="gap:14px"><h2>Stimme</h2>
            ${fields(['tts_provider', 'elevenlabs_voice_id', 'elevenlabs_model', 'openai_tts_voice', 'openai_tts_model'], s)}
            <div class="row-inline">${testBtn('tts', 'Probe anhören')}</div>${testOut('tts')}
          </section>
          <section class="glass card stack" style="gap:14px"><h2>Spracherkennung</h2>
            ${fields(['stt_provider', 'stt_model', 'stt_language'], s)}
            <div class="row-inline">${testBtn('stt', 'Testen')}</div>${testOut('stt')}
          </section>
        </div>
        <div class="stack">
          <section class="glass card stack" style="gap:14px" id="wake"><h2>Aktivierungswort</h2>
            <p class="muted small" style="margin:0">Die Tablets hören ständig auf dieses Wort, ganz ohne Internet. Erst danach wird aufgenommen und an den Server geschickt. Hören es mehrere, antwortet das Tablet, bei dem gerade jemand ist, sonst das, das dich am lautesten gehört hat.</p>
            ${fields(['wake_word'], s)}
            <div class="chips" id="wake-suggest"></div>
            <p class="small muted" id="wake-preview" style="margin:0"></p>
            ${fields(['wake_sensitivity'], s)}
          </section>
          <section class="glass card stack" style="gap:14px"><h2>Zugangsschlüssel</h2>
            <p class="muted small" style="margin:0">Nur die Schlüssel der Anbieter, die du nutzt. Sie werden nie wieder angezeigt.</p>
            ${fields(['openai_api_key', 'xai_api_key', 'elevenlabs_api_key'], s)}
          </section>
          <section class="glass card stack" style="gap:14px"><h2>Persönlichkeit</h2>
            ${fields(['assistant_instructions'], s)}
          </section>
        </div>
      </div>
      ${saveBar}
    </form>
    <section class="glass card stack" style="gap:14px"><h2>Ausprobieren</h2>
      <p class="muted small" style="margin:0">Schick einen Satz an den Assistenten, als stündest du im gewählten Raum. Geräte werden dabei wirklich geschaltet. Erst speichern, dann testen.</p>
      <form class="row-inline" id="try">
        <label class="field" style="flex:0 1 220px"><span>Raum</span><select name="room">${roomOptions(rooms, rooms[0]?.id)}</select></label>
        <label class="field" style="flex:3"><span>Satz</span><input type="text" name="text" required maxlength="1000" placeholder="z. B. Mach das Licht auf 30 Prozent"></label>
        <button class="btn primary">Senden</button>
      </form>
      <label class="check small"><input type="checkbox" id="speak" checked> Antwort vorlesen</label>
      <div id="answer" hidden></div>
    </section>`,
    bind(el) {
      bindSettingsForm($('#form', el), s, { onSaved: rerender });
      bindWakePreview(el);
      $('#try', el).onsubmit = async (e) => {
        e.preventDefault();
        const btn = $('button', e.target);
        btn.disabled = true;
        const out = $('#answer', el);
        const r = await run(() => api('POST', '/api/voice/test', { text: e.target.text.value.trim(), room_id: e.target.room.value || null, speak: $('#speak', el).checked }));
        btn.disabled = false;
        if (!r) return;
        out.hidden = false;
        out.innerHTML = `<p class="reply">„${esc(r.reply)}“</p>${r.actions.length ? `<div class="chips">${r.actions.map((a) => `<span class="chip">${esc(a.entity_id)} → ${esc(a.action)}${a.value != null ? ` ${esc(a.value)}` : ''}</span>`).join('')}</div>` : '<p class="muted small" style="margin:0">Keine Geräte geschaltet.</p>'}`;
        play(r);
      };
    },
  };
}

async function settingsSystem() {
  const [s, st] = await Promise.all([api('GET', '/api/settings'), api('GET', '/api/status')]);
  return {
    html: `<div class="cols">
      <div class="stack">
        <form class="glass card stack" id="form" style="gap:14px"><h2>App-Updates</h2>
          ${fields(['update_repo'], s)}
          <div class="row-inline" style="justify-content:flex-end"><button class="btn primary" data-save disabled>Speichern</button></div>
        </form>
        <section class="glass card stack" style="gap:14px"><h2>Sicherung</h2>
          <p class="muted small" style="margin:0">Räume, Geräte-Zuordnung, Tablets und Einstellungen in einer Datei. Sie enthält deine API-Schlüssel und die Tablet-Tokens, also gut aufbewahren. Das Passwort ist nicht enthalten.</p>
          <div class="row-inline"><button type="button" class="btn" id="export">Sicherung herunterladen</button>
            <label class="btn">Sicherung einspielen<input type="file" id="import" accept="application/json,.json" hidden></label></div>
        </section>
      </div>
      <div class="stack">
        <form class="glass card stack" id="pw" style="gap:14px"><h2>Passwort ${st.password_set ? 'ändern' : 'festlegen'}</h2>
          ${st.password_set ? '' : '<p class="muted small" style="margin:0">Du bist mit dem ADMIN_KEY des Containers angemeldet. Mit einem eigenen Passwort brauchst du ihn nicht mehr.</p>'}
          <label class="field"><span>${st.password_set ? 'Bisheriges Passwort' : 'ADMIN_KEY'}</span><input type="password" name="current" autocomplete="current-password" required></label>
          <label class="field"><span>Neues Passwort</span><input type="password" name="new" autocomplete="new-password" minlength="8" required><small>Mindestens 8 Zeichen. Andere angemeldete Geräte werden abgemeldet.</small></label>
          <label class="field"><span>Wiederholen</span><input type="password" name="repeat" autocomplete="new-password" minlength="8" required></label>
          <div class="row-inline" style="justify-content:flex-end"><button class="btn primary">Speichern</button></div>
        </form>
        <section class="glass card"><h2>Info</h2>
          <div class="kv"><span>Version</span><span>${esc(st.version)}</span></div>
          <div class="kv"><span>API-Doku</span><a href="/docs" target="_blank" rel="noopener">/docs</a></div>
          <div class="kv"><span>Projekt</span><a href="https://github.com/gottschalkfelix4-source/hausgeist" target="_blank" rel="noopener">GitHub</a></div>
        </section>
      </div>
    </div>`,
    bind(el) {
      bindSettingsForm($('#form', el), s, { onSaved: rerender });
      $('#pw', el).onsubmit = async (e) => {
        e.preventDefault();
        const f = e.target;
        if (f.new.value !== f.repeat.value) return toast('Die beiden neuen Passwörter sind nicht gleich.', true);
        if (await run(() => api('PUT', '/api/admin/password', { current: f.current.value, new: f.new.value }), 'Passwort geändert')) f.reset();
      };
      $('#export', el).onclick = async () => {
        const res = await fetch('/api/backup', { headers: { 'x-admin-key': key } });
        if (!res.ok) return toast('Sicherung fehlgeschlagen', true);
        const a = document.createElement('a');
        a.href = URL.createObjectURL(await res.blob());
        a.download = /filename="([^"]+)"/.exec(res.headers.get('content-disposition') || '')?.[1] || 'hausgeist-sicherung.json';
        a.click();
        URL.revokeObjectURL(a.href);
      };
      $('#import', el).onchange = async (e) => {
        const file = e.target.files[0];
        e.target.value = '';
        if (!file) return;
        let data;
        try {
          data = JSON.parse(await file.text());
        } catch {
          return toast('Das ist keine Hausgeist-Sicherung.', true);
        }
        if (data.format !== 'hausgeist-backup') return toast('Das ist keine Hausgeist-Sicherung.', true);
        if (!confirm(`Sicherung vom ${data.created?.replace('T', ' ') || '?'} einspielen? Alle Räume, Tablets und Einstellungen werden ersetzt.`)) return;
        const r = await run(() => api('POST', '/api/backup', data));
        if (r) toast(`Eingespielt: ${plural(r.rooms, 'Raum', 'Räume')}, ${plural(r.tablets, 'Tablet', 'Tablets')}`);
      };
    },
  };
}

// ---------- Einrichtungs-Assistent ----------
const WIZARD = ['Home Assistant', 'Sprachassistent', 'Räume', 'Tablet'];

async function viewWizard(stepArg) {
  const step = Math.min(Math.max(parseInt(stepArg, 10) || 1, 1), WIZARD.length);
  const stepper = `<ol class="stepper">${WIZARD.map((t, i) => `<li class="${i + 1 === step ? 'on' : i + 1 < step ? 'done' : ''}"><a href="#/einrichtung/${i + 1}"><span>${i + 1}</span>${t}</a></li>`).join('')}</ol>`;
  const goto = (n) => { window.onbeforeunload = null; location.hash = n > WIZARD.length ? '#/uebersicht' : `#/einrichtung/${n}`; };
  const nav = (primary, skip = true) => `<div class="row-inline wizard-nav">
      ${step > 1 ? `<a class="btn" href="#/einrichtung/${step - 1}">Zurück</a>` : ''}<span class="grow"></span>
      ${skip ? `<button type="button" class="link" id="skip">${step === WIZARD.length ? 'Später' : 'Überspringen'}</button>` : ''}
      <button class="btn primary" id="next">${primary}</button></div>`;
  const wrap = (body) => `<div class="head"><h1>Einrichtung</h1></div>${stepper}<div class="wizard">${body}</div>`;
  const bindNav = (el, onNext) => {
    $('#skip', el)?.addEventListener('click', () => goto(step + 1));
    $('#next', el).onclick = async (e) => {
      e.preventDefault();
      e.target.disabled = true;
      try {
        if ((await onNext()) !== false) goto(step + 1);
      } finally {
        e.target.disabled = false;
      }
    };
  };

  if (step === 1) {
    const s = await api('GET', '/api/settings');
    return {
      html: wrap(`<form class="glass card stack" id="form" style="gap:14px">
        <h2>Mit Home Assistant verbinden</h2>
        <p class="muted small" style="margin:0">Den Token erstellst du in Home Assistant: unten links auf deinen Namen → <b>Sicherheit</b> → <b>Langlebige Zugriffstoken</b> → <b>Token erstellen</b>.</p>
        ${fields(['ha_url', 'ha_token'], s)}${testOut('ha')}
        ${nav('Verbinden und weiter')}</form>`),
      bind(el) {
        const form = $('#form', el);
        bindSettingsForm(form, s);
        bindNav(el, async () => {
          const body = collect(form, s);
          const out = $('[data-result="ha"]', form);
          result(out, { ok: true, message: 'Verbinde …' });
          const r = await run(() => api('POST', '/api/settings/test/ha', body));
          if (!r) return false;
          result(out, r);
          if (!r.ok) return false;
          return !!(await run(() => api('PUT', '/api/settings', body), 'Home Assistant verbunden'));
        });
      },
    };
  }

  if (step === 2) {
    const s = await api('GET', '/api/settings');
    const show = { openai_api_key: '', xai_api_key: 'llm_provider=xai', elevenlabs_api_key: 'tts_provider=elevenlabs' };
    return {
      html: wrap(`<form class="glass card stack" id="form" style="gap:14px">
        <h2>Sprachassistent</h2>
        <p class="muted small" style="margin:0">Am Tablet auf das Mikrofon tippen und sprechen. Dafür braucht Hausgeist einen OpenAI-Schlüssel (Spracherkennung), ein Sprachmodell für die Antworten und eine Stimme. Ohne Schlüssel funktioniert alles außer der Sprache.</p>
        ${fields(['openai_api_key'], s, show)}
        <h2 style="margin-top:8px">Antworten</h2>
        ${fields(['llm_provider', 'xai_api_key', 'custom_llm_url', 'custom_llm_model'], s, show)}
        <h2 style="margin-top:8px">Stimme</h2>
        ${fields(['tts_provider', 'elevenlabs_api_key', 'elevenlabs_voice_id', 'openai_tts_voice'], s, show)}
        <p class="muted small" style="margin:0">Modelle und weitere Feinheiten findest du später unter Einstellungen → Sprachassistent.</p>
        ${testOut('llm')}
        ${nav('Speichern und weiter')}</form>`),
      bind(el) {
        const form = $('#form', el);
        bindSettingsForm(form, s);
        bindNav(el, async () => {
          const body = collect(form, s);
          if (Object.keys(body).length && !(await run(() => api('PUT', '/api/settings', body)))) return false;
          const r = await run(() => api('POST', '/api/settings/test/llm', {}));
          if (r && !r.ok) {
            result($('[data-result="llm"]', form), r);
            return confirm(`Der Test des Sprachmodells ist fehlgeschlagen: ${r.message}\n\nTrotzdem weiter?`);
          }
          return true;
        });
      },
    };
  }

  if (step === 3) {
    const [rooms, st] = await Promise.all([api('GET', '/api/rooms'), api('GET', '/api/status')]);
    return {
      html: wrap(`<section class="glass card stack" style="gap:14px">
        <h2>Räume und Geräte</h2>
        <p class="muted small" style="margin:0">Jedes Tablet zeigt nur die Geräte seines Raums. Am schnellsten geht es mit den Bereichen, die du in Home Assistant schon angelegt hast.</p>
        ${st.ha.connected ? '' : '<p class="error small">Home Assistant ist noch nicht verbunden. Bereiche und Geräte gibt es erst danach.</p>'}
        <div class="row-inline"><button type="button" class="btn primary" id="import">Aus Home Assistant übernehmen</button><button type="button" class="btn" id="add">Raum von Hand anlegen</button></div>
        ${rooms.length ? `<div class="chips">${rooms.map((r) => `<a class="chip" href="#/raeume/${encodeURIComponent(r.id)}">${esc(r.name)} · ${plural(r.entity_ids.length, 'Gerät', 'Geräte')}</a>`).join('')}</div>` : '<p class="muted small" style="margin:0">Noch keine Räume.</p>'}
        ${nav('Weiter')}</section>`),
      bind(el) {
        $('#import', el).onclick = importAreasDialog;
        $('#add', el).onclick = addRoomDialog;
        bindNav(el, () => (rooms.length ? true : confirm('Noch kein Raum angelegt. Trotzdem weiter?')));
      },
    };
  }

  const [tablets, rooms] = await Promise.all([api('GET', '/api/tablets'), api('GET', '/api/rooms')]);
  return {
    html: wrap(`<section class="glass card stack" style="gap:14px">
      <h2>Tablet koppeln</h2>
      <ol class="steps">
        <li>Die App <b>hausgeist-<i>version</i>.apk</b> von <a href="https://github.com/gottschalkfelix4-source/hausgeist/releases/latest" target="_blank" rel="noopener">GitHub</a> auf dem Tablet installieren</li>
        <li>Hier ein Tablet hinzufügen und den Raum wählen</li>
        <li>In der App die Server-Adresse <b>${esc(location.origin)}</b> und den 6-stelligen Code eingeben</li>
      </ol>
      <div class="row-inline"><button type="button" class="btn primary" id="add">Tablet hinzufügen</button></div>
      ${tablets.length ? `<div>${tablets.map((t) => `<div class="kv"><a href="#/tablets/${encodeURIComponent(t.id)}">${esc(t.name)}</a><span class="dot ${t.online ? 'ok' : t.pair_code ? 'warn' : ''}">${t.online ? 'Online' : t.pair_code ? 'Wartet auf Kopplung' : 'Offline'}</span></div>`).join('')}</div>` : ''}
      ${nav('Fertig', false)}</section>`),
    bind(el) {
      $('#add', el).onclick = () => addTabletDialog(rooms);
      bindNav(el, () => toast('Einrichtung abgeschlossen'));
    },
  };
}

// Beim Verlassen einer Seite die Warnung vor ungespeicherten Änderungen wieder entfernen.
window.addEventListener('hashchange', () => { window.onbeforeunload = null; });

(async function boot() {
  const st = await fetch('/api/setup').then((r) => r.json()).catch(() => ({}));
  if (st.needs_setup) return showSetup();
  if (!key) return showLogin();
  api('GET', '/api/status').then(start, (err) => (err instanceof AuthError ? authFailed(err) : start()));
})();
