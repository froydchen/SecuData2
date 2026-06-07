const app = {
  state: null,
  history: [],
  visibleLogs: [],
  draftSaveTimer: null,
  ws: null,
  draftInitialized: false,
  activeCaptureField: 'id',
  suggestionRequestIds: {},
  suggestionAbortControllers: {},
  suggestionCache: { id: ['-'], geraeteart: ['-'], hersteller: ['-'] },
};


const captureFields = ['id', 'geraeteart', 'hersteller'];
const captureFieldLabels = {
  id: 'ID',
  geraeteart: 'Geräteart',
  hersteller: 'Hersteller',
};

const draftFields = [
  'id',
  'geraeteart',
  'hersteller',
  'raum_etage',
  'kunde',
  'typ_modell',
  'seriennummer',
  'pruefer',
  'zusatztext',
];

function el(id) {
  return document.getElementById(id);
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    headers: {
      'Content-Type': 'application/json',
      ...(options.headers || {}),
    },
    ...options,
  });
  const contentType = response.headers.get('content-type') || '';
  const data = contentType.includes('application/json') ? await response.json() : await response.text();
  if (!response.ok) {
    const detail = typeof data === 'object' && data?.detail ? data.detail : String(data);
    throw new Error(detail || `${response.status} ${response.statusText}`);
  }
  return data;
}

function toast(message) {
  const node = el('toast');
  node.textContent = message;
  node.classList.add('visible');
  window.clearTimeout(node._timer);
  node._timer = window.setTimeout(() => node.classList.remove('visible'), 2800);
}

function activateTab(tabName) {
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.classList.toggle('active', tab.dataset.tab === tabName);
  });
  document.querySelectorAll('.tab-panel').forEach((panel) => {
    panel.classList.toggle('active', panel.id === `tab-${tabName}`);
  });
}

function readDraftFromInputs() {
  const payload = {};
  draftFields.forEach((field) => {
    payload[field] = el(`field-${field}`).value ?? '';
  });
  return payload;
}

function applyDraftToInputs(draft = {}) {
  draftFields.forEach((field) => {
    const node = el(`field-${field}`);
    if (!node) return;
    node.value = draft[field] ?? '';
  });
}

function applyServerDraft(draft = {}) {
  applyDraftToInputs(draft);
  updateMobileContext();
  updateMobileCaptureDisplay({ syncInput: true });
  refreshSuggestions(app.activeCaptureField);
}

function updateMobileContext() {
  const customer = el('field-kunde')?.value?.trim() || '–';
  const room = el('field-raum_etage')?.value?.trim() || '–';
  if (el('mobileContextCustomer')) el('mobileContextCustomer').textContent = customer;
  if (el('mobileContextRoom')) el('mobileContextRoom').textContent = room;
}

function captureFieldValue(field) {
  return el(`field-${field}`)?.value ?? '';
}

function setCaptureFieldValue(field, value) {
  const node = el(`field-${field}`);
  if (!node) return;
  node.value = value ?? '';
  updateMobileContext();
  updateMobileCaptureDisplay({ syncInput: field === app.activeCaptureField });
  scheduleDraftSave();
}

function updateMobileCaptureDisplay({ syncInput = false } = {}) {
  document.querySelectorAll('[data-capture-field]').forEach((row) => {
    const field = row.dataset.captureField;
    const active = field === app.activeCaptureField;
    row.classList.toggle('active', active);
    const display = el(`mobileDisplay-${field}`);
    if (!display) return;
    const value = captureFieldValue(field).trim();
    display.textContent = value || captureFieldLabels[field] || field;
    display.classList.toggle('placeholder', !value);
  });

  const input = el('mobileFieldInput');
  if (!input) return;
  input.placeholder = captureFieldLabels[app.activeCaptureField] || '';
  if (syncInput || document.activeElement !== input) {
    input.value = captureFieldValue(app.activeCaptureField);
  }
}

async function finalizeCaptureField(field = app.activeCaptureField) {
  if (field !== 'geraeteart') return;
  const raw = captureFieldValue('geraeteart');
  if (!raw.trim()) return;
  try {
    const data = await fetchJson('/api/draft/expand-device', {
      method: 'POST',
      body: JSON.stringify({ value: raw }),
    });
    const expanded = String(data.value ?? '').trim();
    if (expanded && expanded !== raw) {
      setCaptureFieldValue('geraeteart', expanded);
      refreshSuggestions('hersteller');
    }
  } catch (_error) {
    // Expansion is helpful, but field switching must never block on it.
  }
}

