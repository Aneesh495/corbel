/// Embedded single-page web management dashboard for cluster administration and search exploration.
class DashboardAssets {
  static const String indexHtml = '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Corbel Engine Dashboard</title>
  <style>
    :root {
      --bg-dark: #0f172a;
      --card-bg: #1e293b;
      --border-color: #334155;
      --accent: #38bdf8;
      --accent-hover: #0284c7;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
      --success: #22c55e;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    body { background-color: var(--bg-dark); color: var(--text-main); min-height: 100vh; padding: 24px; }
    header { display: flex; justify-content: space-between; align-items: center; padding-bottom: 24px; border-bottom: 1px solid var(--border-color); margin-bottom: 24px; }
    .logo { font-size: 24px; font-weight: 700; color: var(--accent); letter-spacing: -0.5px; }
    .status-badge { background: rgba(34, 197, 94, 0.15); color: var(--success); padding: 6px 12px; border-radius: 9999px; font-size: 13px; font-weight: 600; border: 1px solid rgba(34, 197, 94, 0.3); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 20px; margin-bottom: 32px; }
    .card { background-color: var(--card-bg); border: 1px solid var(--border-color); border-radius: 12px; padding: 20px; }
    .card-title { font-size: 13px; font-weight: 600; color: var(--text-muted); text-transform: uppercase; margin-bottom: 8px; }
    .card-value { font-size: 28px; font-weight: 700; color: var(--text-main); }
    .section-title { font-size: 18px; font-weight: 600; margin-bottom: 16px; color: var(--text-main); }
    .search-bar { display: flex; gap: 12px; margin-bottom: 24px; }
    input[type="text"] { flex: 1; background: var(--card-bg); border: 1px solid var(--border-color); border-radius: 8px; padding: 12px 16px; color: #fff; font-size: 15px; outline: none; }
    input[type="text"]:focus { border-color: var(--accent); }
    button { background: var(--accent); color: #0f172a; border: none; border-radius: 8px; padding: 12px 24px; font-weight: 600; cursor: pointer; transition: background 0.15s; }
    button:hover { background: var(--accent-hover); }
    table { width: 100%; border-collapse: collapse; text-align: left; margin-top: 12px; }
    th { color: var(--text-muted); font-size: 13px; padding: 12px; border-bottom: 1px solid var(--border-color); }
    td { padding: 14px 12px; border-bottom: 1px solid var(--border-color); font-size: 14px; }
    .highlight { background: rgba(56, 189, 248, 0.2); color: var(--accent); font-weight: 600; padding: 2px 4px; border-radius: 4px; }
    .results-panel { background: var(--card-bg); border: 1px solid var(--border-color); border-radius: 12px; padding: 20px; }
    .hit-item { padding: 14px 0; border-bottom: 1px solid var(--border-color); }
    .hit-item:last-child { border-bottom: none; }
    .hit-header { display: flex; justify-content: space-between; margin-bottom: 6px; }
    .hit-id { font-weight: 600; color: var(--accent); }
    .hit-score { font-size: 12px; color: var(--text-muted); }
    .hit-body { font-size: 14px; color: #cbd5e1; line-height: 1.5; }
  </style>
</head>
<body>
  <header>
    <div class="logo">CORBEL ENGINE</div>
    <div class="status-badge" id="cluster-status">CLUSTER HEALTH: GREEN</div>
  </header>

  <div class="grid">
    <div class="card">
      <div class="card-title">Indices</div>
      <div class="card-value" id="stat-indices">0</div>
    </div>
    <div class="card">
      <div class="card-title">Total Documents</div>
      <div class="card-value" id="stat-docs">0</div>
    </div>
    <div class="card">
      <div class="card-title">Segments</div>
      <div class="card-value" id="stat-segments">0</div>
    </div>
    <div class="card">
      <div class="card-title">Engine Version</div>
      <div class="card-value">1.0.0</div>
    </div>
  </div>

  <div class="section-title">Search Playground</div>
  <div class="search-bar">
    <input type="text" id="query-input" placeholder="Type query (e.g. title:fast OR vector database)..." value="*">
    <button onclick="executeSearch()">Search</button>
  </div>

  <div class="results-panel">
    <div class="section-title" style="margin-bottom: 12px;">Hits & Results</div>
    <div id="results-container">
      <div style="color: var(--text-muted); font-size: 14px;">Execute a search query above to inspect matching documents and BM25 scores.</div>
    </div>
  </div>

  <div class="section-title" style="margin-top: 32px;">Active Collections</div>
  <div class="card" style="padding: 0;">
    <table>
      <thead>
        <tr>
          <th>INDEX NAME</th>
          <th>DOCUMENTS</th>
          <th>SEGMENTS</th>
        </tr>
      </thead>
      <tbody id="indices-table-body">
        <tr>
          <td colspan="3" style="text-align: center; color: var(--text-muted);">No indices found.</td>
        </tr>
      </tbody>
    </table>
  </div>

  <script>
    async function refreshStats() {
      try {
        const res = await fetch('/_cat/indices');
        const data = await res.json();
        const indices = data.indices || [];
        document.getElementById('stat-indices').innerText = indices.length;
        var totalDocs = 0;
        var totalSegs = 0;
        const tbody = document.getElementById('indices-table-body');
        if (indices.length > 0) {
          tbody.innerHTML = '';
          indices.forEach(idx => {
            totalDocs += idx.doc_count || 0;
            totalSegs += idx.segment_count || 0;
            const tr = document.createElement('tr');
            tr.innerHTML = `<td><b>\${idx.name}</b></td><td>\${idx.doc_count}</td><td>\${idx.segment_count}</td>`;
            tbody.appendChild(tr);
          });
        }
        document.getElementById('stat-docs').innerText = totalDocs;
        document.getElementById('stat-segments').innerText = totalSegs;
      } catch (err) {
        console.error(err);
      }
    }

    async function executeSearch() {
      const q = document.getElementById('query-input').value;
      const resContainer = document.getElementById('results-container');
      try {
        const indicesRes = await fetch('/_cat/indices');
        const indData = await indicesRes.json();
        const indices = indData.indices || [];
        if (indices.length === 0) {
          resContainer.innerHTML = '<div style="color: var(--text-muted);">No active indices available to query.</div>';
          return;
        }
        const targetIndex = indices[0].name;
        const searchRes = await fetch('/' + targetIndex + '/_search', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ query: q, size: 10 })
        });
        const results = await searchRes.json();
        const hits = (results.hits && results.hits.hits) || [];
        if (hits.length === 0) {
          resContainer.innerHTML = '<div style="color: var(--text-muted);">No documents matched query.</div>';
          return;
        }
        resContainer.innerHTML = '';
        hits.forEach(h => {
          const div = document.createElement('div');
          div.className = 'hit-item';
          div.innerHTML = `
            <div class="hit-header">
              <span class="hit-id">\${h._id}</span>
              <span class="hit-score">Score: \${h._score.toFixed(4)}</span>
            </div>
            <div class="hit-body">\${JSON.stringify(h._source)}</div>
          `;
          resContainer.appendChild(div);
        });
      } catch (err) {
        resContainer.innerHTML = '<div style="color: #ef4444;">Search error: ' + err.message + '</div>';
      }
    }

    refreshStats();
  </script>
</body>
</html>
''';
}
