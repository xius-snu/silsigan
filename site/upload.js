(function () {
  const API_BASE = (location.hostname === 'localhost' || location.hostname === '127.0.0.1')
    ? 'http://localhost:3000'
    : 'https://silsigan.onrender.com';
  const STORAGE_KEY = 'silsigan_private_code';

  const gate = document.getElementById('gate');
  const workspace = document.getElementById('workspace');
  const lockBtn = document.getElementById('lock-btn');
  const gateForm = document.getElementById('gate-form');
  const codeInput = document.getElementById('code-input');
  const gateError = document.getElementById('gate-error');
  const gateSubmit = document.getElementById('gate-submit');
  const codeLabel = document.getElementById('code-label');
  const creditsRemaining = document.getElementById('credits-remaining');
  const creditsMeta = document.getElementById('credits-meta');
  const dropzone = document.getElementById('dropzone');
  const fileInput = document.getElementById('file-input');
  const fileLabel = document.getElementById('file-label');
  const translateOptions = document.getElementById('translate-options');
  const targetLanguage = document.getElementById('target-language');
  const sourceLanguage = document.getElementById('source-language');
  const uploadForm = document.getElementById('upload-form');
  const uploadError = document.getElementById('upload-error');
  const uploadSubmit = document.getElementById('upload-submit');
  const resultCard = document.getElementById('result-card');
  const resultKicker = document.getElementById('result-kicker');
  const resultFile = document.getElementById('result-file');
  const loading = document.getElementById('loading');
  const loadingText = document.getElementById('loading-text');
  const resultBody = document.getElementById('result-body');
  const historyList = document.getElementById('history-list');
  const historyEmpty = document.getElementById('history-empty');

  let privateCode = '';
  let selectedFile = null;
  let pollTimer = null;
  let activeJobId = null;
  let formBusy = false;

  function show(el) { el.classList.remove('hidden'); }
  function hide(el) { el.classList.add('hidden'); }

  function setError(node, message) {
    if (!message) {
      hide(node);
      node.textContent = '';
      return;
    }
    node.textContent = message;
    show(node);
  }

  function formatDuration(seconds) {
    const s = Math.max(0, Math.round(Number(seconds) || 0));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (h > 0 && m > 0) return h + 'h ' + m + 'm';
    if (h > 0) return h + 'h';
    if (m > 0) return m + 'm';
    if (s === 0) return '0m';
    return s + 's';
  }

  function authHeaders(extra) {
    return Object.assign({ Authorization: 'Bearer ' + privateCode }, extra || {});
  }

  async function api(path, options) {
    const res = await fetch(API_BASE + path, options);
    let data = null;
    try { data = await res.json(); } catch (_) { data = {}; }
    if (!res.ok) {
      const err = new Error(data.error || ('Request failed (' + res.status + ')'));
      err.status = res.status;
      throw err;
    }
    return data;
  }

  function selectedMode() {
    const checked = uploadForm.querySelector('input[name="mode"]:checked');
    return checked ? checked.value : 'transcribe';
  }

  function updateModeUi() {
    if (selectedMode() === 'translate') show(translateOptions);
    else hide(translateOptions);
  }

  function renderCredits(account) {
    creditsRemaining.textContent = formatDuration(account.remainingSeconds) + ' left';
    creditsMeta.textContent = formatDuration(account.usedSeconds) + ' used of '
      + formatDuration(account.creditSeconds);
    if (account.code) codeLabel.textContent = account.code;
  }

  function copyButton(label, getText) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'text-btn';
    btn.textContent = label;
    btn.addEventListener('click', async () => {
      const text = getText();
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        const prev = btn.textContent;
        btn.textContent = 'Copied';
        setTimeout(() => { btn.textContent = prev; }, 1200);
      } catch (_) {
        btn.textContent = 'Copy failed';
      }
    });
    return btn;
  }

  function textBlock(title, text) {
    const wrap = document.createElement('div');
    wrap.className = 'result-block';
    const head = document.createElement('div');
    head.className = 'result-block-head';
    const h = document.createElement('h2');
    h.textContent = title;
    head.appendChild(h);
    head.appendChild(copyButton('Copy', () => text));
    const pre = document.createElement('pre');
    pre.className = 'result-text';
    pre.textContent = text || '';
    wrap.appendChild(head);
    wrap.appendChild(pre);
    return wrap;
  }

  function showLoading(job) {
    show(resultCard);
    show(loading);
    resultBody.innerHTML = '';
    resultKicker.textContent = job.mode === 'translate' ? 'Translating' : 'Transcribing';
    resultFile.textContent = job.filename || '';
    loadingText.textContent = job.mode === 'translate'
      ? 'Transcribing and translating… this can take a few minutes for long files.'
      : 'Transcribing… this can take a few minutes for long files.';
  }

  function showJob(job) {
    show(resultCard);
    hide(loading);
    resultBody.innerHTML = '';
    resultFile.textContent = job.filename || '';
    if (job.status === 'failed') {
      resultKicker.textContent = 'Failed';
      const p = document.createElement('p');
      p.className = 'form-error';
      p.textContent = job.error || 'This file could not be processed.';
      resultBody.appendChild(p);
      return;
    }
    if (job.status !== 'completed') {
      showLoading(job);
      return;
    }
    resultKicker.textContent = 'Done';
    resultBody.appendChild(textBlock('Transcription', job.transcription || ''));
    if (job.mode === 'translate' || job.translation) {
      resultBody.appendChild(textBlock('Translation', job.translation || ''));
    }
    if (job.transcription || job.translation) {
      const all = [job.transcription, job.translation].filter(Boolean).join('\n\n');
      const row = document.createElement('div');
      row.className = 'result-actions';
      row.appendChild(copyButton('Copy all', () => all));
      resultBody.appendChild(row);
    }
  }

  function renderHistory(jobs) {
    historyList.innerHTML = '';
    if (!jobs || jobs.length === 0) {
      historyEmpty.textContent = 'No files yet. Upload a recording to get started.';
      historyList.appendChild(historyEmpty);
      return;
    }
    for (const job of jobs) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'history-item' + (job.id === activeJobId ? ' is-active' : '');
      const title = document.createElement('strong');
      title.textContent = job.filename || ('Job ' + job.id);
      const meta = document.createElement('span');
      const bits = [
        job.mode === 'translate' ? 'Transcribe + translate' : 'Transcribe',
        job.status === 'completed' ? formatDuration(job.durationSeconds) : job.status,
      ];
      if (job.createdAt) bits.unshift(new Date(job.createdAt).toLocaleString());
      meta.textContent = bits.join(' · ');
      btn.appendChild(title);
      btn.appendChild(meta);
      btn.addEventListener('click', () => {
        activeJobId = job.id;
        if (job.status === 'processing' || job.status === 'queued') {
          showLoading(job);
          startPolling(job.id);
        } else {
          stopPolling();
          showJob(job);
        }
        renderHistory(jobs);
      });
      historyList.appendChild(btn);
    }
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function setBusy(busy) {
    formBusy = busy;
    uploadSubmit.disabled = formBusy || !selectedFile;
    dropzone.classList.toggle('is-busy', formBusy);
  }

  function startPolling(jobId) {
    stopPolling();
    activeJobId = jobId;
    setBusy(true);
    const tick = async () => {
      try {
        const data = await api('/api/private/jobs/' + jobId, { headers: authHeaders() });
        renderCredits(data);
        if (data.job.status === 'completed' || data.job.status === 'failed') {
          stopPolling();
          setBusy(false);
          showJob(data.job);
          refreshSession();
        } else {
          showLoading(data.job);
        }
      } catch (err) {
        setError(uploadError, err.message);
      }
    };
    pollTimer = setInterval(tick, 2500);
    tick();
  }

  async function refreshSession() {
    const account = await api('/api/private/session', { headers: authHeaders() });
    renderCredits(account);
    renderHistory(account.jobs || []);
    return account;
  }

  function enterWorkspace(account) {
    privateCode = account.code;
    sessionStorage.setItem(STORAGE_KEY, privateCode);
    hide(gate);
    show(workspace);
    show(lockBtn);
    renderCredits(account);
    renderHistory(account.jobs || []);
    const inflight = (account.jobs || []).find((j) => j.status === 'processing' || j.status === 'queued');
    if (inflight) {
      activeJobId = inflight.id;
      showLoading(inflight);
      startPolling(inflight.id);
    }
  }

  function lock() {
    stopPolling();
    setBusy(false);
    privateCode = '';
    selectedFile = null;
    activeJobId = null;
    sessionStorage.removeItem(STORAGE_KEY);
    fileInput.value = '';
    fileLabel.textContent = 'Drop a recording here, or choose a file';
    uploadSubmit.disabled = true;
    hide(workspace);
    hide(lockBtn);
    hide(resultCard);
    setError(gateError, '');
    setError(uploadError, '');
    show(gate);
    codeInput.value = '';
    codeInput.focus();
  }

  function setFile(file) {
    selectedFile = file || null;
    fileLabel.textContent = selectedFile
      ? selectedFile.name
      : 'Drop a recording here, or choose a file';
    uploadSubmit.disabled = formBusy || !selectedFile;
    setError(uploadError, '');
  }

  gateForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    setError(gateError, '');
    gateSubmit.disabled = true;
    try {
      const account = await api('/api/private/unlock', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code: codeInput.value }),
      });
      enterWorkspace(account);
    } catch (err) {
      setError(gateError, err.message);
    } finally {
      gateSubmit.disabled = false;
    }
  });

  lockBtn.addEventListener('click', lock);

  uploadForm.addEventListener('change', (event) => {
    if (event.target.name === 'mode') updateModeUi();
  });

  dropzone.addEventListener('click', () => fileInput.click());
  dropzone.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      fileInput.click();
    }
  });
  fileInput.addEventListener('change', () => setFile(fileInput.files[0]));
  ['dragenter', 'dragover'].forEach((type) => {
    dropzone.addEventListener(type, (event) => {
      event.preventDefault();
      dropzone.classList.add('is-hover');
    });
  });
  ['dragleave', 'drop'].forEach((type) => {
    dropzone.addEventListener(type, (event) => {
      event.preventDefault();
      dropzone.classList.remove('is-hover');
    });
  });
  dropzone.addEventListener('drop', (event) => {
    const file = event.dataTransfer.files && event.dataTransfer.files[0];
    if (file) setFile(file);
  });

  uploadForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!selectedFile || !privateCode) return;
    setError(uploadError, '');
    setBusy(true);
    const mode = selectedMode();
    const body = new FormData();
    body.append('code', privateCode);
    body.append('mode', mode);
    body.append('file', selectedFile, selectedFile.name);
    if (mode === 'translate') body.append('targetLanguage', targetLanguage.value);
    if (sourceLanguage.value) body.append('sourceLanguage', sourceLanguage.value);

    show(resultCard);
    show(loading);
    resultBody.innerHTML = '';
    resultKicker.textContent = 'Uploading';
    resultFile.textContent = selectedFile.name;
    loadingText.textContent = 'Uploading the file…';

    try {
      const data = await api('/api/private/jobs', {
        method: 'POST',
        headers: authHeaders(),
        body,
      });
      activeJobId = data.job.id;
      showLoading(data.job);
      startPolling(data.job.id);
      refreshSession().catch(() => {});
    } catch (err) {
      hide(loading);
      setBusy(false);
      setError(uploadError, err.message);
    }
  });

  updateModeUi();

  const saved = sessionStorage.getItem(STORAGE_KEY);
  if (saved) {
    privateCode = saved;
    refreshSession()
      .then(enterWorkspace)
      .catch(lock);
  }
})();
