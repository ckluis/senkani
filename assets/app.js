// Senkani site — shared behaviors
(function () {
  'use strict';

  // --- Mobile hamburger nav -----------------------------------
  const hamburger = document.querySelector('.topnav-hamburger');
  const navLinks  = document.getElementById('topnav-links');
  if (hamburger && navLinks) {
    hamburger.addEventListener('click', () => {
      const isOpen = navLinks.classList.toggle('open');
      hamburger.setAttribute('aria-expanded', String(isOpen));
      hamburger.setAttribute('aria-label', isOpen ? 'Close navigation menu' : 'Open navigation menu');
    });
    navLinks.querySelectorAll('a').forEach(a => {
      a.addEventListener('click', () => {
        navLinks.classList.remove('open');
        hamburger.setAttribute('aria-expanded', 'false');
        hamburger.setAttribute('aria-label', 'Open navigation menu');
      });
    });
  }

  // --- Active wiki-nav link on load ---------------------------
  const here = window.location.pathname.replace(/\/index\.html$/, '/');
  document.querySelectorAll('.wiki-nav a').forEach(a => {
    const href = a.getAttribute('href');
    if (!href) return;
    const aPath = new URL(href, window.location.href).pathname.replace(/\/index\.html$/, '/');
    if (aPath === here) a.classList.add('active');
  });
  document.querySelectorAll('.topnav-links a').forEach(a => {
    const href = a.getAttribute('href');
    if (!href) return;
    try {
      const u = new URL(href, window.location.href);
      const section = u.pathname.split('/').filter(Boolean)[0] || '';
      const pageSection = window.location.pathname.split('/').filter(Boolean)[0] || '';
      if (section && section === pageSection) a.classList.add('active');
    } catch (e) {}
  });

  // --- Legacy anchor → new URL redirects ----------------------
  // Preserve inbound links from before the rebuild. Paths are
  // relative to the site root, so compute a prefix from the current
  // page back to root.
  const legacyMap = {
    'how-it-works':   'docs/concepts/',
    'hook-architecture': 'docs/concepts/hook-relay.html',
    'filter-pipeline':   'docs/concepts/compression-layer.html',
    'smart-denials':     'docs/concepts/three-layer-stack.html',
    'intelligence':   'docs/concepts/mcp-intelligence.html',
    'symbol-indexer': 'docs/concepts/mcp-intelligence.html',
    'read-cache':     'docs/reference/mcp/senkani_read.html',
    'local-ml':       'docs/concepts/mcp-intelligence.html',
    'control':        'docs/reference/options/',
    'budget':         'docs/reference/options/budget.html',
    'terse':          'docs/reference/options/terse.html',
    'session-db':     'docs/concepts/three-layer-stack.html',
    'interface':      'docs/reference/',
    'mcp-tools':      'docs/reference/mcp/',
    'cli':            'docs/reference/cli/',
    'workspace':      'docs/reference/panes/',
    'configuration':  'docs/reference/options/',
    'status':         'docs/status.html',
    'whats-built':    'docs/status.html',
    'install':        'docs/guides/install.html'
  };
  const hash = window.location.hash.replace(/^#/, '');
  if (hash && legacyMap[hash] && /index\.html?$|\/$/.test(window.location.pathname)) {
    const depth = window.location.pathname.split('/').filter(Boolean).length - (
      /index\.html?$/.test(window.location.pathname) ? 1 : 0
    );
    if (depth === 0) window.location.replace(legacyMap[hash]);
  }

  // --- Search: lazy Lunr loader -------------------------------
  const searchInput = document.getElementById('site-search');
  if (searchInput) {
    let idx = null;
    let docs = null;
    let loaded = false;
    let loading = false;
    let resultsEl = null;

    const ensureResultsEl = () => {
      if (resultsEl) return resultsEl;
      resultsEl = document.createElement('div');
      resultsEl.id = 'search-results';
      resultsEl.className = 'search-results';
      resultsEl.setAttribute('role', 'listbox');
      searchInput.parentNode.appendChild(resultsEl);
      return resultsEl;
    };

    // Compute the site base by backing out to where app.js lives.
    // app.js is always at `<base>/assets/app.js` — so find the <script src>
    // and derive the base path.
    const appScript = document.querySelector('script[src$="assets/app.js"]');
    const siteBase = appScript ? appScript.src.replace(/assets\/app\.js.*$/, '') : '/';

    const loadLunr = () => new Promise((resolve, reject) => {
      if (window.lunr) return resolve();
      if (loading) return;
      loading = true;
      const s = document.createElement('script');
      s.src = siteBase + 'assets/lunr.min.js';
      s.onload = resolve;
      s.onerror = reject;
      document.head.appendChild(s);
    });

    const loadIndex = async () => {
      if (loaded) return;
      try {
        await loadLunr();
        const resp = await fetch(siteBase + 'assets/search-index.json');
        if (!resp.ok) throw new Error('index fetch failed');
        const data = await resp.json();
        docs = data.docs;
        idx = lunr(function () {
          this.ref('id');
          this.field('title', { boost: 10 });
          this.field('path', { boost: 3 });
          this.field('body');
          data.docs.forEach(d => this.add(d));
        });
        loaded = true;
      } catch (e) {
        console.warn('Search index unavailable:', e);
      }
    };

    let activeIdx = -1;
    const renderResults = (results) => {
      const el = ensureResultsEl();
      if (!results || results.length === 0) {
        el.innerHTML = '<div class="search-empty">No results</div>';
        el.classList.add('open');
        activeIdx = -1;
        return;
      }
      el.innerHTML = results.slice(0, 8).map((r, i) => {
        const d = docs.find(x => x.id === r.ref);
        if (!d) return '';
        return `<a class="search-hit" href="${d.path}" role="option" data-idx="${i}">` +
          `<span class="hit-title">${d.title}</span>` +
          `<span class="hit-path">${d.path}</span></a>`;
      }).join('');
      el.classList.add('open');
      activeIdx = -1;
    };

    searchInput.addEventListener('focus', loadIndex);
    searchInput.addEventListener('input', async () => {
      const q = searchInput.value.trim();
      if (!q) { if (resultsEl) resultsEl.classList.remove('open'); return; }
      await loadIndex();
      if (!idx) return;
      try {
        const fuzzy = q.split(/\s+/).map(w => `${w}* ${w}~1`).join(' ');
        const results = idx.search(fuzzy);
        renderResults(results);
      } catch (e) {}
    });
    searchInput.addEventListener('keydown', (e) => {
      if (!resultsEl || !resultsEl.classList.contains('open')) return;
      const hits = resultsEl.querySelectorAll('.search-hit');
      if (e.key === 'ArrowDown') { e.preventDefault(); activeIdx = Math.min(activeIdx + 1, hits.length - 1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); activeIdx = Math.max(activeIdx - 1, 0); }
      else if (e.key === 'Enter' && activeIdx >= 0) { e.preventDefault(); hits[activeIdx].click(); return; }
      else if (e.key === 'Escape') { resultsEl.classList.remove('open'); searchInput.blur(); return; }
      else return;
      hits.forEach((h, i) => h.classList.toggle('active', i === activeIdx));
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === '/' && document.activeElement !== searchInput &&
          !['INPUT','TEXTAREA'].includes(document.activeElement.tagName)) {
        e.preventDefault();
        searchInput.focus();
      }
    });
    document.addEventListener('click', (e) => {
      if (!resultsEl) return;
      if (!resultsEl.contains(e.target) && e.target !== searchInput) {
        resultsEl.classList.remove('open');
      }
    });
  }

  // --- Copy-to-clipboard for code blocks ----------------------
  document.querySelectorAll('.code').forEach(code => {
    if (code.dataset.nocopy === 'true') return;
    const btn = document.createElement('button');
    btn.className = 'code-copy';
    btn.setAttribute('aria-label', 'Copy to clipboard');
    btn.textContent = 'Copy';
    code.style.position = 'relative';
    code.appendChild(btn);
    btn.addEventListener('click', async () => {
      const text = code.innerText.replace(/^Copy$/m, '').trim();
      try {
        await navigator.clipboard.writeText(text);
        btn.textContent = 'Copied';
        setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
      } catch (e) {
        btn.textContent = 'Error';
        setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
      }
    });
  });
})();