function activateCaptureField(field, { focus = true } = {}) {
  if (!captureFields.includes(field)) return;
  const previousField = app.activeCaptureField;
  app.activeCaptureField = field;
  updateMobileCaptureDisplay({ syncInput: true });
  refreshSuggestions(field, { forceRender: true });
  const input = el('mobileFieldInput');
  if (focus && input) input.focus();
  if (previousField !== field) {
    finalizeCaptureField(previousField);
  }
}

function stepCaptureField(direction) {
  const currentIndex = captureFields.indexOf(app.activeCaptureField);
  const nextIndex = Math.max(0, Math.min(captureFields.length - 1, currentIndex + direction));
  if (nextIndex === currentIndex) return;
  activateCaptureField(captureFields[nextIndex], { focus: false });
  window.setTimeout(() => el('mobileFieldInput')?.focus(), 0);
}

function writeMobileInputToActiveField() {
  const input = el('mobileFieldInput');
  if (!input) return;
  const field = app.activeCaptureField;
  const target = el(`field-${field}`);
  if (!target) return;
  target.value = input.value;
  updateMobileCaptureDisplay({ syncInput: false });
  scheduleDraftSave();
  refreshSuggestions(field);
}

function renderMobileSuggestions(field, values = []) {
  const node = el('mobileSuggestionButtons');
  if (!node || field !== app.activeCaptureField) return;
  const deduped = [];
  ['-', ...(values || [])].forEach((value) => {
    const normalized = String(value ?? '').trim();
    if (!normalized || deduped.includes(normalized)) return;
    deduped.push(normalized);
  });
  node.innerHTML = deduped.slice(0, 8).map((value) => `
    <button type="button" class="mobile-suggestion-button" data-mobile-suggestion="${escapeAttribute(value)}">${escapeHtml(value)}</button>
  `).join('');
  node.querySelectorAll('[data-mobile-suggestion]').forEach((button) => {
    button.addEventListener('click', async () => {
      const field = app.activeCaptureField;
      setCaptureFieldValue(field, button.dataset.mobileSuggestion || '');
      if (field === 'geraeteart') {
        finalizeCaptureField('geraeteart');
      }
      refreshSuggestions(field, { forceRender: true });
      el('mobileFieldInput')?.focus();
    });
  });
}

function scheduleDraftSave() {
  window.clearTimeout(app.draftSaveTimer);
  app.draftSaveTimer = window.setTimeout(async () => {
    try {
      await fetchJson('/api/draft', {
        method: 'POST',
        body: JSON.stringify(readDraftFromInputs()),
      });
    } catch (error) {
      toast(`Entwurf nicht gespeichert: ${error.message}`);
    }
  }, 250);
}

function renderState(state) {
  app.state = state;

  const connected = state.connection_status === 'CONNECTED';
  el('connectionStatus').textContent = state.connection_status || 'DISCONNECTED';
  el('connectionDetail').textContent = state.connection_detail || '';
  el('connectionDot').classList.toggle('connected', connected);

  if (!app.draftInitialized) {
    applyServerDraft(state.draft || {});
    app.draftInitialized = true;
  }

  renderAppStatePill(state.app_state);
  renderMeasurement(state.current_measurement);
  el('deviceStatus').textContent = state.current_device_status || '–';
  el('sequenceMessage').textContent = state.last_sequence_message || '–';
  el('rawProtocol').textContent = state.current_raw_protocol?.raw_record || '–';

  const workflowDisabled = Boolean(state.is_sequence_running || state.is_loading);
  const saveDisabled = state.app_state !== 'MEASUREMENT_RECEIVED_NEEDS_METADATA' || Boolean(state.is_loading);
  el('leitungenButton').disabled = workflowDisabled;
  el('skButton').disabled = workflowDisabled;
  el('saveButton').disabled = saveDisabled;
  el('mobileLeitungenButton').disabled = workflowDisabled;
  el('mobileSkButton').disabled = workflowDisabled;
  el('mobileSaveButton').disabled = saveDisabled;
  el('connectButton').disabled = connected;
  el('disconnectButton').disabled = !connected;

  if (el('mobileWorkflowStatus')) {
    el('mobileWorkflowStatus').textContent = state.current_raw_protocol?.source || state.active_measurement_button || '–';
  }
  if (el('mobileDeviceStatus')) {
    el('mobileDeviceStatus').textContent = state.current_device_status || '–';
  }
  if (el('mobileRawProtocol')) {
    el('mobileRawProtocol').textContent = state.current_raw_protocol?.raw_record || '–';
  }

  if (Array.isArray(state.logs) && app.visibleLogs.length === 0) {
    app.visibleLogs = [...state.logs];
    renderTerminal();
  }
  renderCommList(state.comm_log || []);
  renderCustomButtons(state.custom_buttons || []);
  applySettings(state.settings || {});
  updateMobileContext();
  updateMobileCaptureDisplay({ syncInput: false });
}

