// ── Preferences (localStorage) ──

const prefs = {
  _key: 'trionyx_prefs',

  _load() {
    try { return JSON.parse(localStorage.getItem(this._key)) || {}; }
    catch { return {}; }
  },

  get(key, fallback) {
    const val = this._load()[key];
    return val === undefined ? fallback : val;
  },

  set(key, value) {
    const data = this._load();
    data[key] = value;
    localStorage.setItem(this._key, JSON.stringify(data));
  },
};

document.addEventListener('DOMContentLoaded', () => {
  const config = document.getElementById('sse-config');
  if (!config) return;

  const sseUrl = config.dataset.sseUrl;
  const lastTimestamp = config.dataset.lastTimestamp || '';
  const isActive = config.dataset.isActive === 'true';
  const agentName = config.dataset.agentName;
  const sessionId = config.dataset.sessionId;
  const chatMessages = document.getElementById('chat-messages');
  const sseStatus = document.getElementById('sse-status');
  const promptInput = document.querySelector('.prompt-input');
  const promptForm = document.querySelector('.prompt-bar');
  const sendBtn = promptForm ? promptForm.querySelector('.btn-send') : null;

  if (chatMessages) {
    chatMessages.scrollTop = chatMessages.scrollHeight;
    addCopyButtons(chatMessages);
  }

  // ── Restore preferences ──

  const savedSidebar = prefs.get('sidebarOpen', undefined);
  if (savedSidebar !== undefined) {
    const panel = document.getElementById('ctx-panel');
    const toggle = document.getElementById('ctx-toggle');
    if (panel) panel.classList.toggle('open', savedSidebar);
    if (toggle) toggle.setAttribute('aria-expanded', savedSidebar);
  }

  if (prefs.get('toolCallsExpanded', false) && chatMessages) {
    chatMessages.querySelectorAll('.msg-tool').forEach(el => el.open = true);
  }

  // ── Textarea auto-grow ──

  if (promptInput) {
    promptInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        promptForm.requestSubmit();
      }
    });

    promptInput.addEventListener('input', () => autoResize(promptInput));
  }

  let lastSentContent = null;

  if (promptForm) {
    promptForm.addEventListener('htmx:beforeRequest', () => {
      if (promptInput) lastSentContent = promptInput.value.trim();
    });
    promptForm.addEventListener('htmx:afterRequest', (e) => {
      promptForm.reset();
      if (promptInput) promptInput.style.height = '';
      if (chatMessages) chatMessages.scrollTop = chatMessages.scrollHeight;
      if (sendBtn) {
        sendBtn.disabled = true;
        setTimeout(() => { sendBtn.disabled = false; }, 1000);
      }
    });
  }

  // ── Timestamps ──

  updateTimestamps(chatMessages);
  setInterval(() => updateTimestamps(chatMessages), 60000);

  // ── SSE ──

  let watermark = lastTimestamp;

  function setStatus(state, label) {
    if (!sseStatus) return;
    sseStatus.className = 'sse-status ' + state;
    sseStatus.textContent = label;
  }

  if (!sseUrl) return;

  function connectSSE(url) {
    url = url || sseUrl;
    setStatus('connecting', 'connecting...');
    const es = new EventSource(url);

    // Gateway-owned list (SessionEvents.chat_visible + sse_meta),
    // embedded by the chat template as #sse-event-types.
    let eventTypes = [];
    try {
      const el = document.getElementById('sse-event-types');
      eventTypes = (el && JSON.parse(el.textContent)) || [];
    } catch (e) {
      eventTypes = [];
    }

    eventTypes.forEach(type => {
      es.addEventListener(type, (event) => {
        const data = JSON.parse(event.data);

        if (type === 'waiting') {
          setStatus('waiting', 'waiting for session');
          return;
        }

        if (type === 'connected' || type === 'session_start') {
          setStatus('connected', 'live');
          return;
        }

        if (watermark && data.timestamp && data.timestamp <= watermark) return;

        if (type === 'user_prompt' && lastSentContent && data.content === lastSentContent) {
          lastSentContent = null;
          if (data.timestamp) watermark = data.timestamp;
          return;
        }

        if (type === 'tool_result' && mergeToolResult(chatMessages, data)) {
          if (data.timestamp) watermark = data.timestamp;
          return;
        }

        const html = renderEvent(type, data);
        if (html && chatMessages) {
          chatMessages.insertAdjacentHTML('beforeend', html);
          chatMessages.scrollTop = chatMessages.scrollHeight;
          updateTimestamps(chatMessages);
          addCopyButtons(chatMessages);
        }

        if (type === 'result' && data.cost_usd) {
          updateSessionCost(data.cost_usd);
        }

        if (data.timestamp) watermark = data.timestamp;

        if (type === 'result') {
          setStatus('connected', 'idle');
        }

        if (type === 'session_stop' || type === 'port_down') {
          setStatus('disconnected', 'session ended');
          es.close();
        }
      });
    });

    es.onopen = () => {};

    es.onerror = () => {
      setStatus('disconnected', 'disconnected');
      es.close();
      setTimeout(connectSSE, 5000);
    };
  }

  connectSSE();
});

