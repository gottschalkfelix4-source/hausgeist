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
const WAKE_MODES = { both: 'Kamera und Präsenzmelder', camera: 'Nur Kamera', sensor: 'Nur Präsenzmelder' };

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
};

// ---------- API ----------
let key = sessionStorage.getItem('hg-key') || localStorage.getItem('hg-key') || '';

class AuthError extends Error {}

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: { 'x-admin-key': key, ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) throw new AuthError('Admin-Key ungültig');
  if (res.status === 503) throw new AuthError('Auf dem Server ist kein ADMIN_KEY gesetzt. Bitte in der Container-Konfiguration eintragen.');
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

function showLogin(error) {
  $('#app').hidden = true;
  $('#login').hidden = false;
  $('#login-error').hidden = !error;
  $('#login-error').textContent = error || '';
  $('#login-key').focus();
}

function logout() {
  key = '';
  sessionStorage.removeItem('hg-key');
  localStorage.removeItem('hg-key');
  showLogin();
}

$('#login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  key = $('#login-key').value.trim();
  try {
    await api('GET', '/api/status');
  } catch (err) {
    return showLogin(err.message);
  }
  (($('#login-remember').checked) ? localStorage : sessionStorage).setItem('hg-key', key);
  $('#login-key').value = '';
  start();
});
$('#logout').addEventListener('click', logout);

function start() {
  $('#login').hidden = true;
  $('#app').hidden = false;
  route();
}

// Ein einfacher Hash-Router: #/raeume/<id> usw.
const routes = { uebersicht: viewOverview, raeume: viewRooms, tablets: viewTablets };
let renderId = 0;

async function route() {
  const [name = 'uebersicht', id] = location.hash.replace(/^#\/?/, '').split('/');
  const view = routes[name] ? name : 'uebersicht';
  $$('[data-nav]').forEach((a) => a.classList.toggle('on', a.dataset.nav === view));
  const el = $('#view');
  const mine = ++renderId;
  el.innerHTML = '<p class="muted">Lade …</p>';
  try {
    const html = await (id ? (view === 'raeume' ? viewRoom : viewTablet)(decodeURIComponent(id)) : routes[view]());
    if (mine !== renderId) return; // inzwischen weiternavigiert
    el.innerHTML = html.html ?? html;
    html.bind?.(el);
  } catch (err) {
    if (err instanceof AuthError) return logout(), showLogin(err.message);
    el.innerHTML = `<div class="glass card"><h3>Das hat nicht geklappt</h3><p class="error">${esc(err.message)}</p></div>`;
  }
  if (document.activeElement === document.body) el.focus({ preventScroll: true });
}
window.addEventListener('hashchange', route);

/** Führt eine Aktion aus und zeigt Fehler als Hinweis. */
async function run(fn, okMsg) {
  try {
    const r = await fn();
    if (okMsg) toast(okMsg);
    return r ?? true;
  } catch (err) {
    if (err instanceof AuthError) return logout(), showLogin(err.message), false;
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
  const provider = { openai: 'OpenAI', xai: 'Grok (xAI)', elevenlabs: 'ElevenLabs' };
  const steps = [
    [rooms.length > 0, 'Räume anlegen', 'oder aus Home Assistant übernehmen', '#/raeume'],
    [rooms.some((r) => r.entity_ids.length), 'Geräte den Räumen zuweisen', '', '#/raeume'],
    [tablets.length > 0, 'Tablet hinzufügen', 'und den Kopplungscode am Tablet eingeben', '#/tablets'],
  ];
  return `
    <div class="head"><div><h1>Übersicht</h1><p class="muted small">Hausgeist ${esc(st.version)}</p></div></div>
    ${steps.every((s) => s[0]) ? '' : `
      <section class="glass card"><h2>Erste Schritte</h2><ol class="steps">
        ${steps.map(([done, t, sub, href]) => `<li>${done ? '✓ ' : ''}<a href="${href}"><b>${t}</b></a> ${sub}</li>`).join('')}
      </ol></section>`}
    <div class="cards">
      <section class="glass card"><h2>Home Assistant</h2>
        <div class="kv"><span>Verbindung</span>${okDot(st.ha.connected, 'Verbunden', st.ha.token_set ? 'Getrennt' : 'HA_TOKEN fehlt')}</div>
        <div class="kv"><span>Adresse</span><span>${esc(st.ha.url)}</span></div>
        <div class="kv"><span>Geräte</span><span>${st.ha.entities ?? '–'}</span></div>
      </section>
      <section class="glass card"><h2>Sprachassistent</h2>
        <div class="kv"><span>Sprache zu Text</span>${okDot(st.voice.stt_ok, provider[st.voice.stt] || st.voice.stt, 'Schlüssel fehlt')}</div>
        <div class="kv"><span>Antworten</span>${okDot(st.voice.llm_ok, provider[st.voice.llm] || st.voice.llm, 'Schlüssel fehlt')}</div>
        <div class="kv"><span>Stimme</span>${okDot(st.voice.tts_ok, provider[st.voice.tts] || st.voice.tts, 'Schlüssel fehlt')}</div>
      </section>
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
        const body = { wake_mode: form.wake_mode.value };
        for (const [k, , , , , , pct] of DISPLAY_FIELDS) body[k] = pct ? Number(form[k].value) / 100 : Number(form[k].value);
        if (body.sleep_after <= body.dim_after) return toast('„Ausschalten nach“ sollte länger sein als „Dimmen nach“.', true);
        if (body.min_brightness > body.max_brightness) return toast('Mindesthelligkeit ist größer als die Höchsthelligkeit.', true);
        await run(() => api('PUT', `/api/tablets/${id}/display`, body), 'Display-Einstellungen gespeichert');
      };
      $('#defaults', el).onclick = () => {
        form.wake_mode.value = DISPLAY_DEFAULTS.wake_mode;
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

// Beim Verlassen einer Raumseite die Warnung vor ungespeicherten Änderungen wieder entfernen.
window.addEventListener('hashchange', () => { window.onbeforeunload = null; });

if (key) {
  api('GET', '/api/status').then(start, (err) => (err instanceof AuthError ? logout() : start()));
} else {
  showLogin();
}