function renderAppStatePill(value) {
  const node = el('appStatePill');
  node.classList.remove('pending', 'saved', 'fetching');
  const mapping = {
    READY_FOR_MEASUREMENT: 'Bereit',
    FETCHING_MEASUREMENT: 'Rufe Messdaten ab…',
    MEASUREMENT_RECEIVED_NEEDS_METADATA: 'Messdaten empfangen',
    POST_SAVE_CLEANUP: 'Speichere · PSI leer · Reset/Init…',
    SAVED: 'Gespeichert',
  };
  node.textContent = mapping[value] || value || 'Bereit';
  if (value === 'FETCHING_MEASUREMENT') node.classList.add('fetching');
  if (value === 'POST_SAVE_CLEANUP') node.classList.add('fetching');
  if (value === 'MEASUREMENT_RECEIVED_NEEDS_METADATA') node.classList.add('pending');
  if (value === 'SAVED') node.classList.add('saved');
}

function formatValue(value, suffix) {
  return value === null || value === undefined ? '' : `${value} ${suffix}`;
}

function measurementItems(measurement) {
  if (!measurement) return [];
  const rawItems = Array.isArray(measurement.values) ? measurement.values : [];
  const items = rawItems
    .map((item) => ({ label: String(item?.label ?? '').trim(), value: String(item?.value ?? '').trim() }))
    .filter((item) => item.label && item.value);
  if (items.length) return items;
  return [
    { label: 'Rpe', value: formatValue(measurement.rpe, 'Ω') },
    { label: 'Rins', value: formatValue(measurement.rins, 'MΩ') },
    { label: 'Ipe', value: formatValue(measurement.ipe, 'mA') },
    { label: 'U', value: formatValue(measurement.u, 'V') },
  ].filter((item) => item.value);
}

function renderMeasurement(measurement) {
  const nodes = [el('measurementSummary'), el('mobileMeasurementSummary')].filter(Boolean);
  const renderEmpty = '<div class="placeholder">Noch keine Messdaten übernommen.</div>';
  if (!measurement) {
    nodes.forEach((node) => {
      node.className = node.id === 'mobileMeasurementSummary' ? 'measurement-summary mobile-measurement-summary' : 'measurement-summary';
      node.innerHTML = renderEmpty;
    });
    return;
  }
  const items = measurementItems(measurement);
  const html = `
    <div class="measurement-title">
      <span>${measurement.is_ok ? 'STATUS: OK' : 'STATUS: FEHLER'}</span>
      <span class="muted">${escapeHtml(measurement.timestamp || '')}</span>
    </div>
    ${items.length ? `<div class="measurement-grid">${items.map((item) => measurementBox(item.label, item.value)).join('')}</div>` : '<div class="placeholder">Keine belegten Messwertfelder erkannt.</div>'}
  `;
  nodes.forEach((node) => {
    const mobileClass = node.id === 'mobileMeasurementSummary' ? ' mobile-measurement-summary' : '';
    node.className = `measurement-summary${mobileClass} ${measurement.is_ok ? 'ok' : 'failed'}`;
    node.innerHTML = html;
  });
}