// ── Tool result merging ──

function mergeToolResult(container, data) {
  if (!container || !data.id) return false;
  const el = container.querySelector(`.msg-tool[data-tool-id="${CSS.escape(data.id)}"]`);
  if (!el || el.querySelector('.tool-result-section')) return false;
  const cls = data.is_error ? ' error' : '';
  const content = (data.content || '').slice(0, 3000);
  el.insertAdjacentHTML('beforeend',
    `<div class="tool-result-section${cls}">` +
    `<div class="tool-result-label">result</div>` +
    `<div class="markdown tool-result-content">${renderMarkdown(content)}</div></div>`);
  return true;
}

// ── Event rendering ──

function renderEvent(type, data) {
  const ts = data.timestamp || '';
  switch (type) {
    case 'text':
      return `<div class="msg msg-agent markdown" data-ts="${escapeAttr(ts)}">${renderMarkdown(data.content || '')}</div>`;

    case 'user_prompt':
      return `<div class="msg msg-user" data-ts="${escapeAttr(ts)}">${escapeHtml(data.content || '')}</div>`;

    case 'tool_use': {
      const openAttr = prefs.get('toolCallsExpanded', false) ? ' open' : '';
      return `<details class="msg-tool" data-ts="${escapeAttr(ts)}" data-tool-id="${escapeAttr(data.id || '')}"${openAttr}>` +
        `<summary>${escapeHtml(data.name || '')} ${formatToolBrief(data.name, data.input)}</summary>` +
        `<pre>${escapeHtml(JSON.stringify(data.input || {}, null, 2))}</pre></details>`;
    }

    case 'tool_result': {
      const cls = data.is_error ? ' error' : '';
      const content = (data.content || '').slice(0, 3000);
      return `<details class="msg-tool-result${cls}" data-ts="${escapeAttr(ts)}">` +
        `<summary>${escapeHtml(data.name || '')} result</summary>` +
        `<div class="markdown tool-result-content">${renderMarkdown(content)}</div></details>`;
    }

    case 'result':
      return `<div class="msg-result" data-ts="${escapeAttr(ts)}">${data.num_turns || 0} turns · ${data.duration_ms || 0}ms · $${(data.cost_usd || 0).toFixed(4)}</div>`;

    case 'error':
      return `<div class="msg msg-error" data-ts="${escapeAttr(ts)}">${escapeHtml(data.message || JSON.stringify(data))}</div>`;

    case 'ready':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">Runtime ready</div>`;

    case 'connected':
      return null;

    case 'risk_escalation':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">Risk escalated: ${escapeHtml(data.previous_risk || '')} → ${escapeHtml(data.effective_risk || '')} (${escapeHtml(data.source || '')})</div>`;

    case 'send_message':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">Message → <a href="/agents/${encodeURIComponent(data.to || '')}/" class="agent-link-card">${escapeHtml(data.to || '')}</a></div>`;

    case 'bcp_query':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">BCP query → <a href="/agents/${encodeURIComponent(data.to || '')}/" class="agent-link-card">${escapeHtml(data.to || '')}</a> (cat ${data.category || ''})</div>`;

    case 'session_stop':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">Session ended</div>`;

    case 'interrupted':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">Interrupted: ${escapeHtml(data.reason || '')}</div>`;

    case 'approval_request':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">Approval requested</div>`;

    case 'port_down':
      return `<div class="msg msg-error" data-ts="${escapeAttr(ts)}">Agent process terminated</div>`;

    case 'idle_timeout':
      return `<div class="msg msg-system" data-ts="${escapeAttr(ts)}">Idle timeout — saving memory</div>`;

    case 'image':
      return `<div class="msg msg-agent msg-image" data-ts="${escapeAttr(ts)}">` +
        `<img src="/workspace/images/${encodeURIComponent(agentName)}/${encodeURIComponent(sessionId)}/${encodeURIComponent(data.image_id || '')}"` +
        ` alt="${escapeAttr(data.filename || '')}" title="${escapeAttr(data.filename || '')}" loading="lazy">` +
        `<span class="image-caption">${escapeHtml(data.filename || '')}</span></div>`;

    case 'audio': {
      const audioUrl = `/workspace/audio/${encodeURIComponent(agentName)}/${encodeURIComponent(sessionId)}/${encodeURIComponent(data.audio_id || '')}`;
      return `<div class="msg msg-agent msg-audio" data-ts="${escapeAttr(ts)}">` +
        `<audio controls preload="metadata" src="${audioUrl}"></audio>` +
        `<span class="audio-caption">${escapeHtml(data.text_preview || '')}</span></div>`;
    }

    case 'page': {
      const pageUrl = `/workspace/pages/${encodeURIComponent(data.commit || '')}/${data.path || ''}`;
      const title = escapeHtml(data.title || data.filename || 'Page');
      return `<div class="msg msg-agent msg-page" data-ts="${escapeAttr(ts)}">` +
        `<div class="page-card" data-page-url="${escapeAttr(pageUrl)}">` +
        `<div class="page-card-header" onclick="togglePageCard(this)">` +
        `<svg class="page-card-icon" width="16" height="16" viewBox="0 0 16 16" fill="currentColor">` +
        `<path d="M4 0a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V4.414A2 2 0 0 0 13.414 3L11 .586A2 2 0 0 0 9.586 0H4zm5.5 1.5v2A1.5 1.5 0 0 0 11 5h2v9a.5.5 0 0 1-.5.5h-9A.5.5 0 0 1 3 14V2a.5.5 0 0 1 .5-.5h6z"/></svg>` +
        `<span class="page-card-title">${title}</span>` +
        `<span class="page-card-actions">` +
        `<a href="${escapeAttr(pageUrl)}" target="_blank" class="page-card-open" title="Open in new tab" onclick="event.stopPropagation()">&nearr;</a>` +
        `</span></div>` +
        `</div></div>`;
    }

    default:
      return null;
  }
}

