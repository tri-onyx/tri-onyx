/* Agent Builder — dynamically renders form from gateway schema */

(function() {
  'use strict';

  var schema = JSON.parse(document.getElementById('builder-config').textContent);
  var initial = JSON.parse(document.getElementById('builder-initial').textContent);
  var formState = {};
  var debounceTimer = null;

  // --- Initialization ---

  function init() {
    loadInitialState();
    renderFields();
    renderFrontmatterPreview();
    setupTabs();
    setupSave();
    setupDelete();

    var editor = document.getElementById('system-prompt-editor');
    if (editor) {
      editor.value = initial.system_prompt || '';
      editor.addEventListener('input', function() {
        scheduleFrontmatterUpdate();
      });
      autoResizeEditor(editor);
    }
  }

  function loadInitialState() {
    var fm = initial.frontmatter || {};
    (schema.fields || []).forEach(function(field) {
      var val = fm[field.key];
      if (val !== undefined && val !== null) {
        formState[field.key] = val;
      } else if (field.default !== undefined && field.default !== null) {
        formState[field.key] = field.default;
      } else {
        formState[field.key] = field.type === 'boolean' ? false :
                               (field.type === 'list' || field.type === 'tool_picker' ||
                                field.type === 'agent_list' || field.type === 'multi_enum') ? [] : '';
      }
    });
  }

  // --- Field rendering ---

  function renderFields() {
    var container = document.getElementById('builder-fields');
    if (!container) return;

    var groups = schema.groups || [];
    var fields = schema.fields || [];

    groups.sort(function(a, b) { return a.order - b.order; });

    groups.forEach(function(group) {
      var groupFields = fields
        .filter(function(f) { return f.group === group.key; })
        .sort(function(a, b) { return a.order - b.order; });

      if (groupFields.length === 0) return;

      var section = el('div', 'builder-group');
      var header = el('div', 'builder-group-header');
      header.textContent = group.label;
      header.onclick = function() { section.classList.toggle('collapsed'); };
      section.appendChild(header);

      var body = el('div', 'builder-group-body');
      groupFields.forEach(function(field) {
        body.appendChild(renderField(field));
      });
      section.appendChild(body);
      container.appendChild(section);
    });
  }

  function renderField(field) {
    var wrap = el('div', 'builder-field');

    switch (field.type) {
      case 'string':
      case 'duration':
      case 'cron':
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderTextInput(field));
        break;
      case 'enum':
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderSelect(field));
        break;
      case 'boolean':
        wrap.appendChild(renderCheckbox(field));
        break;
      case 'tool_picker':
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderToolPicker(field));
        break;
      case 'list':
      case 'agent_list':
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderTagInput(field));
        break;
      case 'multi_enum':
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderMultiEnum(field));
        break;
      case 'network':
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderNetworkField(field));
        break;
      case 'yaml':
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderYamlField(field));
        break;
      default:
        wrap.appendChild(renderLabel(field));
        wrap.appendChild(renderTextInput(field));
    }

    return wrap;
  }

  function renderLabel(field) {
    var label = el('label', 'builder-label');
    label.textContent = field.label;
    if (field.required) {
      var req = el('span', 'builder-required');
      req.textContent = ' *';
      label.appendChild(req);
    }
    if (field.hint) {
      label.title = field.hint;
    }
    return label;
  }

  function renderTextInput(field) {
    var input = el('input', 'builder-input');
    input.type = 'text';
    input.value = formState[field.key] || '';
    input.placeholder = field.hint || '';
    if (field.key === 'name' && initial.mode === 'edit') {
      input.readOnly = true;
      input.classList.add('readonly');
    }
    input.addEventListener('input', function() {
      formState[field.key] = input.value;
      scheduleFrontmatterUpdate();
    });
    return input;
  }

  function renderSelect(field) {
    var select = el('select', 'builder-input');
    (field.options || []).forEach(function(opt) {
      var option = document.createElement('option');
      option.value = opt.value;
      option.textContent = opt.label;
      if (formState[field.key] === opt.value) option.selected = true;
      select.appendChild(option);
    });

    if (field.allow_custom) {
      var currentVal = formState[field.key] || '';
      var hasMatch = (field.options || []).some(function(o) { return o.value === currentVal; });
      if (!hasMatch && currentVal) {
        var custom = document.createElement('option');
        custom.value = currentVal;
        custom.textContent = currentVal;
        custom.selected = true;
        select.appendChild(custom);
      }
      var customOpt = document.createElement('option');
      customOpt.value = '__custom__';
      customOpt.textContent = 'Custom...';
      select.appendChild(customOpt);
    }

    select.addEventListener('change', function() {
      if (select.value === '__custom__') {
        var val = prompt('Enter custom value' + (field.custom_hint ? ' (' + field.custom_hint + ')' : '') + ':');
        if (val) {
          var opt = document.createElement('option');
          opt.value = val;
          opt.textContent = val;
          select.insertBefore(opt, select.lastChild);
          select.value = val;
          formState[field.key] = val;
        } else {
          select.value = formState[field.key] || field.default || '';
        }
      } else {
        formState[field.key] = select.value;
      }
      scheduleFrontmatterUpdate();
    });
    return select;
  }

  function renderCheckbox(field) {
    var row = el('label', 'builder-checkbox-row');
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = !!formState[field.key];
    cb.addEventListener('change', function() {
      formState[field.key] = cb.checked;
      scheduleFrontmatterUpdate();
    });
    row.appendChild(cb);
    var span = document.createElement('span');
    span.textContent = field.label;
    if (field.hint) span.title = field.hint;
    row.appendChild(span);
    return row;
  }

  function renderToolPicker(field) {
    var container = el('div', 'builder-tool-picker');
    var groups = {};
    var toolGroupMap = {};

    (schema.tool_groups || []).forEach(function(tg) {
      if (!toolGroupMap[tg.display]) {
        toolGroupMap[tg.display] = tg.group;
      }
    });

    (schema.known_tools || []).forEach(function(tool) {
      var group = toolGroupMap[tool] || 'Other';
      if (!groups[group]) groups[group] = [];
      groups[group].push(tool);
    });

    var selected = new Set(formState[field.key] || []);

    Object.keys(groups).sort().forEach(function(groupName) {
      var groupEl = el('div', 'builder-tool-group');
      var groupLabel = el('div', 'builder-tool-group-label');
      groupLabel.textContent = groupName;
      groupEl.appendChild(groupLabel);

      var chips = el('div', 'builder-tool-chips');
      groups[groupName].forEach(function(tool) {
        var chip = el('label', 'builder-tool-chip' + (selected.has(tool) ? ' selected' : ''));
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = selected.has(tool);
        cb.style.display = 'none';
        cb.addEventListener('change', function() {
          if (cb.checked) {
            selected.add(tool);
            chip.classList.add('selected');
          } else {
            selected.delete(tool);
            chip.classList.remove('selected');
          }
          formState[field.key] = Array.from(selected);
          scheduleFrontmatterUpdate();
        });
        chip.appendChild(cb);
        var span = document.createElement('span');
        span.textContent = tool;
        chip.appendChild(span);
        chips.appendChild(chip);
      });
      groupEl.appendChild(chips);
      container.appendChild(groupEl);
    });

    return container;
  }

  function renderTagInput(field) {
    var container = el('div', 'builder-tag-container');
    var tags = el('div', 'builder-tags');
    var input = el('input', 'builder-tag-input');
    input.type = 'text';
    input.placeholder = field.hint || 'Type and press Enter';

    var items = formState[field.key] || [];
    var suggestions = field.type === 'agent_list' ? (schema.known_agents || []) : [];

    function renderTags() {
      tags.innerHTML = '';
      items.forEach(function(item, idx) {
        var tag = el('span', 'builder-tag');
        tag.textContent = item;
        var rm = el('span', 'builder-tag-remove');
        rm.textContent = '×';
        rm.onclick = function() {
          items.splice(idx, 1);
          formState[field.key] = items.slice();
          renderTags();
          scheduleFrontmatterUpdate();
        };
        tag.appendChild(rm);
        tags.appendChild(tag);
      });
    }

    input.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && input.value.trim()) {
        e.preventDefault();
        var val = input.value.trim();
        if (items.indexOf(val) === -1) {
          items.push(val);
          formState[field.key] = items.slice();
          renderTags();
          scheduleFrontmatterUpdate();
        }
        input.value = '';
      }
    });

    if (suggestions.length > 0) {
      var dl = document.createElement('datalist');
      dl.id = 'dl-' + field.key;
      suggestions.forEach(function(s) {
        var opt = document.createElement('option');
        opt.value = s;
        dl.appendChild(opt);
      });
      input.setAttribute('list', dl.id);
      container.appendChild(dl);
    }

    renderTags();
    container.appendChild(tags);
    container.appendChild(input);
    return container;
  }

  function renderMultiEnum(field) {
    var container = el('div', 'builder-multi-enum');
    var selected = new Set(formState[field.key] || []);

    (field.options || []).forEach(function(opt) {
      var chip = el('label', 'builder-tool-chip' + (selected.has(opt.value) ? ' selected' : ''));
      var cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = selected.has(opt.value);
      cb.style.display = 'none';
      cb.addEventListener('change', function() {
        if (cb.checked) {
          selected.add(opt.value);
          chip.classList.add('selected');
        } else {
          selected.delete(opt.value);
          chip.classList.remove('selected');
        }
        formState[field.key] = Array.from(selected);
        scheduleFrontmatterUpdate();
      });
      chip.appendChild(cb);
      var span = document.createElement('span');
      span.textContent = opt.label;
      chip.appendChild(span);
      container.appendChild(chip);
    });

    return container;
  }

  function renderNetworkField(field) {
    var container = el('div', 'builder-network');
    var currentVal = formState[field.key];
    var mode = 'none';
    var hosts = [];

    if (Array.isArray(currentVal)) {
      mode = 'hosts';
      hosts = currentVal;
    } else if (currentVal === 'outbound') {
      mode = 'outbound';
    }

    var select = el('select', 'builder-input');
    [{v: 'none', l: 'Isolated (no network)'}, {v: 'outbound', l: 'Outbound (unrestricted)'}, {v: 'hosts', l: 'Specific hosts...'}].forEach(function(o) {
      var opt = document.createElement('option');
      opt.value = o.v;
      opt.textContent = o.l;
      if (o.v === mode) opt.selected = true;
      select.appendChild(opt);
    });

    var hostsInput = el('textarea', 'builder-input builder-network-hosts');
    hostsInput.placeholder = 'One hostname per line';
    hostsInput.value = hosts.join('\n');
    hostsInput.rows = 3;
    hostsInput.style.display = mode === 'hosts' ? 'block' : 'none';

    function updateState() {
      if (select.value === 'hosts') {
        var lines = hostsInput.value.split('\n').map(function(l) { return l.trim(); }).filter(Boolean);
        formState[field.key] = lines.length > 0 ? lines : 'none';
        hostsInput.style.display = 'block';
      } else {
        formState[field.key] = select.value;
        hostsInput.style.display = 'none';
      }
      scheduleFrontmatterUpdate();
    }

    select.addEventListener('change', updateState);
    hostsInput.addEventListener('input', updateState);

    container.appendChild(select);
    container.appendChild(hostsInput);
    return container;
  }

  function renderYamlField(field) {
    var container = el('div', 'builder-yaml-field');
    var textarea = el('textarea', 'builder-input builder-yaml-input');
    textarea.rows = 6;
    textarea.spellcheck = false;
    textarea.placeholder = field.yaml_example || 'YAML content...';

    var currentVal = formState[field.key];
    if (Array.isArray(currentVal) && currentVal.length > 0) {
      textarea.value = yamlifyComplexList(currentVal);
    } else {
      textarea.value = '';
    }

    textarea.addEventListener('input', function() {
      var text = textarea.value.trim();
      if (!text) {
        formState[field.key] = [];
      } else {
        formState[field.key] = '__yaml__' + text;
      }
      scheduleFrontmatterUpdate();
    });

    container.appendChild(textarea);
    return container;
  }

  // --- Frontmatter preview ---

  function scheduleFrontmatterUpdate() {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(renderFrontmatterPreview, 300);
  }

  function renderFrontmatterPreview() {
    var pre = document.getElementById('frontmatter-preview');
    if (!pre) return;

    var lines = ['---'];
    var fieldOrder = (schema.fields || [])
      .sort(function(a, b) {
        var ga = groupOrder(a.group), gb = groupOrder(b.group);
        return ga !== gb ? ga - gb : a.order - b.order;
      });

    fieldOrder.forEach(function(field) {
      var val = formState[field.key];
      var yamlLines = serializeFieldToYaml(field.key, val, field);
      if (yamlLines.length > 0) {
        lines = lines.concat(yamlLines);
      }
    });

    lines.push('---');
    pre.textContent = lines.join('\n');
  }

  function serializeFieldToYaml(key, val, field) {
    if (val === undefined || val === null || val === '') return [];
    if (val === field.default) return [];
    if (Array.isArray(val) && val.length === 0) return [];
    if (val === false && field.type === 'boolean') return [];

    if (typeof val === 'string' && val.startsWith('__yaml__')) {
      var raw = val.substring(8);
      return [key + ':', ...raw.split('\n').map(function(l) { return '  ' + l; })];
    }

    if (typeof val === 'boolean') return [key + ': ' + val];
    if (typeof val === 'number') return [key + ': ' + val];

    if (Array.isArray(val)) {
      if (val.length === 0) return [];
      if (val.every(function(v) { return typeof v === 'string'; })) {
        var items = val.map(function(v) { return '  - ' + yamlQuoteIfNeeded(v); });
        return [key + ':'].concat(items);
      }
      return [key + ': ' + JSON.stringify(val)];
    }

    if (typeof val === 'string') {
      if (val.indexOf(':') !== -1 || val.indexOf('#') !== -1 || val.indexOf('"') !== -1) {
        return [key + ': "' + val.replace(/"/g, '\\"') + '"'];
      }
      return [key + ': ' + val];
    }

    return [key + ': ' + JSON.stringify(val)];
  }

  function groupOrder(groupKey) {
    var g = (schema.groups || []).find(function(g) { return g.key === groupKey; });
    return g ? g.order : 99;
  }

  function yamlQuoteIfNeeded(str) {
    if (/[: #\[\]{},"'!&%@*]/.test(str) || /^\s|\s$/.test(str)) {
      return '"' + str.replace(/"/g, '\\"') + '"';
    }
    return str;
  }

  function yamlifyComplexList(items) {
    return items.map(function(item) {
      var lines = [];
      var first = true;
      Object.keys(item).forEach(function(key) {
        var val = item[key];
        var prefix = first ? '- ' : '  ';
        first = false;
        if (typeof val === 'object' && !Array.isArray(val) && val !== null) {
          lines.push(prefix + key + ':');
          Object.keys(val).forEach(function(k) {
            lines.push('    ' + k + ': ' + val[k]);
          });
        } else {
          lines.push(prefix + key + ': ' + (typeof val === 'string' && /[:#]/.test(val) ? '"' + val + '"' : val));
        }
      });
      return lines.join('\n');
    }).join('\n');
  }

  // --- Tabs ---

  function setupTabs() {
    var tabs = document.querySelectorAll('.builder-tab');
    tabs.forEach(function(tab) {
      tab.addEventListener('click', function() {
        tabs.forEach(function(t) {
          t.classList.remove('active');
          t.setAttribute('aria-selected', 'false');
        });
        tab.classList.add('active');
        tab.setAttribute('aria-selected', 'true');

        document.querySelectorAll('.builder-tab-content').forEach(function(tc) {
          tc.classList.remove('active');
        });
        var target = document.getElementById('tab-' + tab.dataset.tab);
        if (target) target.classList.add('active');
      });
    });
  }

  // --- Save ---

  function setupSave() {
    var btn = document.getElementById('builder-save-btn');
    if (!btn) return;

    btn.addEventListener('click', function() {
      btn.disabled = true;
      btn.textContent = 'Saving...';

      var payload = {};
      Object.keys(formState).forEach(function(key) {
        var val = formState[key];
        if (typeof val === 'string' && val.startsWith('__yaml__')) {
          payload[key] = parseYamlish(val.substring(8));
        } else {
          payload[key] = val;
        }
      });

      var editor = document.getElementById('system-prompt-editor');
      payload.system_prompt = editor ? editor.value : '';
      payload._mode = initial.mode;

      fetch(builderSaveUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRFToken': getCSRF(),
        },
        body: JSON.stringify(payload),
      }).then(function(resp) {
        var redirect = resp.headers.get('HX-Redirect');
        if (resp.ok && redirect) {
          window.location.href = redirect;
          return;
        }
        return resp.text();
      }).then(function(html) {
        if (html) {
          var errEl = document.getElementById('builder-errors');
          if (errEl) errEl.innerHTML = html;
        }
        btn.disabled = false;
        btn.textContent = 'Save';
      }).catch(function() {
        btn.disabled = false;
        btn.textContent = 'Save';
      });
    });
  }

  // --- Delete ---

  function setupDelete() {
    var btn = document.getElementById('builder-delete-btn');
    if (!btn || !builderDeleteUrl) return;

    btn.addEventListener('click', function() {
      if (!confirm('Delete agent "' + builderAgentName + '"? This cannot be undone.')) return;

      fetch(builderDeleteUrl, {
        method: 'POST',
        headers: {
          'X-CSRFToken': getCSRF(),
        },
      }).then(function(resp) {
        var redirect = resp.headers.get('HX-Redirect');
        if (resp.ok && redirect) {
          window.location.href = redirect;
          return;
        }
        return resp.text();
      }).then(function(html) {
        if (html) {
          var errEl = document.getElementById('builder-errors');
          if (errEl) errEl.innerHTML = html;
        }
      });
    });
  }

  // --- Helpers ---

  function el(tag, cls) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    return e;
  }

  function getCSRF() {
    var meta = document.querySelector('[name=csrfmiddlewaretoken]');
    if (meta) return meta.value;
    var cookie = document.cookie.split(';').find(function(c) { return c.trim().startsWith('csrftoken='); });
    return cookie ? cookie.split('=')[1] : '';
  }

  function autoResizeEditor(textarea) {
    function resize() {
      textarea.style.height = 'auto';
      textarea.style.height = Math.max(200, textarea.scrollHeight) + 'px';
    }
    textarea.addEventListener('input', resize);
    setTimeout(resize, 50);
  }

  function parseYamlish(text) {
    var lines = text.split('\n');
    var result = [];
    var current = null;

    lines.forEach(function(line) {
      if (line.match(/^- /)) {
        if (current) result.push(current);
        current = {};
        var rest = line.substring(2).trim();
        parseKV(current, rest);
      } else if (line.match(/^\s+/) && current) {
        var rest = line.trim();
        parseKV(current, rest);
      }
    });
    if (current) result.push(current);
    return result.length > 0 ? result : [];
  }

  function parseKV(obj, str) {
    var match = str.match(/^(\w+):\s*(.*)$/);
    if (!match) return;
    var key = match[1];
    var val = match[2].trim();
    if (val === '') return;
    if (val === 'true') val = true;
    else if (val === 'false') val = false;
    else if (/^\d+$/.test(val)) val = parseInt(val, 10);
    else if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
    obj[key] = val;
  }

  // --- Overview toggle ---
  window.toggleBuilderOverview = function() {
    var panel = document.querySelector('.builder-overview');
    if (panel) panel.classList.toggle('collapsed');
  };

  // --- Init ---
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