function measurementBox(label, value) {
  return `<div class="measurement-value"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function appendLog(line) {
  app.visibleLogs.push(line);
  if (app.visibleLogs.length > 240) app.visibleLogs.shift();
  renderTerminal();
}

function renderTerminal() {
  const content = app.visibleLogs.length ? app.visibleLogs.join('\n') : 'Noch keine Verbindungslogs vorhanden.';
  const terminal = el('terminal');
  if (terminal) {
    terminal.textContent = content;
    terminal.scrollTop = terminal.scrollHeight;
  }
  const mobileTerminal = el('mobileTerminal');
  if (mobileTerminal) {
    mobileTerminal.textContent = content;
    mobileTerminal.scrollTop = mobileTerminal.scrollHeight;
  }
  const mobileDebugTerminal = el('mobileDebugTerminal');
  if (mobileDebugTerminal) {
    mobileDebugTerminal.textContent = content;
    mobileDebugTerminal.scrollTop = mobileDebugTerminal.scrollHeight;
  }
}

function renderCommList(entries) {
  const recent = [...entries].slice(-28).reverse();
  const html = recent.map((entry) => {
    const rx = entry.direction === 'RX';
    const okClass = rx ? (entry.checksum_ok ? 'ok' : 'bad') : '';
    return `
      <article class="comm-entry ${entry.direction.toLowerCase()} ${okClass}">
        <div class="comm-entry-top">
          <strong>${escapeHtml(entry.direction)}</strong>
          <span>${escapeHtml(entry.timestamp || '')}</span>
          <span>${entry.checksum_ok === null || entry.checksum_ok === undefined ? '' : (entry.checksum_ok ? 'Checksum OK' : 'Checksum FEHLER')}</span>
        </div>
        <code>${escapeHtml(entry.plain_text || '')}</code>
      </article>
    `;
  }).join('');
  [el('commList'), el('mobileCommList')].filter(Boolean).forEach((node) => {
    node.innerHTML = html;
  });
}

function applySettings(settings) {
  el('setting-host').value = settings.host ?? '10.10.100.254';
  el('setting-port').value = settings.port ?? '8899';
  el('setting-poll').value = settings.poll_interval_ms ?? '300';
  el('setting-timeout').value = settings.command_timeout_ms ?? '2500';
  el('setting-rst-sk').value = settings.rst_code_sk_i_ii ?? '3';
  el('setting-rst-leitungen').value = settings.rst_code_leitungen ?? '4';
  if (el('setting-rst-address')) el('setting-rst-address').value = settings.rst_target_address ?? '1';
  if (el('setting-post-reset-settle')) el('setting-post-reset-settle').value = settings.post_reset_settle_ms ?? '2200';
  el('setting-simulation').checked = settings.simulation_enabled === '1';
  el('setting-autosave').checked = settings.autosave_enabled !== '0';
  el('setting-autosave-path').value = settings.autosave_path ?? 'data/records_autosave.xlsx';
}

async function connectTcp() {
  try {
    await fetchJson('/api/connect', { method: 'POST', body: '{}' });
    toast('Verbindung aufgebaut.');
  } catch (error) {
    toast(`Connect fehlgeschlagen: ${error.message}`);
  }
}

async function disconnectTcp() {
  try {
    await fetchJson('/api/disconnect', { method: 'POST', body: '{}' });
    toast('Verbindung getrennt.');
  } catch (error) {
    toast(`Disconnect fehlgeschlagen: ${error.message}`);
  }
}

async function runSequence(kind) {
  const endpoint = kind === 'leitungen' ? '/api/sequence/leitungen' : '/api/sequence/sk';
  try {
    const result = await fetchJson(endpoint, { method: 'POST', body: '{}' });
    toast(result.result?.message || 'Sequenz beendet.');
  } catch (error) {
    toast(error.message);
  }
}

async function saveRecord() {
  try {
    const payload = readDraftFromInputs();
    const data = await fetchJson('/api/records/save', {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    el('field-id').value = '';
    updateMobileCaptureDisplay({ syncInput: app.activeCaptureField === 'id' });
    refreshSuggestions('id');
    const cleanupOk = data.post_save_cleanup?.ok !== false;
    toast(cleanupOk ? 'Datensatz gespeichert. PSI leer + Reset/Init erledigt.' : 'Datensatz gespeichert. Cleanup-Warnung im Log.');
  } catch (error) {
    toast(`Speichern fehlgeschlagen: ${error.message}`);
  }
}

async function sendCommand(command = null) {
  const raw = command ?? el('commandInput').value;
  const normalized = String(raw || '').trim();
  if (!normalized) {
    toast('Kein Befehl eingegeben.');
    return;
  }
  try {
    const data = await fetchJson('/api/command', {
      method: 'POST',
      body: JSON.stringify({ command: normalized }),
    });
    toast(`Antwort: ${data.frame?.payload_without_checksum || 'OK'}`);
    if (!command) el('commandInput').select();
  } catch (error) {
    toast(`Befehl fehlgeschlagen: ${error.message}`);
  }
}

async function manualAction(endpoint, successMessage) {
  try {
    await fetchJson(endpoint, { method: 'POST', body: '{}' });
    toast(successMessage);
  } catch (error) {
    toast(error.message);
  }
}

async function saveSettings() {
  try {
    const payload = {
      host: el('setting-host').value.trim(),
      port: Number(el('setting-port').value || 8899),
      poll_interval_ms: Number(el('setting-poll').value || 300),
      command_timeout_ms: Number(el('setting-timeout').value || 2500),
      rst_code_sk_i_ii: el('setting-rst-sk').value || '3',
      rst_code_leitungen: el('setting-rst-leitungen').value || '4',
      rst_target_address: el('setting-rst-address')?.value || '1',
      post_reset_settle_ms: el('setting-post-reset-settle')?.value || '2200',
      simulation_enabled: el('setting-simulation').checked,
      autosave_enabled: el('setting-autosave').checked,
      autosave_path: el('setting-autosave-path').value.trim() || 'data/records_autosave.xlsx',
    };
    await fetchJson('/api/settings', {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    el('settingsDialog').close();
    toast('Einstellungen gespeichert.');
  } catch (error) {
    toast(`Einstellungen nicht gespeichert: ${error.message}`);
  }
}

async function importExcel(file) {
  if (!file) return;
  const formData = new FormData();
  formData.append('file', file);
  try {
    const response = await fetch('/api/records/import.xlsx', {
      method: 'POST',
      body: formData,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.detail || 'Import fehlgeschlagen.');
    toast(`${data.imported} Datensätze importiert.`);
  } catch (error) {
    toast(`Import fehlgeschlagen: ${error.message}`);
  } finally {
    el('excelImportInput').value = '';
  }
}

async function refreshSuggestions(field, { forceRender = false } = {}) {
  if (!captureFields.includes(field)) return;
  const requestId = (app.suggestionRequestIds[field] || 0) + 1;
  app.suggestionRequestIds[field] = requestId;

  // Abort only the older request for the same field. Requests for other fields
  // must not overwrite or cancel the active mobile button list.
  try {
    app.suggestionAbortControllers[field]?.abort();
  } catch (_error) {}
  const controller = new AbortController();
  app.suggestionAbortControllers[field] = controller;

  const queryMap = {
    id: el('field-id').value,
    geraeteart: el('field-geraeteart').value,
    hersteller: el('field-hersteller').value,
  };
  const datalistMap = {
    id: 'suggestions-id',
    geraeteart: 'suggestions-device',
    hersteller: 'suggestions-manufacturer',
  };

  // Keep the UI responsive immediately, even if Chrome is still busy with a
  // previous fetch/WebSocket task. The '-' button is never optional.
  if (forceRender || field === app.activeCaptureField) {
    renderMobileSuggestions(field, app.suggestionCache[field] || ['-']);
  }

  try {
    const params = new URLSearchParams({
      field,
      q: queryMap[field] || '',
      geraeteart: el('field-geraeteart').value || '',
      ts: String(Date.now()),
    });
    const data = await fetchJson(`/api/suggestions?${params.toString()}`, { signal: controller.signal });
    if (requestId !== app.suggestionRequestIds[field]) return;
    const values = ['-', ...(data.values || []).filter((value) => String(value || '').trim() !== '-')];
    app.suggestionCache[field] = values;

    const datalist = el(datalistMap[field]);
    if (datalist) {
      datalist.innerHTML = values.map((value) => `<option value="${escapeAttribute(value)}"></option>`).join('');
    }
    if (field === app.activeCaptureField) {
      renderMobileSuggestions(field, values);
    }
  } catch (error) {
    if (error?.name === 'AbortError') return;
    // Suggestions are convenience only; do not spam the UI on failure.
    if (field === app.activeCaptureField) renderMobileSuggestions(field, app.suggestionCache[field] || ['-']);
  }
}

async function openHistory() {
  el('historyDialog').showModal();
  await loadHistory();
}

async function loadHistory() {
  try {
    const sort = el('historySort').value;
    const data = await fetchJson(`/api/records?sort=${encodeURIComponent(sort)}`);
    app.history = data.records || [];
    renderHistory();
  } catch (error) {
    toast(`Verlauf fehlgeschlagen: ${error.message}`);
  }
}

function renderHistory() {
  const search = el('historySearch').value.trim().toLowerCase();
  const resultFilter = el('historyResultFilter').value;
  const filtered = app.history.filter((record) => {
    const ok = Boolean(record.measurement?.is_ok);
    if (resultFilter === 'ok' && !ok) return false;
    if (resultFilter === 'failed' && ok) return false;
    if (!search) return true;
    const haystack = [
      record.metadata?.id,
      record.metadata?.geraeteart,
      record.metadata?.hersteller,
      record.metadata?.kunde,
      record.metadata?.raum_etage,
      record.metadata?.typ_modell,
      record.metadata?.seriennummer,
      record.metadata?.pruefer,
      record.metadata?.zusatztext,
      record.measurement?.rpe,
      record.measurement?.rins,
      record.measurement?.ipe,
      record.measurement?.u,
      ...(measurementItems(record.measurement).flatMap((item) => [item.label, item.value])),
    ].filter(Boolean).join(' ').toLowerCase();
    return haystack.includes(search);
  });
  el('historyCount').textContent = `${filtered.length} von ${app.history.length} Datensätzen angezeigt`;
  el('historyList').innerHTML = filtered.map(renderHistoryItem).join('');
  document.querySelectorAll('[data-edit-record]').forEach((button) => {
    button.addEventListener('click', () => openEditRecord(Number(button.dataset.editRecord)));
  });
}

function renderHistoryItem(record) {
  const ok = Boolean(record.measurement?.is_ok);
  const meta = record.metadata || {};
  const meas = record.measurement || {};
  const historyMeasurementItems = measurementItems(meas);
  const measurementHtml = historyMeasurementItems.length
    ? `<div class="history-measurement-grid">${historyMeasurementItems.map((item) => measurementBox(item.label, item.value)).join('')}</div>`
    : '<span class="muted">Keine belegten Messwertfelder erkannt.</span>';
  return `
    <article class="history-item">
      <div class="history-top">
        <strong>${escapeHtml(meta.id || 'Ohne ID')}</strong>
        <span>${escapeHtml(meta.geraeteart || '–')}</span>
        <span>${escapeHtml(meta.hersteller || '–')}</span>
        <span>${escapeHtml(meta.raum_etage || 'Kein Raum')}</span>
        <span class="history-result ${ok ? 'ok' : 'failed'}">${ok ? 'OK' : 'Fehler'}</span>
      </div>
      <div class="history-meta">
        <span>Messung: ${ok ? 'BESTANDEN' : 'NICHT BESTANDEN'} · Gespeichert: ${escapeHtml(record.created_at || '')}</span>
        <div class="history-measurements">${measurementHtml}</div>
        <span>Typ/Modell: ${escapeHtml(meta.typ_modell || '–')} · Seriennummer: ${escapeHtml(meta.seriennummer || '–')} · Prüfer: ${escapeHtml(meta.pruefer || '–')}</span>
        <span>Bemerkung: ${escapeHtml(meta.zusatztext || '–')}</span>
      </div>
      <div class="modal-actions">
        <button class="secondary tiny" data-edit-record="${record.id}">Datensatz bearbeiten</button>
      </div>
    </article>
  `;
}

function openEditRecord(recordId) {
  const record = app.history.find((item) => item.id === recordId);
  if (!record) return;
  const meta = record.metadata || {};
  el('edit-record-id').value = recordId;
  ['id', 'geraeteart', 'hersteller', 'kunde', 'raum_etage', 'typ_modell', 'seriennummer', 'pruefer', 'zusatztext'].forEach((field) => {
    el(`edit-${field}`).value = meta[field] || '';
  });
  el('editRecordDialog').showModal();
}

async function saveEditedRecord() {
  const recordId = Number(el('edit-record-id').value);
  const payload = {};
  ['id', 'geraeteart', 'hersteller', 'kunde', 'raum_etage', 'typ_modell', 'seriennummer', 'pruefer', 'zusatztext'].forEach((field) => {
    payload[field] = el(`edit-${field}`).value || '';
  });
  try {
    await fetchJson(`/api/records/${recordId}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    });
    el('editRecordDialog').close();
    await loadHistory();
    toast('Datensatz aktualisiert.');
  } catch (error) {
    toast(`Änderung fehlgeschlagen: ${error.message}`);
  }
}

