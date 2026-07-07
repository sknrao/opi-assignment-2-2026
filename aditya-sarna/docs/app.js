/* OVS Lab Console — world-class evidence explorer */

(function () {
  'use strict';

  const D = window.APP_DATA;
  const state = {
    tab: 'overview',
    evidenceTab: 'openflow',
    selectedNode: null,
    selectedRoute: 0,
    evidenceQuery: '',
    animFrame: null,
  };

  const POS = {
    'vm-a':         { x: 180, y: 118 },
    'vm-b':         { x: 820, y: 118 },
    'ovs-ping-pod': { x: 500, y: 348 },
    'br1':          { x: 500, y: 228 },
  };

  /* ── DOM helpers ── */
  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (k === 'cls') node.className = v;
        else if (k === 'html') node.innerHTML = v;
        else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v);
      }
    }
    for (const child of children) {
      if (child == null) continue;
      node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    }
    return node;
  }

  function svgEl(tag, attrs) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    if (attrs) for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    return node;
  }

  function badge(text, type) { return el('span', { cls: `badge badge-${type}` }, text); }
  function fmtNum(n) { return n != null ? String(n) : '—'; }

  /* ── Data helpers ── */
  function classifierFlows() {
    return D.flows.filter(f => (f.match || '').includes('nw_src'));
  }

  function activeMegaflows() {
    return D.datapathFlows.filter(f => (f.packets || 0) > 0);
  }

  function vlanFdb() {
    return D.fdb.filter(e => e.vlan === 100);
  }

  function hasVlanTag() {
    return D.datapathFlows.some(f => (f.actions || '').includes('push_vlan'));
  }

  function megaflowsForMac(mac) {
    const m = mac.toLowerCase();
    return D.datapathFlows.filter(f => {
      const o = (f.orig || '').toLowerCase();
      return o.includes(`src=${m}`) || o.includes(`dst=${m}`);
    });
  }

  function fdbForMac(mac) {
    return D.fdb.find(e => e.mac && e.mac.toLowerCase() === mac.toLowerCase());
  }

  function nodeById(id) {
    return D.topology.nodes.find(n => n.id === id);
  }

  function highlightPing(text) {
    return text
      .replace(/0% packet loss/g, '<span class="hl-green">0% packet loss</span>')
      .replace(/ttl=64/g, '<span class="hl-ttl">ttl=64</span>');
  }

  function highlightFlows(text, after) {
    if (!text) return '';
    return text.split('\n').map(line => {
      if (line.includes('nw_src=')) return `<span class="rule-classifier">${line}</span>`;
      if (after && line.includes('actions=NORMAL')) return `<span class="rule-normal">${line}</span>`;
      return line;
    }).join('\n');
  }

  /* ── Hero ── */
  function renderHero() {
    const links = D.links || {};
    return el('section', { cls: 'hero' },
      el('div', { cls: 'hero-eyebrow' },
        el('span', { cls: 'hero-eyebrow-dot' }),
        'Assignment 2 · OPI 2026 · Live Evidence',
      ),
      el('h1', null, 'Cloud-Native OVS Datapath Console'),
      el('p', { cls: 'hero-sub' },
        'Interactive proof that two CirrOS KubeVirt VMs and a verification pod share Open vSwitch bridge ',
        el('strong', null, 'br1'),
        ' through Multus and OVS-CNI — with kernel megaflows, VLAN 100, classifier rules, and CI-gated reproducibility.',
      ),
      el('div', { cls: 'hero-actions' },
        el('a', { cls: 'btn btn-primary', href: links.repo || '#', target: '_blank', rel: 'noopener' }, 'View repository'),
        el('a', { cls: 'btn', href: links.ci || '#', target: '_blank', rel: 'noopener' }, 'CI run'),
        el('a', { cls: 'btn', href: links.submit || '#', target: '_blank', rel: 'noopener' }, 'Verification guide'),
        el('a', { cls: 'btn', href: links.diagram || '#', target: '_blank', rel: 'noopener' }, 'Topology diagram'),
      ),
    );
  }

  function renderMetaStrip() {
    const m = D.meta || {};
    const ts = (m.timestamp_utc || '').replace('T', ' ').slice(0, 19) + ' UTC';
    const links = D.links || {};
    return el('div', { cls: 'meta-strip' },
      el('span', { cls: 'chip' }, el('strong', null, 'bridge'), ' ' + (m.bridge || 'br1')),
      el('span', { cls: 'chip' }, el('strong', null, 'node'), ' ' + (m.node || '')),
      el('span', { cls: 'chip' }, (m.ovs_version || '').replace('ovs-vsctl ', '')),
      el('span', { cls: 'chip' }, el('strong', null, 'captured'), ' ' + ts),
      el('a', { cls: 'ci-badge', href: links.ci || '#', target: '_blank', rel: 'noopener' },
        el('span', { cls: 'ci-dot' }), 'CI passing',
      ),
    );
  }

  /* ── Proof cards ── */
  function renderProofCards() {
    const s = D.stats || {};
    const cf = classifierFlows();
    const cards = [
      { cls: 'accent-green', icon: '↔', label: 'Ping Proof', value: `${D.pingBlocks}/4`, desc: 'Zero-loss blocks: pod→VM and VM↔VM console', status: 'All directions pass', tab: 'pings' },
      { cls: 'accent-blue', icon: '⚡', label: 'Classifiers', value: s.classifierRules || cf.length, desc: `nw_src= rules · min n_packets = ${s.classifierMinPackets || 0}`, status: 'Rules hit during ping', tab: 'diff' },
      { cls: 'accent-purple', icon: '◈', label: 'Megaflows', value: s.megaflowActive || activeMegaflows().length, desc: `Active cache entries · max ${s.megaflowMaxPackets || 0} pkts`, status: `${s.megaflowTotal || D.datapathFlows.length} captured`, tab: 'evidence' },
      { cls: 'accent-yellow', icon: '▣', label: 'VLAN + FDB', value: s.fdbVlan100 || vlanFdb().length, desc: `FDB on VLAN 100${hasVlanTag() ? ' · push_vlan confirmed' : ''}`, status: 'Access port tag/strip', tab: 'evidence' },
    ];

    const grid = el('div', { cls: 'proof-grid' });
    for (const c of cards) {
      grid.appendChild(
        el('div', { cls: `proof-card ${c.cls}`, onclick: () => switchTab(c.tab) },
          el('div', { cls: 'proof-card-top' },
            el('div', { cls: 'proof-card-label' }, c.label),
            el('div', { cls: 'proof-icon' }, c.icon),
          ),
          el('div', { cls: 'proof-card-value' }, String(c.value)),
          el('div', { cls: 'proof-card-desc' }, c.desc),
          el('div', { cls: 'proof-card-status' }, c.status),
        ),
      );
    }
    return grid;
  }

  function renderNav() {
    const tabs = [
      { id: 'overview', label: 'Overview' },
      { id: 'pings', label: 'Ping Proof' },
      { id: 'diff', label: 'Flow Diff' },
      { id: 'evidence', label: 'Evidence' },
      { id: 'journey', label: 'Journey' },
    ];
    const nav = el('nav', { cls: 'main-nav', role: 'tablist' });
    for (const t of tabs) {
      nav.appendChild(el('button', {
        cls: `nav-tab${state.tab === t.id ? ' active' : ''}`,
        role: 'tab',
        'data-tab': t.id,
        'aria-selected': state.tab === t.id ? 'true' : 'false',
        onclick: () => switchTab(t.id),
      }, t.label));
    }
    return nav;
  }

  /* ── Topology + packet animation ── */
  function routePath(source, target) {
    const br = POS.br1;
    const a = POS[source];
    const b = POS[target];
    if (!a || !b) return [];
    return [a, br, b];
  }

  function lerp(a, b, t) {
    return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
  }

  function pointOnPolyline(points, t) {
    if (points.length < 2) return points[0] || { x: 0, y: 0 };
    const segs = [];
    let total = 0;
    for (let i = 0; i < points.length - 1; i++) {
      const dx = points[i + 1].x - points[i].x;
      const dy = points[i + 1].y - points[i].y;
      const len = Math.hypot(dx, dy);
      segs.push({ a: points[i], b: points[i + 1], len });
      total += len;
    }
    let dist = t * total;
    for (const s of segs) {
      if (dist <= s.len) {
        const r = s.len ? dist / s.len : 0;
        return lerp(s.a, s.b, r);
      }
      dist -= s.len;
    }
    return points[points.length - 1];
  }

  function startPacketAnimation(svg, dot, source, target) {
    if (state.animFrame) cancelAnimationFrame(state.animFrame);
    const path = routePath(source, target);
    if (path.length < 2) return;
    let start = null;
    const duration = 2200;
    function frame(ts) {
      if (!start) start = ts;
      const t = ((ts - start) % duration) / duration;
      const p = pointOnPolyline(path, t);
      dot.setAttribute('cx', p.x);
      dot.setAttribute('cy', p.y);
      state.animFrame = requestAnimationFrame(frame);
    }
    state.animFrame = requestAnimationFrame(frame);
  }

  function themeColor(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }

  function renderTopology() {
    const layout = el('div', { cls: 'topology-layout' });
    const W = 1000, H = 420;
    const svg = svgEl('svg', { viewBox: `0 0 ${W} ${H}`, id: 'topo-svg' });

    const defs = svgEl('defs');
    const grad = svgEl('linearGradient', { id: 'brGrad', x1: '0', y1: '0', x2: '1', y2: '1' });
    grad.appendChild(svgEl('stop', { offset: '0%', 'stop-color': themeColor('--topo-br-fill-a') || '#ede9fe' }));
    grad.appendChild(svgEl('stop', { offset: '100%', 'stop-color': themeColor('--topo-br-fill-b') || '#ddd6fe' }));
    defs.appendChild(grad);
    svg.appendChild(defs);

    const routes = D.pingDirections || [];
    const route = routes[state.selectedRoute];
    const activeEdge = route ? new Set([route.source, route.target]) : new Set();
    const vmColor = themeColor('--vm') || '#0284c7';
    const podColor = themeColor('--pod') || '#059669';
    const brStroke = themeColor('--topo-br-stroke') || '#7c3aed';
    const textPrimary = themeColor('--text') || '#0f172a';
    const textMuted = themeColor('--text-muted') || '#475569';
    const textSubtle = themeColor('--text-subtle') || '#64748b';

    for (const e of D.topology.edges) {
      const from = POS[e.from];
      const to = POS.br1;
      if (!from) continue;
      const active = activeEdge.has(e.from);
      svg.appendChild(svgEl('line', {
        x1: from.x, y1: from.y, x2: to.x, y2: to.y,
        class: `topo-line${active ? ' active' : ''}`,
        'data-from': e.from,
      }));
    }

    const br = POS.br1;
    const brG = svgEl('g', { class: 'topo-node', 'data-id': 'br1' });
    brG.appendChild(svgEl('rect', {
      x: br.x - 88, y: br.y - 36, width: 176, height: 72, rx: 14,
      fill: 'url(#brGrad)', stroke: brStroke, 'stroke-width': 2,
    }));
    const brT = svgEl('text', { class: 'topo-label', x: br.x, y: br.y - 6, fill: textPrimary, 'font-size': '17' });
    brT.textContent = 'br1';
    const brS = svgEl('text', { class: 'topo-sublabel', x: br.x, y: br.y + 16, fill: textMuted, 'font-size': '12' });
    brS.textContent = 'VLAN 100 · OVS · Megaflows';
    brG.appendChild(brT);
    brG.appendChild(brS);
    svg.appendChild(brG);

    for (const node of D.topology.nodes) {
      const p = POS[node.id];
      if (!p) continue;
      const sel = state.selectedNode === node.id;
      const color = node.type === 'vm' ? vmColor : podColor;
      const g = svgEl('g', { class: `topo-node${sel ? ' selected' : ''}`, 'data-id': node.id, style: 'cursor:pointer' });
      g.addEventListener('click', () => selectNode(node.id));

      g.appendChild(svgEl('circle', {
        cx: p.x, cy: p.y, r: 54,
        fill: node.type === 'vm' ? 'rgba(2,132,199,0.1)' : 'rgba(5,150,105,0.1)',
        stroke: sel ? vmColor : color,
        'stroke-width': sel ? 3 : 2,
      }));
      if (sel) {
        g.appendChild(svgEl('circle', {
          cx: p.x, cy: p.y, r: 62, fill: 'none', stroke: color, 'stroke-width': 1, opacity: '0.4',
        }));
      }

      const lb = svgEl('text', { class: 'topo-label', x: p.x, y: p.y - 10, fill: textPrimary, 'font-size': '15' });
      lb.textContent = node.id;
      const ip = svgEl('text', { class: 'topo-sublabel', x: p.x, y: p.y + 12, fill: textMuted, 'font-size': '12' });
      ip.textContent = node.ip;
      const mac = svgEl('text', { class: 'topo-sublabel', x: p.x, y: p.y + 28, fill: textSubtle, 'font-size': '10' });
      mac.textContent = node.mac;
      g.appendChild(lb);
      g.appendChild(ip);
      g.appendChild(mac);
      svg.appendChild(g);
    }

    const dot = svgEl('circle', {
      id: 'packet-dot', class: 'packet-dot', cx: 0, cy: 0, r: 7,
      fill: podColor, stroke: '#ffffff', 'stroke-width': 2, opacity: '0',
    });
    svg.appendChild(dot);

    const canvasWrap = el('div', { cls: 'topology-canvas' });
    const head = el('div', { cls: 'panel-head' },
      el('div', null,
        el('div', { cls: 'panel-title' }, 'Live topology'),
        el('div', { cls: 'panel-sub' }, 'Click a node · animate a verified ping path'),
      ),
      routes.length ? el('select', {
        cls: 'route-select',
        onchange: (e) => {
          state.selectedRoute = Number(e.target.value);
          rerenderTopology(svg, dot);
        },
      }, ...routes.map((r, i) => el('option', { value: String(i) }, r.label))) : null,
    );
    canvasWrap.appendChild(head);
    canvasWrap.appendChild(svg);

    const panel = el('div', { cls: 'node-panel', id: 'node-panel' });
    renderNodePanel(panel, state.selectedNode);

    layout.appendChild(canvasWrap);
    layout.appendChild(panel);

    if (route) {
      dot.setAttribute('opacity', '1');
      startPacketAnimation(svg, dot, route.source, route.target);
    }

    return layout;
  }

  function rerenderTopology(svg, dot) {
    const routes = D.pingDirections || [];
    const route = routes[state.selectedRoute];
    svg.querySelectorAll('.topo-line').forEach(line => {
      const from = line.getAttribute('data-from');
      const active = route && (from === route.source || from === route.target);
      line.classList.toggle('active', active);
    });
    if (route) {
      dot.setAttribute('opacity', '1');
      startPacketAnimation(svg, dot, route.source, route.target);
    } else {
      dot.setAttribute('opacity', '0');
      if (state.animFrame) cancelAnimationFrame(state.animFrame);
    }
  }

  function renderNodePanel(panel, nodeId) {
    panel.innerHTML = '';
    if (!nodeId) {
      panel.appendChild(el('div', { cls: 'node-panel-empty' },
        'Select a node to inspect MAC, OVS port, and kernel megaflows tied to that endpoint.',
      ));
      return;
    }
    const node = nodeById(nodeId);
    if (!node) return;
    const fdbEntry = fdbForMac(node.mac);
    const flows = megaflowsForMac(node.mac).sort((a, b) => (b.packets || 0) - (a.packets || 0));

    panel.appendChild(el('div', { cls: 'node-panel-title' }, node.id));
    panel.appendChild(el('span', { cls: `node-type-badge ${node.type}` }, node.type.toUpperCase()));

    const rows = [['IP', node.ip], ['MAC', node.mac], ['Stack', 'Multus + OVS-CNI']];
    if (fdbEntry) {
      rows.push(['OVS Port', String(fdbEntry.port)]);
      rows.push(['FDB VLAN', String(fdbEntry.vlan)]);
      rows.push(['FDB Age', `${fdbEntry.age_s}s`]);
    }
    for (const [k, v] of rows) {
      panel.appendChild(el('div', { cls: 'detail-row' },
        el('span', { cls: 'detail-key' }, k),
        el('span', { cls: 'detail-value' }, v),
      ));
    }

    if (flows.length) {
      const sec = el('div', { cls: 'panel-section' });
      sec.appendChild(el('div', { cls: 'panel-section-title' }, `Kernel megaflows (${flows.length})`));
      for (const f of flows.slice(0, 8)) {
        const orig = (f.orig || '').replace('recirc_id(0),', '').slice(0, 56);
        sec.appendChild(el('div', { cls: 'megaflow-row' },
          el('span', null, orig + (orig.length >= 56 ? '…' : '')),
          el('span', { cls: 'megaflow-pkts' }, `${f.packets}p`),
        ));
      }
      panel.appendChild(sec);
    }
  }

  function selectNode(id) {
    state.selectedNode = state.selectedNode === id ? null : id;
    const panel = document.getElementById('node-panel');
    if (panel) renderNodePanel(panel, state.selectedNode);
    document.querySelectorAll('.topo-node[data-id]').forEach(g => {
      if (g.dataset.id === 'br1') return;
      g.classList.toggle('selected', g.dataset.id === state.selectedNode);
    });
  }

  /* ── Pings ── */
  function renderPings() {
    const wrap = el('div', { cls: 'panel' },
      el('div', { cls: 'panel-head' },
        el('div', null,
          el('div', { cls: 'panel-title' }, 'Ping proof — four directions'),
          el('div', { cls: 'panel-sub' }, 'All blocks show 0% packet loss · ttl=64 confirms single L2 hop across br1'),
        ),
      ),
    );
    const grid = el('div', { cls: 'ping-grid', style: 'padding:18px' });
    const dirs = D.pingDirections || [];
    if (!dirs.length) {
      grid.appendChild(el('pre', { cls: 'ping-pre' }, D.pingText || 'No ping data'));
    } else {
      for (const d of dirs) {
        const card = el('div', { cls: `ping-card${d.pass ? ' pass' : ''}` },
          el('div', { cls: 'ping-card-head' },
            el('div', { cls: 'ping-card-title' }, d.label),
            el('span', { cls: 'ping-method' }, d.method),
          ),
          el('div', { cls: 'ping-badges' },
            d.pass ? badge('0% loss', 'green') : badge('FAIL', 'yellow'),
            d.ttl64 ? badge('ttl=64', 'blue') : null,
            badge(d.targetIp, 'blue'),
          ),
          el('div', { cls: 'ping-body' },
            el('div', { cls: 'ping-pre', html: highlightPing(d.text) }),
          ),
        );
        grid.appendChild(card);
      }
    }
    wrap.appendChild(grid);
    return wrap;
  }

  /* ── Flow diff ── */
  function renderFlowDiff() {
    const wrap = el('div', null,
      el('div', { cls: 'diff-grid' },
        el('div', { cls: 'diff-panel' },
          el('div', { cls: 'diff-head' }, 'Before classifiers', el('span', null, 'evidence/flows_before.txt · 1 NORMAL rule')),
          el('div', { cls: 'diff-pre', html: highlightFlows(D.flowsBefore || '', false) }),
        ),
        el('div', { cls: 'diff-panel after' },
          el('div', { cls: 'diff-head' }, 'After ping suite', el('span', null, 'evidence/flows_after.txt · 5 rules with hits')),
          el('div', { cls: 'diff-pre', html: highlightFlows(D.flowsAfter || '', true) }),
        ),
      ),
      el('div', { cls: 'diff-callout' },
        el('strong', null, 'Why this matters: '),
        'install_classifier_flows() proves per-source OpenFlow classification — not just a learning switch. ',
        'The same rule shape compiles to BlueField-3 hardware via OVS-DOCA.',
      ),
    );
    return wrap;
  }

  /* ── Evidence ── */
  function renderEvidence() {
    const layout = el('div', { cls: 'panel evidence-layout' });
    const sidebar = el('div', { cls: 'evidence-sidebar' });
    const content = el('div', { cls: 'evidence-content', id: 'evidence-content' });

    const tabs = [
      { id: 'openflow', label: 'OpenFlow' },
      { id: 'datapath', label: 'Datapath' },
      { id: 'fdb', label: 'FDB' },
      { id: 'ports', label: 'Ports' },
      { id: 'raw', label: 'Raw JSON' },
    ];
    for (const t of tabs) {
      sidebar.appendChild(el('button', {
        cls: `evidence-tab${state.evidenceTab === t.id ? ' active' : ''}`,
        'data-evidence-tab': t.id,
        onclick: () => switchEvidenceTab(t.id),
      }, t.label));
    }
    renderEvidenceContent(content, state.evidenceTab);
    layout.appendChild(sidebar);
    layout.appendChild(content);
    return layout;
  }

  function renderEvidenceContent(container, tabId) {
    container.innerHTML = '';
    const m = D.meta || {};
    container.appendChild(el('div', { cls: 'evidence-toolbar' },
      tabId !== 'raw' ? el('input', {
        cls: 'search-input',
        type: 'search',
        placeholder: 'Filter rows…',
        value: state.evidenceQuery,
        oninput: (e) => {
          state.evidenceQuery = e.target.value;
          renderEvidenceContent(container, tabId);
        },
      }) : null,
      tabId === 'raw' ? el('button', {
        cls: 'btn',
        onclick: () => {
          const raw = JSON.stringify({ _meta: m, flows: D.flows, datapath_flows: D.datapathFlows, fdb: D.fdb, ports: D.ports }, null, 2);
          navigator.clipboard.writeText(raw);
        },
      }, 'Copy JSON') : null,
    ));

    const q = state.evidenceQuery.toLowerCase();
    const match = (s) => !q || String(s || '').toLowerCase().includes(q);

    if (tabId === 'openflow') container.appendChild(wrapTable(renderOpenflowTable(match)));
    if (tabId === 'datapath') container.appendChild(wrapTable(renderDatapathTable(match)));
    if (tabId === 'fdb') container.appendChild(wrapTable(renderFdbTable(match)));
    if (tabId === 'ports') container.appendChild(wrapTable(renderPortsTable(match)));
    if (tabId === 'raw') container.appendChild(renderRawJson());
  }

  function wrapTable(table) {
    const w = el('div', { cls: 'table-wrap' });
    w.appendChild(table);
    return w;
  }

  function renderOpenflowTable(match) {
    const rows = D.flows.filter(f => match(f.match) || match(f.actions) || match(f.priority)).sort((a, b) => (b.priority || 0) - (a.priority || 0));
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'Priority'), el('th', null, 'Match'), el('th', null, 'n_packets'), el('th', null, 'n_bytes'), el('th', null, 'Actions'),
    )));
    const tbody = el('tbody');
    for (const f of rows) {
      const isCl = (f.match || '').includes('nw_src');
      const tr = el('tr', { cls: isCl ? 'highlight' : '' });
      tr.appendChild(el('td', null, fmtNum(f.priority)));
      tr.appendChild(el('td', null, f.match || '*', isCl ? badge('classifier', 'blue') : null));
      const pk = el('td', null);
      pk.appendChild(el('span', { cls: f.n_packets > 0 ? 'num-positive' : '' }, fmtNum(f.n_packets)));
      tr.appendChild(pk);
      tr.appendChild(el('td', null, fmtNum(f.n_bytes)));
      tr.appendChild(el('td', null, f.actions || ''));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderDatapathTable(match) {
    const rows = D.datapathFlows.filter(f => match(f.orig) || match(f.actions)).sort((a, b) => (b.packets || 0) - (a.packets || 0));
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'Pkts'), el('th', null, 'Bytes'), el('th', null, 'Used'), el('th', null, 'Actions'), el('th', null, 'Flags'),
    )));
    const tbody = el('tbody');
    for (const f of rows) {
      const hasVlan = (f.actions || '').includes('push_vlan');
      const tr = el('tr');
      const pk = el('td', null);
      pk.appendChild(el('span', { cls: f.packets > 0 ? 'num-positive' : '' }, fmtNum(f.packets)));
      tr.appendChild(pk);
      tr.appendChild(el('td', null, fmtNum(f.bytes)));
      tr.appendChild(el('td', null, f.used_s != null ? String(f.used_s) : '—'));
      tr.appendChild(el('td', null, (f.actions || '').slice(0, 48)));
      const fl = el('td');
      if (hasVlan) fl.appendChild(badge('push_vlan', 'yellow'));
      tr.appendChild(fl);
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderFdbTable(match) {
    const macNode = {};
    for (const n of D.topology.nodes) macNode[n.mac.toLowerCase()] = n.id;
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'Port'), el('th', null, 'VLAN'), el('th', null, 'MAC'), el('th', null, 'Age'), el('th', null, 'Node'),
    )));
    const tbody = el('tbody');
    for (const e of D.fdb.filter(x => match(x.mac) || match(x.port) || match(x.vlan))) {
      const tr = el('tr');
      tr.appendChild(el('td', null, fmtNum(e.port)));
      tr.appendChild(el('td', null, el('span', { cls: e.vlan === 100 ? 'num-positive' : '' }, fmtNum(e.vlan))));
      tr.appendChild(el('td', null, e.mac || ''));
      tr.appendChild(el('td', null, e.age_s || ''));
      tr.appendChild(el('td', null, macNode[(e.mac || '').toLowerCase()] || '—'));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderPortsTable(match) {
    const table = el('table', { cls: 'data-table' });
    table.appendChild(el('thead', null, el('tr', null,
      el('th', null, 'OFPort'), el('th', null, 'Name'), el('th', null, 'MAC'),
    )));
    const tbody = el('tbody');
    for (const p of D.ports.filter(x => match(x.name) || match(x.mac) || match(x.ofport))) {
      const tr = el('tr');
      tr.appendChild(el('td', null, p.ofport || ''));
      tr.appendChild(el('td', null, p.name || ''));
      tr.appendChild(el('td', null, p.mac || ''));
      tbody.appendChild(tr);
    }
    table.appendChild(tbody);
    return table;
  }

  function renderRawJson() {
    const pre = el('pre', { cls: 'raw-pre' });
    pre.textContent = JSON.stringify({ _meta: D.meta, bridge: D.bridge, flows: D.flows, datapath_flows: D.datapathFlows, fdb: D.fdb, ports: D.ports }, null, 2);
    return pre;
  }

  /* ── Journey ── */
  function renderJourney() {
    const list = el('div', { cls: 'journey-list' });
    D.journey.forEach((item, i) => {
      const card = el('div', { cls: 'journey-card' },
        el('div', { cls: 'journey-step' }, `Step ${i + 1}`),
        el('div', { cls: 'journey-title' }, item.title),
      );
      if (item.problem) card.appendChild(el('div', { cls: 'journey-problem' }, 'Problem: ' + item.problem));
      if (item.fix) card.appendChild(el('div', { cls: 'journey-fix' }, 'Fix: ' + item.fix));
      if (item.detail) card.appendChild(el('div', { cls: 'journey-detail' }, item.detail));
      if (item.proof) card.appendChild(el('div', { cls: 'journey-proof' }, '↳ ' + item.proof));
      const wrapper = el('div', { cls: 'journey-item' });
      wrapper.appendChild(el('div', { cls: 'journey-dot' }));
      wrapper.appendChild(card);
      list.appendChild(wrapper);
    });
    return el('div', { cls: 'panel', style: 'padding:28px 24px' }, list);
  }

  function renderDisclosure() {
    const em = D.executionMode || {};
    if (!em.raw && !em.accel) return null;
    const isKvm = (em.accel || '').includes('kvm') && em.useEmulation !== 'true';
    const parts = [
      el('strong', null, 'Execution disclosure: '),
      'Committed CI run uses ',
      em.accel || 'unknown accel',
    ];
    if (isKvm) {
      parts.push(
        ' with /dev/kvm bind-mounted into KinD (',
        String(em.vmxCount || '?'),
        ' vmx/svm cores). useEmulation is disabled — hardware-accelerated nested KVM on GitHub Actions.',
      );
    } else if (em.useEmulation === 'true') {
      parts.push(
        ' with useEmulation=true (TCG fallback when /dev/kvm is unavailable). OVS datapath evidence is the same; only boot speed differs.',
      );
    }
    return el('div', { cls: `disclosure${isKvm ? ' disclosure-kvm' : ''}` }, ...parts);
  }

  function renderFooter() {
    const links = D.links || {};
    return el('footer', { cls: 'site-footer' },
      el('span', null, 'Aditya Sarna · OPI Assignment 2 · Cloud-Native OVS Datapath'),
      el('span', null,
        el('a', { href: links.repo || '#', target: '_blank', rel: 'noopener' }, 'GitHub'),
        ' · ',
        el('a', { href: links.ci || '#', target: '_blank', rel: 'noopener' }, 'CI'),
        ' · ',
        el('a', { href: links.assignment || '#', target: '_blank', rel: 'noopener' }, 'Assignment repo'),
      ),
    );
  }

  /* ── Navigation ── */
  function switchTab(id) {
    if (state.animFrame) cancelAnimationFrame(state.animFrame);
    state.tab = id;
    document.querySelectorAll('.nav-tab').forEach(b => {
      b.classList.toggle('active', b.dataset.tab === id);
      b.setAttribute('aria-selected', b.dataset.tab === id ? 'true' : 'false');
    });
    const content = document.getElementById('main-content');
    if (content) renderContent(content);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function switchEvidenceTab(id) {
    state.evidenceTab = id;
    state.evidenceQuery = '';
    document.querySelectorAll('.evidence-tab').forEach(b => {
      b.classList.toggle('active', b.dataset.evidenceTab === id);
    });
    const content = document.getElementById('evidence-content');
    if (content) renderEvidenceContent(content, id);
  }

  function renderContent(container) {
    container.innerHTML = '';
    if (state.tab === 'overview') container.appendChild(renderTopology());
    if (state.tab === 'pings') container.appendChild(renderPings());
    if (state.tab === 'diff') container.appendChild(renderFlowDiff());
    if (state.tab === 'evidence') container.appendChild(renderEvidence());
    if (state.tab === 'journey') container.appendChild(renderJourney());
  }

  function init() {
    if (!D) {
      document.getElementById('app').textContent = 'Error: data.js not loaded.';
      return;
    }
    const app = document.getElementById('app');
    app.innerHTML = '';
    app.appendChild(renderHero());
    app.appendChild(renderMetaStrip());
    app.appendChild(renderProofCards());
    app.appendChild(renderNav());
    const content = el('div', { cls: 'tab-content', id: 'main-content' });
    renderContent(content);
    app.appendChild(content);
    const disc = renderDisclosure();
    if (disc) app.appendChild(disc);
    app.appendChild(renderFooter());

    document.addEventListener('keydown', (e) => {
      const keys = ['1', '2', '3', '4', '5'];
      const tabs = ['overview', 'pings', 'diff', 'evidence', 'journey'];
      const i = keys.indexOf(e.key);
      if (i >= 0 && !e.metaKey && !e.ctrlKey && document.activeElement?.tagName !== 'INPUT') {
        switchTab(tabs[i]);
      }
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