// ── Timestamps ──

function updateTimestamps(container) {
  if (!container) return;
  container.querySelectorAll('[data-ts]').forEach(el => {
    const ts = el.getAttribute('data-ts');
    if (!ts) return;

    let span = el.querySelector(':scope > .msg-time');
    if (!span) {
      const summary = el.querySelector('summary');
      if (summary) {
        span = summary.querySelector('.msg-time');
      }
    }

    if (!span) {
      span = document.createElement('span');
      span.className = 'msg-time';
      const summary = el.querySelector('summary');
      if (summary) {
        summary.appendChild(span);
      } else {
        el.appendChild(span);
      }
    }

    span.textContent = relativeTime(ts);
    span.title = new Date(ts).toLocaleString();
  });
}

function relativeTime(isoStr) {
  const date = new Date(isoStr);
  if (isNaN(date.getTime())) return '';
  const diff = Math.floor((Date.now() - date.getTime()) / 1000);
  if (diff < 0) return 'just now';
  if (diff < 60) return 'just now';
  if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
  if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
  if (diff < 604800) return Math.floor(diff / 86400) + 'd ago';
  return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

// ── Tool briefs ──
// Per-tool specs come from the gateway (ToolRegistry.brief_specs, embedded
// by the chat template as #tool-briefs). Each spec is an ordered list of
// segments: {keys, prefix?, suffix?, max_len?, transform?}. Tools without
// a spec render generically from their first input field.

let briefSpecs = null;

function getBriefSpecs() {
  if (briefSpecs === null) {
    const el = document.getElementById('tool-briefs');
    try {
      briefSpecs = (el && JSON.parse(el.textContent)) || {};
    } catch (e) {
      briefSpecs = {};
    }
  }
  return briefSpecs;
}

function stringifyBriefValue(v) {
  if (typeof v === 'string') return v;
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

function formatToolBrief(name, input) {
  if (!input) return '';

  const segments = getBriefSpecs()[name];
  if (segments && segments.length) {
    let out = '';
    for (const seg of segments) {
      let value;
      for (const k of (seg.keys || [])) {
        const v = input[k];
        if (v !== undefined && v !== null && v !== '') { value = v; break; }
      }
      if (value === undefined) continue;
      let text = stringifyBriefValue(value);
      if (seg.transform === 'path') text = shortPath(text);
      if (seg.max_len && text.length > seg.max_len) text = text.slice(0, seg.max_len) + '…';
      out += (seg.prefix || '') + text + (seg.suffix || '');
    }
    return escapeHtml(out);
  }

  const keys = Object.keys(input);
  if (!keys.length) return '';
  const text = stringifyBriefValue(input[keys[0]]);
  return escapeHtml(text.slice(0, 80) + (text.length > 80 ? '…' : ''));
}

// ── Utilities ──

function shortPath(path) {
  if (!path) return '';
  const clean = path.replace('/workspace/', '');
  const parts = clean.split('/');
  if (parts.length > 3) return '.../' + parts.slice(-2).join('/');
  return clean;
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function escapeAttr(text) {
  return String(text ?? '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function renderMarkdown(text) {
  if (typeof marked !== 'undefined') {
    marked.setOptions({ breaks: true, gfm: true });
    return marked.parse(text).replace(/<a href="/g, '<a target="_blank" rel="noopener" href="');
  }
  return escapeHtml(text);
}

function updateSessionCost(costUsd) {
  const el = document.getElementById('session-cost');
  if (!el) return;
  const current = parseFloat(el.textContent.replace('$', '')) || 0;
  const total = current + costUsd;
  // Tiny costs get extra precision so they don't render as "0.00"
  // (mirrors format_session_cost in views/helpers.py).
  el.textContent = '$' + (total < 0.005 ? total.toFixed(4) : total.toFixed(2));
}

function autoResize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 200) + 'px';
}

function togglePageCard(header) {
  const card = header.closest('.page-card');
  if (!card) return;
  const expanded = card.classList.toggle('expanded');
  if (expanded) {
    let iframe = card.querySelector('.page-card-frame');
    if (!iframe) {
      iframe = document.createElement('iframe');
      iframe.className = 'page-card-frame';
      iframe.setAttribute('sandbox', 'allow-scripts');
      iframe.loading = 'lazy';
      iframe.src = card.dataset.pageUrl;
      card.appendChild(iframe);
    }
  }
}

// ── Copy buttons ──

const COPY_SVG = '<svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 14.25Z"/><path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z"/></svg>';
const CHECK_SVG = '<svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z"/></svg>';

function addCopyButtons(container) {
  if (!container) return;

  container.querySelectorAll('.msg-agent:not([data-copy-btn])').forEach(el => {
    el.setAttribute('data-copy-btn', '1');
    const btn = document.createElement('button');
    btn.className = 'copy-btn';
    btn.innerHTML = COPY_SVG;
    btn.title = 'Copy';
    btn.setAttribute('aria-label', 'Copy');
    btn.onclick = (e) => {
      e.stopPropagation();
      const text = el.textContent.replace(btn.textContent, '').trim();
      copyToClipboard(text, btn);
    };
    el.appendChild(btn);
  });

  container.querySelectorAll('.markdown pre:not([data-copy-btn])').forEach(el => {
    el.setAttribute('data-copy-btn', '1');
    const btn = document.createElement('button');
    btn.className = 'copy-btn';
    btn.innerHTML = COPY_SVG;
    btn.title = 'Copy code';
    btn.setAttribute('aria-label', 'Copy code');
    btn.onclick = (e) => {
      e.stopPropagation();
      const code = el.querySelector('code');
      copyToClipboard((code || el).textContent.trim(), btn);
    };
    el.appendChild(btn);
  });
}

function copyToClipboard(text, btn) {
  navigator.clipboard.writeText(text).then(() => {
    btn.innerHTML = CHECK_SVG;
    btn.classList.add('copied');
    setTimeout(() => {
      btn.innerHTML = COPY_SVG;
      btn.classList.remove('copied');
    }, 1500);
  });
}

// ── Image lightbox ──

document.addEventListener('click', (e) => {
  if (e.target.matches('.msg-image img')) {
    const overlay = document.createElement('div');
    overlay.className = 'lightbox-overlay';
    const img = document.createElement('img');
    img.src = e.target.src;
    img.alt = e.target.alt;
    overlay.appendChild(img);
    overlay.addEventListener('click', () => overlay.remove());
    document.body.appendChild(overlay);
  }
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    const overlay = document.querySelector('.lightbox-overlay');
    if (overlay) overlay.remove();
  }
});