function renderCustomButtons(buttons) {
  const node = el('customButtons');
  node.innerHTML = buttons.map((button) => `
    <article class="custom-button-card">
      <h3>${escapeHtml(button.name)}</h3>
      <pre>${escapeHtml((button.commands || '').split(/\r?\n/).slice(0, 4).join('\n') || 'Noch leer')}</pre>
      <div class="custom-button-actions">
        <button data-run-custom="${button.id}">Start</button>
        <button class="secondary" data-edit-custom="${button.id}">Edit</button>
      </div>
    </article>
  `).join('');
  document.querySelectorAll('[data-run-custom]').forEach((button) => {
    button.addEventListener('click', () => runCustomButton(Number(button.dataset.runCustom)));
  });
  document.querySelectorAll('[data-edit-custom]').forEach((button) => {
    button.addEventListener('click', () => openCustomButtonEditor(Number(button.dataset.editCustom)));
  });
}

function openCustomButtonEditor(buttonId) {
  const button = (app.state?.custom_buttons || []).find((item) => item.id === buttonId);
  if (!button) return;
  el('custom-button-id').value = buttonId;
  el('custom-button-name').value = button.name || `USER ${buttonId}`;
  el('custom-button-commands').value = button.commands || '';
  el('customButtonDialog').showModal();
}

