// ── State ──
let agents = [];
let analysisData = null;
// Gateway-owned risk model (level ordering, 2D matrix, capability adjustment),
// delivered by /graph/data from GET /agents/schema. The frontend must NOT
// hardcode any of this — see AGENTS.md "Source of Truth". Empty until loaded;
// the derivation helpers below degrade gracefully in that case.
let riskModel = {};
let graphData = { nodes: [], links: [] };
let simulation = null;
const fadedNodes = new Set();

const POSITIONS_KEY = 'trionyx-graph-positions';

function savePositions() {
  const positions = {};
  for (const n of graphData.nodes) {
    if (n.x != null && n.y != null) {
      positions[n.id] = { x: n.x, y: n.y };
    }
  }
  try { localStorage.setItem(POSITIONS_KEY, JSON.stringify(positions)); } catch {}
}

function loadPositions() {
  try { return JSON.parse(localStorage.getItem(POSITIONS_KEY)) || {}; } catch { return {}; }
}

function getAnalysisMode() {
  const checked = document.querySelector('input[name="analysis-mode"]:checked');
  return checked ? checked.value : 'none';
}

// ── Data loading ──

async function loadGraph() {
  try {
    const resp = await fetch('/graph/data');
    const data = await resp.json();
    agents = data.agents || [];
    analysisData = data.analysis || null;
    riskModel = data.risk_model || {};

    document.getElementById('status-text').className = 'connected';
    document.getElementById('status-text').textContent = 'Connected to gateway';
  } catch (err) {
    document.getElementById('status-text').className = 'disconnected';
    document.getElementById('status-text').textContent = 'Gateway unreachable: ' + err.message;
    agents = [];
    analysisData = null;
  }

  buildGraph();
  renderGraph();
  updateMatrix();
}

// ── Graph construction ──

function buildGraph() {
  const agentAnalysis = {};
  if (analysisData && analysisData.agents) {
    for (const [name, data] of Object.entries(analysisData.agents)) {
      agentAnalysis[name] = data;
    }
  }

  const bibaViolations = new Set();
  if (analysisData && analysisData.biba_violations) {
    for (const v of analysisData.biba_violations) {
      bibaViolations.add(`${v.writer}|${v.reader}`);
    }
  }

  const blpViolations = new Set();
  if (analysisData && analysisData.blp_violations) {
    for (const v of analysisData.blp_violations) {
      blpViolations.add(`${v.writer}|${v.reader}`);
    }
  }

  const nodes = agents.map(a => {
    const aa = agentAnalysis[a.name] || {};
    const taint = normalizeLevel(a.taint_level || a.information_level || 'low');
    const sensitivity = normalizeLevel(a.sensitivity_level || 'low');
    const capability = normalizeLevel(aa.capability_level || 'low');
    return {
      id: a.name,
      agent: a,
      taintLevel: taint,
      sensitivityLevel: sensitivity,
      capabilityLevel: capability,
      effectiveRisk: normalizeRisk(aa.effective_risk || 'low'),
      active: a.status && a.status !== 'inactive',
      network: a.network || 'none',
      tools: a.tools || [],
      maxInputTaint: aa.max_input_taint || null,
      maxInputSensitivity: aa.max_input_sensitivity || null,
      maxInputRisk: aa.max_input_risk || null,
      riskChain: aa.risk_chain || [],
      taintSourcesUnified: aa.taint_sources || [],
      sensitivitySourcesUnified: aa.sensitivity_sources || [],
      capabilityDrivers: aa.capability_drivers || [],
      worstCaseTaint: normalizeLevel(aa.worst_case_taint),
      worstCaseSensitivity: normalizeLevel(aa.worst_case_sensitivity),
      propagatedTaint: aa.propagated_taint ? normalizeLevel(aa.propagated_taint) : null,
      propagatedSensitivity: aa.propagated_sensitivity ? normalizeLevel(aa.propagated_sensitivity) : null,
    };
  });

  const nodeMap = Object.fromEntries(nodes.map(n => [n.id, n]));

  const links = [];
  const serverEdges = (analysisData && analysisData.edges) || [];
  for (const edge of serverEdges) {
    if (!nodeMap[edge.from] || !nodeMap[edge.to]) continue;
    const edgeType = edge.edge_type || 'filesystem';
    const type = edgeType === 'filesystem' ? 'write_read' : edgeType;
    const sourceNode = nodeMap[edge.from];

    links.push({
      source: edge.from,
      target: edge.to,
      type: type,
      paths: edge.paths || [],
      taintLevel: type === 'bcp' ? 'low' : (sourceNode ? sourceNode.taintLevel : 'low'),
      sensitivityLevel: type === 'bcp' ? 'low' : (sourceNode ? sourceNode.sensitivityLevel : 'low'),
      bibaViolation: edge.biba_violation || false,
      blpViolation: edge.blp_violation || false,
      maxCategory: edge.max_category,
      rates: edge.rates,
    });
  }

  graphData = { nodes, links, bibaViolations, blpViolations };

  for (const node of nodes) {
    const aa = agentAnalysis[node.id] || {};
    node.effTaintLevel = normalizeLevel(aa.propagated_taint) || node.taintLevel;
    node.effSensitivityLevel = normalizeLevel(aa.propagated_sensitivity) || node.sensitivityLevel;
    node.taintSources = aa.taint_sources || [];
    node.sensitivitySources = aa.sensitivity_sources || [];
  }
  document.getElementById('agent-count').textContent = `${nodes.length} agents`;
  document.getElementById('edge-count').textContent = `${links.length} edges`;
  updateViolationCount();
}