async function saveCustomButton() {
  const buttonId = Number(el('custom-button-id').value);
  try {
    await fetchJson(`/api/custom-buttons/${buttonId}`, {
      method: 'PUT',
      body: JSON.stringify({
        name: el('custom-button-name').value,
        commands: el('custom-button-commands').value,
      }),
    });
    el('customButtonDialog').close();
    toast('Button gespeichert.');
  } catch (error) {
    toast(`Button nicht gespeichert: ${error.message}`);
  }
}

async function runCustomButton(buttonId) {
  try {
    const data = await fetchJson(`/api/custom-buttons/${buttonId}/run`, {
      method: 'POST',
      body: '{}',
    });
    toast(data.ok ? 'Sequenz-Button abgeschlossen.' : 'Sequenz-Button mit Abbruch beendet.');
  } catch (error) {
    toast(`Sequenz-Button fehlgeschlagen: ${error.message}`);
  }
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function escapeAttribute(value) {
  return escapeHtml(value).replaceAll('`', '&#096;');
}

function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  app.ws = new WebSocket(`${protocol}//${window.location.host}/ws`);
  app.ws.onopen = () => {
    app.ws.send('ready');
  };
  app.ws.onmessage = (event) => {
    try {
      const payload = JSON.parse(event.data);
      if (payload.type === 'state') {
        renderState(payload.state);
      } else if (payload.type === 'draft') {
        applyServerDraft(payload.draft || {});
      } else if (payload.type === 'log') {
        appendLog(payload.line);
      } else if (payload.type === 'comm') {
        const current = app.state?.comm_log || [];
        current.push(payload.entry);
        if (current.length > 240) current.shift();
        if (app.state) app.state.comm_log = current;
        renderCommList(current);
      }
    } catch (_error) {
      // Ignore malformed socket messages.
    }
  };
  app.ws.onclose = () => {
    window.setTimeout(connectWebSocket, 1200);
  };
}

async function loadInitialState() {
  try {
    const state = await fetchJson('/api/state');
    renderState(state);
  } catch (error) {
    toast(`Initialisierung fehlgeschlagen: ${error.message}`);
  }
}

function bindEvents() {
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => activateTab(tab.dataset.tab));
  });

  el('connectButton').addEventListener('click', connectTcp);
  el('disconnectButton').addEventListener('click', disconnectTcp);
  el('leitungenButton').addEventListener('click', () => runSequence('leitungen'));
  el('skButton').addEventListener('click', () => runSequence('sk'));
  el('saveButton').addEventListener('click', saveRecord);
  el('mobileLeitungenButton').addEventListener('click', () => runSequence('leitungen'));
  el('mobileSkButton').addEventListener('click', () => runSequence('sk'));
  el('mobileSaveButton').addEventListener('click', saveRecord);
  el('sendCommandButton').addEventListener('click', () => sendCommand());
  el('commandInput').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') sendCommand();
  });

  document.querySelectorAll('[data-command]').forEach((button) => {
    button.addEventListener('click', () => sendCommand(button.dataset.command));
  });

  el('manualMesButton').addEventListener('click', () => manualAction('/api/manual/mes', 'MES? abgefragt.'));
  el('manualEnterButton').addEventListener('click', () => manualAction('/api/manual/enter', 'ENTER gesendet.'));
  el('fetchLatestButton').addEventListener('click', () => manualAction('/api/manual/fetch-latest', 'Letzter PSI-Datensatz übernommen.'));
  el('resetInitButton').addEventListener('click', () => manualAction('/api/manual/reset-init', 'Reset + Adressierung abgeschlossen.'));
  el('clearPsiButton').addEventListener('click', () => {
    if (window.confirm('PSI-Speicher wirklich löschen? MEM! ist nicht dekorativ.')) {
      manualAction('/api/manual/clear-psi', 'PSI-Speicher gelöscht.');
    }
  });

  draftFields.forEach((field) => {
    const node = el(`field-${field}`);
    node.addEventListener('input', () => {
      scheduleDraftSave();
      updateMobileContext();
      updateMobileCaptureDisplay({ syncInput: false });
    });
  });
  el('field-id').addEventListener('input', () => refreshSuggestions('id'));
  el('field-geraeteart').addEventListener('input', () => refreshSuggestions('geraeteart'));
  el('field-hersteller').addEventListener('input', () => refreshSuggestions('hersteller'));
  el('field-geraeteart').addEventListener('change', () => {
    finalizeCaptureField('geraeteart');
    refreshSuggestions('hersteller');
  });

  document.querySelectorAll('[data-capture-field]').forEach((row) => {
    row.addEventListener('pointerdown', (event) => { event.preventDefault(); activateCaptureField(row.dataset.captureField); });
  });
  el('mobileFieldUp').addEventListener('pointerdown', (event) => { event.preventDefault(); stepCaptureField(-1); });
  el('mobileFieldDown').addEventListener('pointerdown', (event) => { event.preventDefault(); stepCaptureField(1); });
  el('mobileFieldInput').addEventListener('input', writeMobileInputToActiveField);
  el('mobileFieldInput').addEventListener('focus', () => refreshSuggestions(app.activeCaptureField, { forceRender: true }));
  el('mobileFieldInput').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); stepCaptureField(1); }
  });

  el('settingsButton').addEventListener('click', () => el('settingsDialog').showModal());
  el('settingsCancelButton').addEventListener('click', () => el('settingsDialog').close());
  el('settingsSaveButton').addEventListener('click', saveSettings);
  el('excelImportInput').addEventListener('change', (event) => importExcel(event.target.files?.[0]));

  el('historyButton').addEventListener('click', openHistory);
  el('historyCloseButton').addEventListener('click', () => el('historyDialog').close());
  el('historySearch').addEventListener('input', renderHistory);
  el('historySort').addEventListener('change', loadHistory);
  el('historyResultFilter').addEventListener('change', renderHistory);

  el('editCancelButton').addEventListener('click', () => el('editRecordDialog').close());
  el('editSaveButton').addEventListener('click', saveEditedRecord);

  el('customCancelButton').addEventListener('click', () => el('customButtonDialog').close());
  el('customSaveButton').addEventListener('click', saveCustomButton);

  el('clearLogButton').addEventListener('click', () => {
    app.visibleLogs = [];
    renderTerminal();
  });
}

window.addEventListener('DOMContentLoaded', async () => {
  bindEvents();
  await loadInitialState();
  connectWebSocket();
  // During field testing Chrome kept serving an old cached UI via the previous
  // service worker. For the mobile capture workflow we prefer fresh local files.
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.getRegistrations()
      .then((regs) => Promise.all(regs.map((reg) => reg.unregister())))
      .catch(() => {});
  }
  if ('caches' in window) {
    caches.keys()
      .then((keys) => Promise.all(keys.map((key) => caches.delete(key))))
      .catch(() => {});
  }
  refreshSuggestions('id', { forceRender: true });
  refreshSuggestions('geraeteart');
  refreshSuggestions('hersteller');
});