// ── Risk model derivation (from gateway `riskModel`, never hardcoded) ──

// Fallback level ordering used only before the gateway data has loaded, so a
// tooltip shown mid-fetch doesn't throw. The authoritative ordering is
// `riskModel.levels`.
const FALLBACK_LEVELS = ['low', 'medium', 'high'];

// taint/sensitivity level → rank index, derived from the gateway's ordering.
function levelRank() {
  const levels = (riskModel.levels && riskModel.levels.length)
    ? riskModel.levels : FALLBACK_LEVELS;
  const rank = {};
  levels.forEach((l, i) => { rank[l] = i; });
  return rank;
}

// 2D baseline grid indexed [taintRank][sensRank], built from the gateway's
// risk_matrix list of {taint, sensitivity, risk}. Empty until the model loads.
function riskMatrix2D() {
  const rank = levelRank();
  const grid = [];
  for (const cell of (riskModel.risk_matrix || [])) {
    const ti = rank[cell.taint];
    const si = rank[cell.sensitivity];
    if (ti == null || si == null) continue;
    if (!grid[ti]) grid[ti] = [];
    grid[ti][si] = cell.risk;
  }
  return grid;
}

// ── Presentation-only maps (not risk-model data) ──

// Human label for what a capability level does to the baseline. Purely
// descriptive; the actual adjusted level comes from riskModel.capability_adjustment.
const CAP_MOD_LABEL = { low: 'step down', medium: 'no change', high: 'step up' };

const levelColor = { low: '#3fb950', medium: '#db6d28', high: '#f85149' };
const riskColor = { low: '#3fb950', moderate: '#db6d28', high: '#f85149', critical: '#f85149' };
const riskRadius = { low: 14, moderate: 20, high: 26, critical: 32 };

// ── Helpers ──

function normalizeLevel(l) {
  if (!l) return 'low';
  const s = String(l).toLowerCase();
  if (s === 'high') return 'high';
  if (s === 'medium') return 'medium';
  return 'low';
}

function normalizeRisk(r) {
  if (!r) return 'low';
  const s = String(r).toLowerCase().replace(/[^a-z]/g, '');
  if (s.startsWith('critical')) return 'critical';
  if (s.startsWith('high')) return 'high';
  if (s.startsWith('moderate') || s.startsWith('medium')) return 'moderate';
  return 'low';
}

function nodeRadius(d) { return riskRadius[d.effectiveRisk] || 14; }

function riskIcon(level) {
  const icons = { low: '●', moderate: '◆', high: '▲', critical: '⬟' };
  return icons[level] || '●';
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function truncate(s, n) {
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

function formatNetwork(n) {
  if (!n || n === 'none') return '<span style="color:var(--green)">isolated</span>';
  if (n === 'outbound') return '<span style="color:var(--purple)">outbound (unrestricted)</span>';
  if (Array.isArray(n)) return n.join(', ');
  return String(n);
}

// ── Rating breakdown ──

function buildRatingBreakdown(d) {
  const hasNetwork = d.network && d.network !== 'none' && !(Array.isArray(d.network) && d.network.length === 0);
  const allTaintSources = d.taintSourcesUnified || [];
  const allSensSources = d.sensitivitySourcesUnified || [];
  const taintToolSources = allTaintSources.filter(x => x.kind === 'tool');
  const taintInputSources = allTaintSources.filter(x => x.kind === 'input');
  const sensToolSources = allSensSources.filter(x => x.kind === 'tool');
  const sensInputSources = allSensSources.filter(x => x.kind === 'input');
  const capDrivers = (d.capabilityDrivers || []).map(x => ({ tool: x.tool, level: x.level }));

  const rank = levelRank();
  const grid = riskMatrix2D();
  const capAdjust = riskModel.capability_adjustment || {};

  const effT = d.effTaintLevel || d.taintLevel;
  const effS = d.effSensitivityLevel || d.sensitivityLevel;
  const tI = rank[effT] || 0;
  const sI = rank[effS] || 0;
  // Baseline from the gateway's 2D matrix; fall back to the gateway-computed
  // effective risk if the model hasn't loaded so the tooltip never breaks.
  const baseline = (grid[tI] && grid[tI][sI]) || d.effectiveRisk;

  // Capability adjustment comes straight from the gateway table. `capMod` is
  // just the descriptive label for the capability level.
  const capMod = CAP_MOD_LABEL[d.capabilityLevel] || 'no change';
  const adjusted = capAdjust[d.capabilityLevel];
  const finalRisk = (adjusted && adjusted[baseline]) || d.effectiveRisk;

  const liveTaintElevated = (rank[d.taintLevel] || 0) > (rank[d.worstCaseTaint || 'low'] || 0);
  const liveSensElevated = (rank[d.sensitivityLevel] || 0) > (rank[d.worstCaseSensitivity || 'low'] || 0);

  return {
    taintToolSources, taintInputSources, sensToolSources, sensInputSources,
    capDrivers, hasNetwork, baseline, capMod, finalRisk,
    effT, effS, liveTaintElevated, liveSensElevated,
  };
}

function renderDriverBadges(drivers) {
  if (!drivers.length) return '<span style="color:var(--muted);font-size:10px;">all tools low</span>';
  return drivers.map(d =>
    `<span class="driver-badge ${d.level}">${d.tool || d.source}</span>`
  ).join('');
}

function renderSourceBadgesUnified(sources) {
  if (!sources.length) return '<span style="color:var(--muted);font-size:10px;">none above low</span>';
  return sources.map(d => {
    const edgeNote = d.edge_type ? ` <span style="color:var(--muted);font-size:8px;">[${d.edge_type}]</span>` : '';
    return `<span class="driver-badge ${d.level}">${d.source}${edgeNote}</span>`;
  }).join('');
}

// ── Edge styling ──

function edgeColor(link) {
  const mode = getAnalysisMode();
  if (mode === 'biba' && link.bibaViolation) return '#f85149';
  if (mode === 'blp' && link.blpViolation) return '#f85149';
  if (link.type === 'messaging') return '#58a6ff';
  if (link.type === 'bcp') return '#bc8cff';

  let level;
  if (mode === 'biba') {
    level = link.taintLevel;
  } else if (mode === 'blp') {
    level = link.sensitivityLevel;
  } else {
    const rank = levelRank();
    level = (rank[link.sensitivityLevel] || 0) >= (rank[link.taintLevel] || 0)
      ? link.sensitivityLevel : link.taintLevel;
  }
  if (level === 'high') return '#f85149';
  if (level === 'medium') return '#db6d28';
  return '#3fb950';
}

function edgeOpacity(link) {
  const mode = getAnalysisMode();
  if (mode === 'biba') return link.bibaViolation ? 0.9 : 0.25;
  if (mode === 'blp') return link.blpViolation ? 0.9 : 0.25;
  return 0.6;
}

function edgeMarker(d) {
  if (d.type === 'bcp') return 'url(#arrow-bcp)';
  if (d.type !== 'write_read') return null;
  const mode = getAnalysisMode();
  if (mode === 'biba' && d.bibaViolation) return 'url(#arrow-violation)';
  if (mode === 'blp' && d.blpViolation) return 'url(#arrow-violation)';
  return 'url(#arrow-compliant)';
}

function edgeWidth(d) {
  const mode = getAnalysisMode();
  if (mode === 'biba' && d.bibaViolation) return 3;
  if (mode === 'blp' && d.blpViolation) return 3;
  return 2;
}

function edgeLabelText(d) {
  const mode = getAnalysisMode();
  if (mode === 'biba' && d.bibaViolation) return 'BIBA';
  if (mode === 'blp' && d.blpViolation) return 'BLP';
  if (d.type === 'bcp') return `BCP-${d.maxCategory || '?'}`;
  if (mode === 'biba') return d.taintLevel || '';
  if (mode === 'blp') return d.sensitivityLevel || '';
  return `T:${(d.taintLevel || 'low')[0]} S:${(d.sensitivityLevel || 'low')[0]}`;
}

function edgeLabelColor(d) {
  const mode = getAnalysisMode();
  if (mode === 'biba' && d.bibaViolation) return '#f85149';
  if (mode === 'blp' && d.blpViolation) return '#f85149';
  return 'var(--muted)';
}

function edgeLabelWeight(d) {
  const mode = getAnalysisMode();
  if ((mode === 'biba' && d.bibaViolation) || (mode === 'blp' && d.blpViolation)) return '700';
  return '400';
}

// ── Curve offsets for parallel edges ──

function assignCurveOffsets(links) {
  const pairCounts = {};
  const pairIndex = {};
  for (const link of links) {
    const srcId = typeof link.source === 'object' ? link.source.id : link.source;
    const tgtId = typeof link.target === 'object' ? link.target.id : link.target;
    const key = srcId < tgtId ? `${srcId}|${tgtId}` : `${tgtId}|${srcId}`;
    pairCounts[key] = (pairCounts[key] || 0) + 1;
    link._pairKey = key;
  }
  for (const link of links) {
    const count = pairCounts[link._pairKey];
    if (count <= 1) {
      link.curveOffset = 0;
    } else {
      const idx = pairIndex[link._pairKey] || 0;
      pairIndex[link._pairKey] = idx + 1;
      link.curveOffset = (idx - (count - 1) / 2) * 40;
    }
  }
}

function linkPath(d) {
  const sx = d.source.x, sy = d.source.y;
  const tx = d.target.x, ty = d.target.y;
  const tr = nodeRadius(d.target) + 2;
  const dx = tx - sx, dy = ty - sy;
  const len = Math.sqrt(dx * dx + dy * dy) || 1;
  const ux = dx / len, uy = dy / len;
  const x1 = sx, y1 = sy;
  const x2 = tx - ux * tr, y2 = ty - uy * tr;
  if (!d.curveOffset) {
    return `M${x1},${y1}L${x2},${y2}`;
  }
  const nx = -dy / len, ny = dx / len;
  const cx = (sx + tx) / 2 + nx * d.curveOffset;
  const cy = (sy + ty) / 2 + ny * d.curveOffset;
  return `M${x1},${y1}Q${cx},${cy} ${x2},${y2}`;
}

function linkMidpoint(d) {
  const sx = d.source.x, sy = d.source.y;
  const tx = d.target.x, ty = d.target.y;
  if (!d.curveOffset) {
    return { x: (sx + tx) / 2, y: (sy + ty) / 2 };
  }
  const dx = tx - sx, dy = ty - sy;
  const len = Math.sqrt(dx * dx + dy * dy) || 1;
  const nx = -dy / len, ny = dx / len;
  const cx = (sx + tx) / 2 + nx * d.curveOffset;
  const cy = (sy + ty) / 2 + ny * d.curveOffset;
  return {
    x: 0.25 * sx + 0.5 * cx + 0.25 * tx,
    y: 0.25 * sy + 0.5 * cy + 0.25 * ty
  };
}

// ── Fade/toggle ──

function toggleFadeNode(id) {
  if (fadedNodes.has(id)) fadedNodes.delete(id);
  else fadedNodes.add(id);
  applyFade();
}

function applyFade() {
  if (!window._graphRefs) return;
  const { node, link, linkHitArea, edgeLabels } = window._graphRefs;

  node.classed('faded', d => fadedNodes.has(d.id));

  const isEdgeFaded = d => {
    const src = typeof d.source === 'object' ? d.source.id : d.source;
    const tgt = typeof d.target === 'object' ? d.target.id : d.target;
    return fadedNodes.has(src) || fadedNodes.has(tgt);
  };

  applyToggles();

  link.each(function(d) {
    if (isEdgeFaded(d)) d3.select(this).attr('visibility', 'hidden');
  });
  linkHitArea.each(function(d) {
    if (isEdgeFaded(d)) d3.select(this).attr('visibility', 'hidden');
  });
  edgeLabels.each(function(d) {
    if (isEdgeFaded(d)) d3.select(this).attr('visibility', 'hidden');
  });
}

function applyToggles() {
  const showFs = document.getElementById('toggle-fs').checked;
  const showMsg = document.getElementById('toggle-msg').checked;
  const showBcp = document.getElementById('toggle-bcp').checked;
  const showLabels = document.getElementById('toggle-labels').checked;
  const showMatrix = document.getElementById('toggle-matrix').checked;

  d3.selectAll('.edge-write_read, .edge-hit-write_read').attr('visibility', showFs ? 'visible' : 'hidden');
  d3.selectAll('.edge-messaging, .edge-hit-messaging').attr('visibility', showMsg ? 'visible' : 'hidden');
  d3.selectAll('.edge-bcp, .edge-hit-bcp').attr('visibility', showBcp ? 'visible' : 'hidden');

  d3.selectAll('.edge-label').attr('visibility', (showFs || showMsg || showBcp) ? 'visible' : 'hidden');
  d3.selectAll('.node-label').attr('visibility', showLabels ? 'visible' : 'hidden');

  document.getElementById('matrix-panel').classList.toggle('visible', showMatrix);

  if (window._graphRefs) {
    const { link, edgeLabels } = window._graphRefs;
    link
      .attr('stroke', d => edgeColor(d))
      .attr('stroke-opacity', d => edgeOpacity(d))
      .attr('stroke-width', d => edgeWidth(d))
      .attr('marker-end', d => edgeMarker(d));

    edgeLabels
      .text(d => edgeLabelText(d))
      .attr('fill', d => edgeLabelColor(d))
      .attr('font-weight', d => edgeLabelWeight(d));
  }
}

// ── D3 rendering ──

function renderGraph() {
  const container = document.getElementById('graph-container');
  const width = container.clientWidth;
  const height = container.clientHeight;

  const svg = d3.select('#graph-svg');
  svg.selectAll('*').remove();

  const defs = svg.append('defs');
  ['compliant', 'warning', 'violation', 'bcp'].forEach((cls, i) => {
    const colors = ['#3fb950', '#d29922', '#f85149', '#bc8cff'];
    defs.append('marker')
      .attr('id', `arrow-${cls}`)
      .attr('viewBox', '0 -5 10 10')
      .attr('refX', 28).attr('refY', 0)
      .attr('markerWidth', 6).attr('markerHeight', 6)
      .attr('orient', 'auto')
      .append('path')
      .attr('d', 'M0,-5L10,0L0,5')
      .attr('fill', colors[i]);
  });

  const g = svg.append('g');

  const zoom = d3.zoom()
    .scaleExtent([0.2, 4])
    .on('zoom', (e) => g.attr('transform', e.transform));
  svg.call(zoom);

  const tooltip = document.getElementById('tooltip');

  assignCurveOffsets(graphData.links);

  const linkGroup = g.append('g').attr('class', 'links');

  const linkHitArea = linkGroup.selectAll('path.edge-hit')
    .data(graphData.links)
    .join('path')
    .attr('class', d => `edge-hit edge-hit-${d.type}`)
    .attr('fill', 'none')
    .attr('stroke', 'transparent')
    .attr('stroke-width', 16)
    .style('pointer-events', 'stroke')
    .style('cursor', 'pointer')
    .on('mouseenter', (event, d) => {
      const src = typeof d.source === 'object' ? d.source.id : d.source;
      const tgt = typeof d.target === 'object' ? d.target.id : d.target;

      if (d.type === 'bcp') {
        tooltip.innerHTML = `
          <h3>${src} → ${tgt} (BCP)</h3>
          <div class="row"><span class="label">Channel:</span><span>Bandwidth-Constrained Protocol</span></div>
          <div class="row"><span class="label">Max category:</span><span class="badge low">Cat-${d.maxCategory || '?'}</span></div>
          <div class="row"><span class="label">Rates:</span><span>${d.rates ? Object.entries(d.rates).map(([k, v]) => `${k}: ${v === 0 ? 'denied' : v}`).join(', ') : '?'}</span></div>
          <div class="row"><span class="label">Taint effect:</span><span class="badge low">none (taint-neutral)</span></div>
          <div style="margin-top:6px;color:var(--muted);font-size:10px;">
            Gateway validates all responses. Cat-1: structured primitives. Cat-2: constrained Q&A. Cat-3: free-text (requires approval).
          </div>
        `;
      } else {
        const direction = d.type === 'write_read' ? `${src} writes → ${tgt} reads`
          : d.type === 'messaging' ? `${src} → ${tgt} (messaging)`
          : `${src} ↔ ${tgt}`;
        const pathList = d.paths.map(p => escapeHtml(p)).join('<br>');
        tooltip.innerHTML = `
          <h3>${direction}</h3>
          <div class="row"><span class="label">Taint carried:</span><span class="badge ${d.taintLevel}">${d.taintLevel}</span></div>
          <div class="row"><span class="label">Sensitivity carried:</span><span class="badge ${d.sensitivityLevel}">${d.sensitivityLevel}</span></div>
          <div style="margin-top:6px;color:var(--muted);font-size:10px;">Overlapping paths:</div>
          <div class="paths" style="margin-top:2px;">${pathList}</div>
        `;
      }
      tooltip.classList.add('visible');
    })
    .on('mousemove', (event) => {
      const rect = container.getBoundingClientRect();
      let x = event.clientX - rect.left + 16;
      let y = event.clientY - rect.top + 16;
      if (x + 390 > rect.width) x = event.clientX - rect.left - 396;
      if (y + 200 > rect.height) y = event.clientY - rect.top - 200;
      tooltip.style.left = x + 'px';
      tooltip.style.top = y + 'px';
    })
    .on('mouseleave', () => {
      tooltip.classList.remove('visible');
    });

  const link = linkGroup.selectAll('path.edge-visible')
    .data(graphData.links)
    .join('path')
    .attr('class', d => `edge-visible edge-${d.type}`)
    .attr('fill', 'none')
    .attr('stroke', d => edgeColor(d))
    .attr('stroke-opacity', d => edgeOpacity(d))
    .attr('stroke-width', d => edgeWidth(d))
    .attr('stroke-dasharray', d => d.type === 'messaging' ? '6,4' : d.type === 'bcp' ? '3,3' : null)
    .attr('marker-end', d => edgeMarker(d))
    .style('pointer-events', 'none');

  const edgeLabelGroup = g.append('g').attr('class', 'edge-labels');
  const edgeLabels = edgeLabelGroup.selectAll('text')
    .data(graphData.links.filter(d => d.type === 'write_read' || d.type === 'bcp'))
    .join('text')
    .attr('class', 'edge-label')
    .text(d => edgeLabelText(d))
    .attr('fill', d => edgeLabelColor(d))
    .attr('font-weight', d => edgeLabelWeight(d));

  const nodeGroup = g.append('g').attr('class', 'nodes');
  const node = nodeGroup.selectAll('g')
    .data(graphData.nodes)
    .join('g')
    .attr('class', 'node')
    .call(d3.drag()
      .on('start', dragStart)
      .on('drag', dragging)
      .on('end', dragEnd));

  // Yin-yang node rendering
  node.each(function(d) {
    const r = nodeRadius(d);
    const hr = r / 2;
    const el = d3.select(this);
    const leftColor = levelColor[d.effTaintLevel || d.taintLevel] || '#3fb950';
    const rightColor = levelColor[d.effSensitivityLevel || d.sensitivityLevel] || '#3fb950';
    const clipId = `clip-${d.id.replace(/[^a-zA-Z0-9]/g, '-')}`;

    el.append('clipPath').attr('id', clipId)
      .append('circle').attr('r', r);
    const clipped = el.append('g').attr('clip-path', `url(#${clipId})`);

    clipped.append('circle').attr('r', r).attr('fill', leftColor);
    clipped.append('path')
      .attr('d', `M 0,${-r} L 0,${r} A ${r},${r} 0 0,0 0,${-r} Z`)
      .attr('fill', rightColor);
    clipped.append('circle').attr('cy', -hr).attr('r', hr).attr('fill', leftColor);
    clipped.append('circle').attr('cy', hr).attr('r', hr).attr('fill', rightColor);
    clipped.append('circle').attr('cy', -hr).attr('r', hr * 0.22).attr('fill', rightColor);
    clipped.append('circle').attr('cy', hr).attr('r', hr * 0.22).attr('fill', leftColor);
    clipped.append('path')
      .attr('d', [
        `M 0,${-r}`,
        `A ${hr},${hr} 0 0,1 0,0`,
        `A ${hr},${hr} 0 0,0 0,${r}`,
      ].join(' '))
      .attr('fill', 'none')
      .attr('stroke', '#0d1117')
      .attr('stroke-width', 2);
    el.append('circle')
      .attr('r', r)
      .attr('fill', 'none')
      .attr('stroke', '#0d1117')
      .attr('stroke-width', 2)
      .style('filter', d.active ? 'drop-shadow(0 0 6px rgba(88,166,255,0.3))' : null);
  });

  const labels = node.append('text')
    .text(d => d.id)
    .attr('dy', d => (nodeRadius(d)) + 14)
    .attr('text-anchor', 'middle')
    .attr('fill', '#e6edf3')
    .attr('font-size', '11px')
    .attr('font-weight', 500)
    .attr('class', 'node-label');

  // Node tooltip
  node.on('mouseenter', (event, d) => {
    const a = d.agent;
    const b = buildRatingBreakdown(d);

    const wcT = d.worstCaseTaint || 'low';
    const wcS = d.worstCaseSensitivity || 'low';
    let taintNote = `static: ${wcT}`;
    if (b.liveTaintElevated) {
      const infoSources = a.information_sources || [];
      taintNote += `; live session: ${d.taintLevel}` + (infoSources.length ? ` via ${infoSources[0]}` : '');
    }
    let sensNote = `static: ${wcS}`;
    if (b.liveSensElevated) {
      sensNote += `; live session: ${d.sensitivityLevel}`;
    }

    const bashNetNote = (b.hasNetwork && d.tools.includes('Bash'))
      ? '<div style="color:var(--orange);font-size:10px;margin-top:2px;">Bash + network access → high taint &amp; capability</div>'
      : '';

    tooltip.innerHTML = `
      <div class="header-row">
        <div class="header-info">
          <h3>${a.name}</h3>
          ${a.description ? `<div style="color:var(--muted);margin-bottom:4px">${escapeHtml(a.description)}</div>` : ''}
          <div class="row"><span class="label">Model:</span><span>${a.model || '?'}</span></div>
          <div class="row"><span class="label">Status:</span><span>${a.status || 'inactive'}</span></div>
          <div class="row"><span class="label">Network:</span><span>${formatNetwork(a.network)}</span></div>
        </div>
        <div class="risk-square ${d.effectiveRisk}">
          <span class="risk-icon">${riskIcon(d.effectiveRisk)}</span>
          ${d.effectiveRisk}
        </div>
      </div>

      <div class="section">
        <div class="section-header"><div class="section-title">☣️ Taint (integrity)</div><span class="badge ${b.effT}">${b.effT}</span></div>
        <div style="font-size:10px;color:var(--muted);margin-bottom:3px;">${taintNote}</div>
        ${b.taintToolSources.length ? `<div class="axis-row"><span class="axis-label">Tools</span><div class="driver-list">${renderSourceBadgesUnified(b.taintToolSources)}</div></div>` : ''}
        ${b.taintInputSources.length ? `<div class="axis-row"><span class="axis-label">Inputs</span><div class="driver-list">${renderSourceBadgesUnified(b.taintInputSources)}</div></div>` : ''}
        ${!b.taintToolSources.length && !b.taintInputSources.length ? '<div class="axis-row"><span class="axis-label">Sources</span><span style="color:var(--muted);font-size:10px;">none above low</span></div>' : ''}
        ${bashNetNote}
      </div>

      <div class="section">
        <div class="section-header"><div class="section-title">🔒 Sensitivity (confidentiality)</div><span class="badge ${b.effS}">${b.effS}</span></div>
        <div style="font-size:10px;color:var(--muted);margin-bottom:3px;">${sensNote}</div>
        ${b.sensToolSources.length ? `<div class="axis-row"><span class="axis-label">Tools</span><div class="driver-list">${renderSourceBadgesUnified(b.sensToolSources)}</div></div>` : ''}
        ${b.sensInputSources.length ? `<div class="axis-row"><span class="axis-label">Inputs</span><div class="driver-list">${renderSourceBadgesUnified(b.sensInputSources)}</div></div>` : ''}
        ${!b.sensToolSources.length && !b.sensInputSources.length ? '<div class="axis-row"><span class="axis-label">Sources</span><span style="color:var(--muted);font-size:10px;">none above low</span></div>' : ''}
      </div>

      <div class="section">
        <div class="section-header"><div class="section-title">🦾 Capability (blast radius)</div><span class="badge ${d.capabilityLevel}">${d.capabilityLevel}</span></div>
        ${b.capDrivers.length ? `<div class="axis-row"><span class="axis-label">Tools</span><div class="driver-list">${renderDriverBadges(b.capDrivers)}</div></div>` : ''}
        ${b.hasNetwork ? `<div class="axis-row"><span class="axis-label">Network</span><span style="color:var(--orange);font-size:10px;">${formatNetwork(d.network)}</span></div>` : ''}
        ${!b.capDrivers.length && !b.hasNetwork ? '<div class="axis-row"><span class="axis-label">Tools</span><span style="color:var(--muted);font-size:10px;">all tools low</span></div>' : ''}
      </div>

      <div class="section">
        <div class="section-header"><div class="section-title">Effective Risk</div><span class="badge ${d.effectiveRisk}">${d.effectiveRisk}</span></div>
        <div class="derivation">Baseline: ☣️ <span class="badge ${b.effT}">${b.effT}</span> × 🔒 <span class="badge ${b.effS}">${b.effS}</span> = <span class="badge ${b.baseline}">${b.baseline}</span></div>
        <div class="derivation">Adjusted: 🦾 <span class="badge ${d.capabilityLevel}">${d.capabilityLevel}</span> capability → ${b.capMod}</div>
        <div class="derivation">Final: <span class="badge ${d.effectiveRisk}" style="font-size:11px;">${d.effectiveRisk}</span></div>
      </div>
    `;
    tooltip.classList.add('visible');
  })
  .on('mousemove', (event) => {
    const rect = container.getBoundingClientRect();
    let x = event.clientX - rect.left + 16;
    let y = event.clientY - rect.top + 16;
    if (x + 390 > rect.width) x = event.clientX - rect.left - 396;
    if (y + 200 > rect.height) y = event.clientY - rect.top - 200;
    tooltip.style.left = x + 'px';
    tooltip.style.top = y + 'px';
  })
  .on('mouseleave', () => {
    tooltip.classList.remove('visible');
  })
  .on('contextmenu', (event, d) => {
    event.preventDefault();
    tooltip.classList.remove('visible');
    toggleFadeNode(d.id);
  })
  .on('click', (event, d) => {
    window.location.href = `/agents/${d.id}/`;
  });

  // Simulation
  simulation = d3.forceSimulation(graphData.nodes)
    .force('link', d3.forceLink(graphData.links).id(d => d.id).distance(280).strength(0.3))
    .force('charge', d3.forceManyBody().strength(-1200).distanceMax(800))
    .force('center', d3.forceCenter(width / 2, height / 2))
    .force('collision', d3.forceCollide().radius(d => (nodeRadius(d)) + 50).iterations(3))
    .alphaDecay(0.015)
    .on('tick', () => {
      linkHitArea.attr('d', d => linkPath(d));
      link.attr('d', d => linkPath(d));
      node.attr('transform', d => `translate(${d.x},${d.y})`);
      edgeLabels.each(function(d) {
        const mid = linkMidpoint(d);
        const sx = d.source.x, sy = d.source.y, tx = d.target.x, ty = d.target.y;
        const dx = tx - sx, dy = ty - sy;
        const len = Math.sqrt(dx * dx + dy * dy) || 1;
        const nx = -dy / len, ny = dx / len;
        const maxR = Math.max(nodeRadius(d.source), nodeRadius(d.target));
        const offset = maxR * 0.6 + 6;
        const sign = d.curveOffset ? Math.sign(d.curveOffset) : -1;
        d3.select(this)
          .attr('x', mid.x + nx * offset * sign)
          .attr('y', mid.y + ny * offset * sign);
      });
    });

  // Restore saved positions
  const saved = loadPositions();
  for (const n of graphData.nodes) {
    if (saved[n.id]) {
      n.x = n.fx = saved[n.id].x;
      n.y = n.fy = saved[n.id].y;
    }
  }

  simulation.stop();
  for (let i = 0; i < 200; i++) simulation.tick();
  simulation.restart();

  simulation.on('end', savePositions);

  window._graphRefs = { link, linkHitArea, edgeLabels, node, labels, svg, g, zoom };
  applyFade();
}

// ── Drag handlers ──

function dragStart(event, d) {
  if (!event.active) simulation.alphaTarget(0.3).restart();
  d.fx = d.x; d.fy = d.y;
}

function dragging(event, d) { d.fx = event.x; d.fy = event.y; }

function dragEnd(event, d) {
  if (!event.active) simulation.alphaTarget(0);
  d.fx = d.x; d.fy = d.y;
  savePositions();
}

function resetLayout() {
  try { localStorage.removeItem(POSITIONS_KEY); } catch {}
  if (simulation) {
    graphData.nodes.forEach(n => { n.fx = null; n.fy = null; });
    simulation.alpha(1).restart();
  }
  if (window._graphRefs) {
    window._graphRefs.svg.transition().duration(500)
      .call(window._graphRefs.zoom.transform, d3.zoomIdentity);
  }
}

// ── Matrix panel ──

function updateViolationCount() {
  const mode = getAnalysisMode();
  const vEl = document.getElementById('violation-count');
  if (mode === 'none' || !graphData.bibaViolations) {
    vEl.textContent = '';
    return;
  }
  const vCount = mode === 'biba' ? graphData.bibaViolations.size
    : mode === 'blp' ? graphData.blpViolations.size : 0;
  vEl.textContent = vCount > 0 ? `${vCount} violations` : '';
  vEl.style.color = vCount > 0 ? '#f85149' : '';
}

function updateMatrix() {
  const content = document.getElementById('matrix-content');
  if (!graphData.nodes.length) {
    content.innerHTML = '<div style="color:var(--muted)">No agents loaded</div>';
    return;
  }

  const names = graphData.nodes.map(n => n.id);
  const edgeMap = {};
  for (const link of graphData.links) {
    if (link.type !== 'write_read' && link.type !== 'bcp') continue;
    const src = typeof link.source === 'object' ? link.source.id : link.source;
    const tgt = typeof link.target === 'object' ? link.target.id : link.target;
    if (!edgeMap[`${src}|${tgt}`] || link.type === 'write_read') {
      edgeMap[`${src}|${tgt}`] = link;
    }
  }

  const mode = getAnalysisMode();
  let html = '<table><thead><tr><th></th>';
  for (const name of names) {
    html += `<th>${escapeHtml(truncate(name, 12))}</th>`;
  }
  html += '</tr></thead><tbody>';

  for (const writer of names) {
    html += `<tr><th>${escapeHtml(truncate(writer, 12))}</th>`;
    for (const reader of names) {
      if (writer === reader) {
        html += '<td class="self">-</td>';
        continue;
      }
      const link = edgeMap[`${writer}|${reader}`];
      if (!link) {
        html += '<td></td>';
        continue;
      }
      let cls = 'compliant';
      let label;
      if (mode === 'biba' && link.bibaViolation) {
        cls = 'violation'; label = 'BIBA';
      } else if (mode === 'blp' && link.blpViolation) {
        cls = 'violation'; label = 'BLP';
      } else if (link.type === 'bcp') {
        cls = 'compliant';
        label = `B${link.maxCategory || '?'}`;
      } else {
        label = `T:${(link.taintLevel || 'low')[0]} S:${(link.sensitivityLevel || 'low')[0]}`;
        const rank = levelRank();
        const maxRank = Math.max(rank[link.taintLevel] || 0, rank[link.sensitivityLevel] || 0);
        if (maxRank >= 1) cls = 'warning';
      }
      html += `<td class="${cls}" title="${escapeHtml(writer)} → ${escapeHtml(reader)}: ${escapeHtml(link.paths.join(', '))}">${label}</td>`;
    }
    html += '</tr>';
  }
  html += '</tbody></table>';
  content.innerHTML = html;
}

// ── Explainer panel ──

function updateExplainer() {
  const mode = getAnalysisMode();
  const panel = document.getElementById('analysis-explainer');
  const title = document.getElementById('explainer-title');
  const body = document.getElementById('explainer-body');

  if (mode === 'biba') {
    title.textContent = 'Biba (integrity)';
    body.innerHTML = 'Flags where a low-taint agent reads data from a higher-taint source. ' +
      'The concern is integrity contamination: a clean agent ingesting potentially ' +
      'poisoned data that may contain prompt injection.';
    panel.style.display = '';
  } else if (mode === 'blp') {
    title.textContent = 'Bell-LaPadula (confidentiality)';
    body.innerHTML = 'Flags where an agent with high sensitivity writes to a location ' +
      'readable by a lower-sensitivity, network-capable agent. ' +
      'The concern is data exfiltration: sensitive response data ' +
      'reaching an agent that can send it outside the system.';
    panel.style.display = '';
  } else {
    panel.style.display = 'none';
  }
}

// ── Event listeners ──

document.getElementById('toggle-fs').addEventListener('change', applyFade);
document.getElementById('toggle-msg').addEventListener('change', applyFade);
document.getElementById('toggle-bcp').addEventListener('change', applyFade);
document.getElementById('toggle-labels').addEventListener('change', applyFade);
document.getElementById('toggle-matrix').addEventListener('change', () => { applyFade(); updateMatrix(); });
document.querySelectorAll('input[name="analysis-mode"]').forEach(el => {
  el.addEventListener('change', () => { applyFade(); updateMatrix(); updateExplainer(); updateViolationCount(); });
});

window.addEventListener('resize', () => {
  if (simulation) {
    const container = document.getElementById('graph-container');
    simulation.force('center', d3.forceCenter(container.clientWidth / 2, container.clientHeight / 2));
    simulation.alpha(0.3).restart();
  }
});

// ── Init ──
loadGraph();
