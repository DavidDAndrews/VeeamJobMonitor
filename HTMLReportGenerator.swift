import Foundation

// MARK: - HTML Report Generator

/// Builds the standalone HTML backup report from already-fetched job/log data.
/// This type owns all of the pure HTML-string assembly; the view keeps only the
/// orchestration (config/log loading, file writing, share/open panels, progress).
struct HTMLReportGenerator {
    struct JobContext {
        let job: VeeamJob
        let summary: JobRunLogSummary?
    }

    let serverDisplayName: String
    let jobsCount: Int

    func makeHTML(contexts: [JobContext]) -> String {
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let reportTitle = "VEEAM JOB MONITOR - BACKUP REPORT (\(serverDisplayName))"
        let logoMarkup = htmlReportLogoMarkup()
        let jobsSortedForReport = contexts.sorted { ($0.job.lastRun ?? .distantPast) > ($1.job.lastRun ?? .distantPast) }
        let kpi = makeKPISummaryHTML(contexts: contexts)
        let jobRows = jobsSortedForReport.map { context in
            let job = context.job
            let statusClass = reportStatusClass(for: job)
            let totalBytes = job.backupPoints.reduce(Int64(0)) { $0 + max($1.backupSizeBytes ?? 0, 0) }
            let runtimeText = formatRuntimeForReport(job: job, summary: context.summary)
            let throughput = rawThroughputForReport(job: job, summary: context.summary)
            return """
              <tr data-job-key="\(escapeHTML(job.id))" data-job-name="\(escapeHTML(job.displayName))">
                <td><a href="#" class="job-link" data-job-key="\(escapeHTML(job.id))">\(escapeHTML(job.displayName))</a></td>
                <td>\(escapeHTML(job.jobType))</td>
                <td>\(escapeHTML(job.repositoryName ?? "—"))</td>
                <td class="num" data-sort-number="\(totalBytes)">\(escapeHTML(job.totalStorageUsedText ?? "—"))</td>
                <td><span class="pill pill-\(statusClass)">\(escapeHTML(job.resultText))</span></td>
                <td>\(escapeHTML(job.status ?? "Unknown"))</td>
                <td>\(escapeHTML(runtimeText))</td>
                <td class="num" data-sort-number="\(throughput.sortValue)" style="color:\(throughput.colorHex);font-weight:600;">\(escapeHTML(throughput.text))</td>
                <td>\(escapeHTML(job.lastRun.map { DetailDateFormatter.shared.string(from: $0) } ?? "—"))</td>
                <td>\(escapeHTML(job.nextRun.map { DetailDateFormatter.shared.string(from: $0) } ?? (job.scheduleDescription ?? "—")))</td>
                <td class="num">\(job.backupPoints.count)</td>
              </tr>
            """
        }.joined(separator: "\n")

        let groupedSections = jobsSortedForReport.map { context in
            let job = context.job
            let groups = Dictionary(grouping: job.backupPoints) { $0.backupSetName ?? "UnknownBackupSet.VBM" }
            let sortedGroups = groups.map { key, points in
                (key: key, points: points.sorted(by: { $0.creationTime > $1.creationTime }))
            }.sorted { lhs, rhs in
                let lhsNewest = lhs.points.first?.creationTime ?? .distantPast
                let rhsNewest = rhs.points.first?.creationTime ?? .distantPast
                return lhsNewest > rhsNewest
            }

            let groupHTML = sortedGroups.enumerated().map { index, group in
                let groupId = "job\(job.id.htmlIDSafe)-group\(index)"
                let machineName = group.points.first?.name ?? group.key.replacingOccurrences(of: "\\.[Vv][Bb][Mm]$", with: "", options: .regularExpression)
                let startDate = group.points.map(\.creationTime).min() ?? .distantPast
                let endDate = group.points.map(\.creationTime).max() ?? .distantPast
                let headerText = "\(machineName) - (\(htmlGroupDateString(from: startDate)) --> \(htmlGroupDateString(from: endDate))) - \(group.points.count) Restore Points"

                let rows = group.points.map { point in
                    let rpRowClass: String
                    switch point.type.replacingOccurrences(of: " ", with: "").lowercased() {
                    case "full", "syntheticfull":
                        rpRowClass = "rp-full"
                    case "increment", "incremental", "reverseincrement":
                        rpRowClass = "rp-incremental"
                    default:
                        rpRowClass = ""
                    }
                    let gfs = point.gfsText ?? "—"
                    let retentionCell: String = (gfs == "R" || gfs == "—")
                        ? "<td>\(escapeHTML(gfs))</td>"
                        : "<td><span class=\"badge badge-gfs\">\(escapeHTML(gfs))</span></td>"
                    let expirationText = point.expirationText
                    let expirationCell: String
                    if expirationText.lowercased().hasPrefix("immutable") {
                        expirationCell = "<td><span class=\"badge badge-immutable\">\(escapeHTML(expirationText))</span></td>"
                    } else if expirationText == "GFS Retained" {
                        expirationCell = "<td><span class=\"badge badge-gfs\">\(escapeHTML(expirationText))</span></td>"
                    } else {
                        expirationCell = "<td>\(escapeHTML(expirationText))</td>"
                    }
                    return """
                    <tr class="\(rpRowClass)">
                      <td>\(escapeHTML(point.name))</td>
                      <td data-sort-number="\(Int(point.creationTime.timeIntervalSince1970))">\(escapeHTML(BackupPointDateFormatter.shared.string(from: point.creationTime)))</td>
                      <td class="num" data-sort-number="\(point.backupSizeBytes ?? -1)">\(escapeHTML(point.backupSizeText))</td>
                      <td>\(escapeHTML(point.type))</td>
                      <td>\(escapeHTML(point.status))</td>
                      \(retentionCell)
                      \(expirationCell)
                      <td>\(escapeHTML(point.repositoryName ?? "—"))</td>
                    </tr>
                    """
                }.joined(separator: "\n")

                return """
                <details class="vbm-group" open>
                  <summary><span class="expander" aria-hidden="true">+</span>\(escapeHTML(headerText))</summary>
                  <div class="table-wrap">
                    <table class="sortable rp-table" id="\(groupId)">
                      <thead>
                        <tr>
                          <th scope="col" data-type="text">Recovery Point</th>
                          <th scope="col" data-type="number">Date</th>
                          <th scope="col" class="num" data-type="number">Backup Size</th>
                          <th scope="col" data-type="text">Type</th>
                          <th scope="col" data-type="text">Status</th>
                          <th scope="col" data-type="text">Retention</th>
                          <th scope="col" data-type="text">Expiration</th>
                          <th scope="col" data-type="text">Repository</th>
                        </tr>
                      </thead>
                      <tbody>
                        \(rows)
                      </tbody>
                    </table>
                  </div>
                </details>
                """
            }.joined(separator: "\n")

            let runtimeText = formatRuntimeForReport(job: job, summary: context.summary)
            let throughput = rawThroughputForReport(job: job, summary: context.summary)
            let processedSizeText = reportByteCountText(job.processedSizeBytes)
            let readSizeText = reportByteCountText(job.readSizeBytes)
            let transferredSizeText = reportByteCountText(job.transferredSizeBytes)
            let logSummaryCards = makeLogSummaryCardsHTML(for: context)
            let logMessages = makeLogMessagesHTML(for: context)

            return """
            <details class="job-group" data-job-key="\(escapeHTML(job.id))" data-job-name="\(escapeHTML(job.displayName))">
              <summary><span class="expander" aria-hidden="true">+</span>\(escapeHTML(job.displayName)) • \(escapeHTML(job.jobType)) • \(job.backupPoints.count) Restore Points</summary>
              <div class="job-meta">
                Repository: <strong>\(escapeHTML(job.repositoryName ?? "—"))</strong> |
                Total Storage Used: <strong>\(escapeHTML(job.totalStorageUsedText ?? "—"))</strong> |
                Last Result: <strong>\(escapeHTML(job.resultText))</strong> |
                Status: <strong>\(escapeHTML(job.status ?? "Unknown"))</strong>
              </div>
              <div class="status-cards-grid">
                <div class="status-card">
                  <div class="status-card-title">Job Runtime</div>
                  <div class="status-card-value">\(escapeHTML(runtimeText))</div>
                </div>
                <div class="status-card">
                  <div class="status-card-title">Processing Rate</div>
                  <div class="status-card-value" style="color:\(throughput.colorHex);">\(escapeHTML(throughput.text))</div>
                </div>
                <div class="status-card">
                  <div class="status-card-title">Processed Size</div>
                  <div class="status-card-value">\(escapeHTML(processedSizeText))</div>
                </div>
                <div class="status-card">
                  <div class="status-card-title">Read Size</div>
                  <div class="status-card-value">\(escapeHTML(readSizeText))</div>
                </div>
                <div class="status-card">
                  <div class="status-card-title">Transferred Size</div>
                  <div class="status-card-value">\(escapeHTML(transferredSizeText))</div>
                </div>
                \(logSummaryCards)
              </div>
              \(logMessages)
              \(groupHTML.isEmpty ? "<div class=\"empty\">No backup points for this job.</div>" : groupHTML)
            </details>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Veeam Backup Report</title>
          <style>
            :root {
              --brand: \(Theme.Hex.brand);
              --brand-dark: \(Theme.Hex.brandDark);
              --running: \(Theme.Hex.running);
              --success: \(Theme.Hex.success);
              --warning: \(Theme.Hex.warning);
              --failed: \(Theme.Hex.failed);
              --disabled: \(Theme.Hex.disabled);
              --unknown: \(Theme.Hex.unknown);
              --surface: #ffffff;
              --surface-2: #f8fafc;
              --surface-3: #eef2f7;
              --border: #e2e8f0;
              --border-strong: #cbd5e1;
              --text: #0f172a;
              --text-2: #475569;
              --text-3: #64748b;
              --shadow: 0 4px 20px rgba(15,23,42,.08);
            }
            * { box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 24px; background:var(--surface-2); color:var(--text); -webkit-font-smoothing:antialiased; }
            .card { background:var(--surface); border:1px solid var(--border); border-radius:16px; padding:20px; box-shadow:var(--shadow); margin-bottom:18px; }
            h1 { margin:0 0 8px; font-size:22px; letter-spacing:-.2px; }
            .meta { color:var(--text-2); margin-bottom:0; font-size:13px; }
            .search-toolbar { display:flex; flex-wrap:wrap; align-items:center; gap:12px; margin:14px 0 16px; }
            .search-field { flex:1 1 260px; display:flex; align-items:center; gap:8px; background:var(--surface-2); border:1px solid var(--border); border-radius:10px; padding:8px 12px; transition:border-color .15s, box-shadow .15s; }
            .search-field:focus-within { border-color:var(--brand); box-shadow:0 0 0 3px color-mix(in srgb, var(--brand) 18%, transparent); }
            .search-icon { color:var(--text-3); font-size:16px; line-height:1; flex:0 0 auto; }
            .search-field input { flex:1 1 auto; border:none; background:transparent; font-size:14px; color:var(--text); outline:none; min-width:0; font-family:inherit; }
            .search-field input::placeholder { color:var(--text-3); }
            .search-field input::-webkit-search-cancel-button { cursor:pointer; }
            .search-count { font-size:13px; color:var(--text-2); white-space:nowrap; }
            .search-count strong { color:var(--text); font-weight:800; }
            .search-empty { display:none; padding:16px; text-align:center; color:var(--text-3); font-size:13px; border:1px dashed var(--border); border-radius:10px; margin-bottom:12px; background:var(--surface-2); }
            .search-empty.visible { display:block; }
            .job-link { color:var(--running); text-decoration:none; font-weight:700; cursor:pointer; }
            .job-link:hover { text-decoration:underline; }

            /* Header band */
            .report-banner { background:linear-gradient(135deg, var(--brand), var(--brand-dark)); border-radius:16px; padding:22px 24px; margin-bottom:18px; display:flex; align-items:center; gap:18px; box-shadow:var(--shadow); color:#fff; }
            .report-logo { width:72px; height:72px; flex:0 0 auto; display:flex; align-items:center; justify-content:center; background:rgba(255,255,255,.14); border:1px solid rgba(255,255,255,.30); border-radius:18px; padding:8px; }
            .report-logo svg, .report-logo img { width:100%; height:100%; object-fit:contain; }
            .report-banner-text { flex:1 1 auto; min-width:0; }
            .report-title { font-size:24px; font-weight:800; margin:0; color:#fff; }
            .report-sub { margin-top:6px; font-size:13px; color:rgba(255,255,255,.92); }
            .report-credit { margin-top:4px; font-size:11px; color:rgba(255,255,255,.78); font-weight:600; }

            /* KPI summary */
            .kpi-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:16px; }
            .kpi { background:var(--surface); border:1px solid var(--border); border-radius:14px; padding:14px 16px; box-shadow:var(--shadow); }
            .kpi-label { font-size:11px; text-transform:uppercase; letter-spacing:.5px; color:var(--text-3); font-weight:700; margin-bottom:6px; display:flex; align-items:center; gap:6px; }
            .kpi-value { font-size:24px; font-weight:800; color:var(--text); line-height:1.1; }
            .kpi .dot { width:9px; height:9px; border-radius:50%; display:inline-block; }
            .kpi-running .kpi-value { color:var(--running); }  .kpi-running .dot { background:var(--running); }
            .kpi-success .kpi-value { color:var(--success); }  .kpi-success .dot { background:var(--success); }
            .kpi-warning .kpi-value { color:var(--warning); }  .kpi-warning .dot { background:var(--warning); }
            .kpi-failed  .kpi-value { color:var(--failed);  }  .kpi-failed  .dot { background:var(--failed); }
            .kpi-disabled .kpi-value { color:var(--disabled); } .kpi-disabled .dot { background:var(--disabled); }

            /* Status mix bar */
            .mix-bar { display:flex; height:14px; border-radius:999px; overflow:hidden; margin:4px 0 18px; border:1px solid var(--border); background:var(--surface-3); }
            .mix-seg { height:100%; }
            .mix-seg.success { background:var(--success); }
            .mix-seg.warning { background:var(--warning); }
            .mix-seg.failed { background:var(--failed); }
            .mix-seg.running { background:var(--running); }
            .mix-seg.disabled { background:var(--disabled); }
            .mix-legend { display:flex; flex-wrap:wrap; gap:14px; font-size:12px; color:var(--text-2); margin-bottom:4px; }
            .mix-legend span { display:inline-flex; align-items:center; gap:6px; }

            /* Pills */
            .pill { display:inline-block; font-size:12px; font-weight:700; padding:3px 10px; border-radius:999px; white-space:nowrap; }
            .pill-running  { color:var(--running);  background:color-mix(in srgb, var(--running) 14%, transparent); }
            .pill-success  { color:var(--success);  background:color-mix(in srgb, var(--success) 14%, transparent); }
            .pill-warning  { color:var(--warning);  background:color-mix(in srgb, var(--warning) 16%, transparent); }
            .pill-failed   { color:var(--failed);   background:color-mix(in srgb, var(--failed) 14%, transparent); }
            .pill-disabled { color:var(--disabled); background:color-mix(in srgb, var(--disabled) 16%, transparent); }
            .pill-unknown  { color:var(--unknown);  background:color-mix(in srgb, var(--unknown) 14%, transparent); }
            .badge { display:inline-block; font-size:11px; font-weight:700; padding:2px 8px; border-radius:6px; }
            .badge-gfs { color:var(--running); background:color-mix(in srgb, var(--running) 12%, transparent); }
            .badge-immutable { color:var(--brand); background:color-mix(in srgb, var(--brand) 14%, transparent); }

            /* Tables */
            .table-scroll { overflow-x:auto; }
            table { width:100%; border-collapse:collapse; font-size:13px; background:var(--surface); }
            th, td { border:1px solid var(--border); padding:8px 11px; text-align:left; }
            td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; }
            thead th { position:sticky; top:0; z-index:2; background:var(--surface-3); font-weight:700; cursor:pointer; user-select:none; color:var(--text-2); }
            th.sort-asc::after { content:" ▲"; color:var(--brand); }
            th.sort-desc::after { content:" ▼"; color:var(--brand); }
            tbody tr:nth-child(even) { background:var(--surface-2); }
            tbody tr:hover { background:color-mix(in srgb, var(--brand) 7%, transparent); }
            .rp-table tr.rp-full td { background:color-mix(in srgb, var(--success) 9%, transparent); }
            .rp-table tr.rp-incremental td { background:color-mix(in srgb, var(--running) 7%, transparent); }

            /* Disclosure groups */
            .job-group, .vbm-group { border:1px solid var(--border-strong); border-radius:12px; margin-bottom:10px; background:var(--surface); overflow:hidden; }
            .job-group > summary, .vbm-group > summary { list-style:none; cursor:pointer; padding:11px 13px; font-weight:800; display:flex; align-items:center; gap:8px; color:#fff; }
            .job-group > summary { background:var(--brand); }
            .vbm-group > summary { background:var(--brand-dark); }
            .job-group > summary::-webkit-details-marker, .vbm-group > summary::-webkit-details-marker { display:none; }
            summary:focus-visible { outline:2px solid #fff; outline-offset:-3px; }
            .expander { width:14px; display:inline-block; text-align:center; font-weight:900; }
            .job-meta { padding:10px 13px; color:var(--text-2); font-size:13px; border-top:1px solid var(--border); border-bottom:1px solid var(--border); background:var(--surface-2); }
            .status-cards-grid { display:grid; grid-template-columns: repeat(auto-fit,minmax(220px,1fr)); gap:10px; padding:10px; background:var(--surface-2); border-bottom:1px solid var(--border); }
            .status-card { background:var(--surface); border:1px solid var(--border); border-radius:10px; padding:10px 12px; }
            .status-card-title { font-size:11px; text-transform:uppercase; letter-spacing:.4px; color:var(--text-3); margin-bottom:4px; font-weight:700; }
            .status-card-value { font-size:14px; font-weight:700; color:var(--text); }
            .log-summary-row { display:flex; flex-wrap:wrap; gap:8px; }
            .log-pill { font-size:12px; font-weight:700; padding:4px 8px; border-radius:999px; }
            .log-pill-success { color:var(--success); background:color-mix(in srgb, var(--success) 14%, transparent); }
            .log-pill-warning { color:var(--warning); background:color-mix(in srgb, var(--warning) 16%, transparent); }
            .log-pill-retry { color:var(--running); background:color-mix(in srgb, var(--running) 14%, transparent); }
            .log-pill-failed { color:var(--failed); background:color-mix(in srgb, var(--failed) 14%, transparent); }
            .log-messages { padding:10px; background:var(--surface-2); border-bottom:1px solid var(--border); }
            .log-line { display:flex; gap:8px; border-bottom:1px solid var(--border); padding:6px 0; align-items:flex-start; font-size:12px; }
            .log-line:last-child { border-bottom:none; }
            .log-time { color:var(--text-3); min-width:132px; font-weight:600; }
            .log-level { min-width:54px; font-weight:700; }
            .log-level-success { color:var(--success); }
            .log-level-warning { color:var(--warning); }
            .log-level-retry { color:var(--running); }
            .log-level-failed { color:var(--failed); }
            .log-level-info { color:var(--text-2); }
            .table-wrap { padding:10px; }
            .empty { padding:12px; color:var(--text-3); font-size:13px; }

            @media (prefers-color-scheme: dark) {
              :root {
                --surface:#1e242c; --surface-2:#161b22; --surface-3:#262d36;
                --border:#2d3742; --border-strong:#3a4654;
                --text:#e6edf3; --text-2:#aeb9c5; --text-3:#8b97a4;
                --shadow:0 4px 20px rgba(0,0,0,.45);
              }
              body { background:#0d1117; }
              .mix-bar { background:var(--surface-3); }
            }

            @media print {
              body { padding:0; background:#fff; }
              .card, .kpi, .report-banner { box-shadow:none; }
              .report-banner { -webkit-print-color-adjust:exact; print-color-adjust:exact; }
              .pill, .badge, .mix-seg, .job-group > summary, .vbm-group > summary, thead th { -webkit-print-color-adjust:exact; print-color-adjust:exact; }
              details { break-inside:avoid; }
              tr, .kpi { break-inside:avoid; }
              thead th { position:static; }
              .job-link { color:var(--text); text-decoration:none; }
              .search-toolbar, .search-empty { display:none; }
            }
          </style>
        </head>
        <body>
          <div class="report-banner">
            <div class="report-logo">\(logoMarkup)</div>
            <div class="report-banner-text">
              <h1 class="report-title">\(escapeHTML(reportTitle))</h1>
              <div class="report-sub">Server: <strong>\(escapeHTML(serverDisplayName))</strong> &nbsp;•&nbsp; Generated: \(escapeHTML(now)) &nbsp;•&nbsp; Jobs: \(jobsCount)</div>
              <div class="report-credit">David Andrews © 2026  All rights reserved.</div>
            </div>
          </div>
          <div class="card">
            \(kpi)
          </div>
          <div class="card">
            <h1>Jobs Overview</h1>
            <div class="meta">Click a job name to jump to its restore points. Click any column header to sort.</div>
            <div class="search-toolbar">
              <label class="search-field" for="job-search-input">
                <span class="search-icon" aria-hidden="true">⌕</span>
                <input type="search" id="job-search-input" placeholder="Search jobs by name..." autocomplete="off" spellcheck="false">
              </label>
              <div class="search-count" id="job-search-count"><strong>\(jobsCount)</strong> jobs</div>
            </div>
            <div class="search-empty" id="job-search-empty">No jobs match your search.</div>
            <div class="table-scroll">
            <table class="sortable" id="jobs-summary-table">
              <thead>
                <tr>
                  <th scope="col" data-type="text">Job Name</th>
                  <th scope="col" data-type="text">Type</th>
                  <th scope="col" data-type="text">Repository</th>
                  <th scope="col" class="num" data-type="number">Total Storage Used</th>
                  <th scope="col" data-type="text">Last Result</th>
                  <th scope="col" data-type="text">Job Status</th>
                  <th scope="col" data-type="text">Job Runtime</th>
                  <th scope="col" class="num" data-type="number">Raw Throughput</th>
                  <th scope="col" data-type="text">Last Run</th>
                  <th scope="col" data-type="text">Next Run</th>
                  <th scope="col" class="num" data-type="number">RP Count</th>
                </tr>
              </thead>
              <tbody>
                \(jobRows)
              </tbody>
            </table>
            </div>
          </div>
          <div class="card" id="rp-grouping-card">
            <h1>Restore Points by Job / VBM Group</h1>
            <div id="job-groups-container">
              \(groupedSections)
            </div>
          </div>
          <script>
            document.querySelectorAll('details').forEach(d => {
              const summary = d.querySelector('summary');
              const s = d.querySelector('summary .expander');
              const setMark = () => {
                if (s) s.textContent = d.open ? '−' : '+';
                if (summary) summary.setAttribute('aria-expanded', d.open ? 'true' : 'false');
              };
              setMark();
              d.addEventListener('toggle', setMark);
            });

            const jobSearchInput = document.getElementById('job-search-input');
            const jobSearchCount = document.getElementById('job-search-count');
            const jobSearchEmpty = document.getElementById('job-search-empty');
            const jobsSummaryBody = document.querySelector('#jobs-summary-table tbody');
            const jobGroupsContainer = document.getElementById('job-groups-container');

            function jobDisplayNameForFilter(node) {
              return (node.getAttribute('data-job-name') || '').trim().toLowerCase();
            }

            function filterJobsBySearch(rawQuery) {
              const query = (rawQuery || '').trim().toLowerCase();
              const summaryRows = jobsSummaryBody
                ? Array.from(jobsSummaryBody.querySelectorAll('tr[data-job-key]'))
                : [];
              const jobGroups = jobGroupsContainer
                ? Array.from(jobGroupsContainer.querySelectorAll('details.job-group[data-job-key]'))
                : [];
              let visibleCount = 0;

              summaryRows.forEach(row => {
                const matches = !query || jobDisplayNameForFilter(row).includes(query);
                row.hidden = !matches;
                if (matches) visibleCount += 1;
              });

              jobGroups.forEach(group => {
                const matches = !query || jobDisplayNameForFilter(group).includes(query);
                group.hidden = !matches;
              });

              if (jobSearchCount) {
                const total = summaryRows.length;
                if (query) {
                  jobSearchCount.innerHTML = 'Showing <strong>' + visibleCount + '</strong> of <strong>' + total + '</strong> jobs';
                } else {
                  jobSearchCount.innerHTML = '<strong>' + total + '</strong> jobs';
                }
              }

              if (jobSearchEmpty) {
                jobSearchEmpty.classList.toggle('visible', query.length > 0 && visibleCount === 0);
              }
            }

            if (jobSearchInput) {
              jobSearchInput.addEventListener('input', () => filterJobsBySearch(jobSearchInput.value));
              jobSearchInput.addEventListener('search', () => filterJobsBySearch(jobSearchInput.value));
            }

            document.querySelectorAll('.job-link[data-job-key]').forEach(link => {
              link.addEventListener('click', (event) => {
                event.preventDefault();
                const key = link.getAttribute('data-job-key');
                if (!key) return;
                const targetGroup = document.querySelector('#job-groups-container details.job-group[data-job-key=\"' + CSS.escape(key) + '\"]');
                if (!targetGroup) return;
                targetGroup.open = true;
                targetGroup.querySelectorAll('details.vbm-group').forEach(vbm => { vbm.open = true; });
                targetGroup.scrollIntoView({ behavior: 'smooth', block: 'start' });
              });
            });

            document.querySelectorAll('table.sortable').forEach(table => {
              const headers = table.querySelectorAll('th');
              const tbody = table.querySelector('tbody');
              if (!tbody) return;
              headers.forEach((th, idx) => {
                th.addEventListener('click', () => {
                  const current = th.dataset.sortDir === 'asc' ? 'asc' : (th.dataset.sortDir === 'desc' ? 'desc' : '');
                  const next = current === 'asc' ? 'desc' : 'asc';
                  headers.forEach(h => { h.dataset.sortDir = ''; h.classList.remove('sort-asc', 'sort-desc'); });
                  th.dataset.sortDir = next;
                  th.classList.add(next === 'asc' ? 'sort-asc' : 'sort-desc');

                  const rows = Array.from(tbody.querySelectorAll('tr[data-job-key]'));
                  rows.sort((a, b) => {
                    const aCell = a.children[idx];
                    const bCell = b.children[idx];
                    const aNum = aCell.getAttribute('data-sort-number');
                    const bNum = bCell.getAttribute('data-sort-number');
                    let cmp = 0;
                    if (aNum !== null && bNum !== null) {
                      cmp = Number(aNum) - Number(bNum);
                    } else {
                      cmp = aCell.textContent.localeCompare(bCell.textContent, undefined, { numeric: true, sensitivity: 'base' });
                    }
                    return next === 'asc' ? cmp : -cmp;
                  });
                  rows.forEach(r => tbody.appendChild(r));

                  if (table.id === 'jobs-summary-table') {
                    syncJobGroupOrderToSummary(tbody);
                  }
                });
              });
            });

            function syncJobGroupOrderToSummary(summaryBody) {
              const groupsContainer = document.getElementById('job-groups-container');
              if (!groupsContainer) return;
              const rows = Array.from(summaryBody.querySelectorAll('tr[data-job-key]'));
              const groupsByKey = new Map(
                Array.from(groupsContainer.querySelectorAll('details.job-group[data-job-key]'))
                  .map(group => [group.getAttribute('data-job-key'), group])
              );
              rows.forEach(row => {
                const key = row.getAttribute('data-job-key');
                const group = groupsByKey.get(key);
                if (group) {
                  groupsContainer.appendChild(group);
                }
              });
            }

            // Add native hover tooltips across report elements.
            const tooltipSelectors = [
              'h1', '.report-title', '.report-credit', '.meta',
              'summary', '.job-meta', '.status-card', '.status-card-title', '.status-card-value',
              '.job-link', '.log-pill', '.log-line', '.log-text', '.log-time', '.log-level',
              'th', 'td', '.empty'
            ];
            tooltipSelectors.forEach(selector => {
              document.querySelectorAll(selector).forEach(node => {
                if (node.hasAttribute('title')) return;
                const text = (node.textContent || '').replace(/\\s+/g, ' ').trim();
                if (!text) return;
                node.setAttribute('title', text);
              });
            });
          </script>
        </body>
        </html>
        """
    }

    private func reportStatusClass(for job: VeeamJob) -> String {
        switch jobResultBucket(for: job) {
        case .running: return "running"
        case .success: return "success"
        case .warning: return "warning"
        case .failed: return "failed"
        case .disabled: return "disabled"
        case .unknown: return "unknown"
        }
    }

    private func makeKPISummaryHTML(contexts: [JobContext]) -> String {
        let buckets = contexts.map { jobResultBucket(for: $0.job) }
        let running = buckets.filter { $0 == .running }.count
        let success = buckets.filter { $0 == .success }.count
        let warning = buckets.filter { $0 == .warning }.count
        let failed = buckets.filter { $0 == .failed }.count
        let disabled = buckets.filter { $0 == .disabled }.count
        let totalJobs = contexts.count

        let totalProtectedBytes = contexts.reduce(Int64(0)) { partial, context in
            partial + context.job.backupPoints.reduce(Int64(0)) { $0 + max($1.backupSizeBytes ?? 0, 0) }
        }
        let totalProtectedText = totalProtectedBytes > 0
            ? ByteCountFormatter.string(fromByteCount: totalProtectedBytes, countStyle: .file)
            : "—"

        let ratedRuns = success + warning + failed
        let successRateText = ratedRuns > 0
            ? "\(Int((Double(success) / Double(ratedRuns) * 100).rounded()))%"
            : "—"

        // CSS-only status-mix bar (no JS libs); widths normalized over rated runs.
        let mixDenominator = max(success + warning + failed + running + disabled, 1)
        func pct(_ value: Int) -> String { String(format: "%.4f", Double(value) / Double(mixDenominator) * 100) }
        let mixSegments = [
            (success, "success", "Success"),
            (warning, "warning", "Warning"),
            (failed, "failed", "Failed"),
            (running, "running", "Running"),
            (disabled, "disabled", "Disabled")
        ]
        let mixBar = mixSegments.filter { $0.0 > 0 }.map { count, klass, label in
            "<div class=\"mix-seg \(klass)\" style=\"width:\(pct(count))%\" title=\"\(label): \(count)\"></div>"
        }.joined()
        let mixLegend = mixSegments.map { count, klass, label in
            "<span><span style=\"width:9px;height:9px;border-radius:50%;display:inline-block;background:var(--\(klass))\"></span>\(label) \(count)</span>"
        }.joined(separator: "\n")

        return """
        <div class="kpi-grid">
          <div class="kpi">
            <div class="kpi-label">Total Jobs</div>
            <div class="kpi-value">\(totalJobs)</div>
          </div>
          <div class="kpi kpi-success">
            <div class="kpi-label"><span class="dot"></span>Success</div>
            <div class="kpi-value">\(success)</div>
          </div>
          <div class="kpi kpi-warning">
            <div class="kpi-label"><span class="dot"></span>Warning</div>
            <div class="kpi-value">\(warning)</div>
          </div>
          <div class="kpi kpi-failed">
            <div class="kpi-label"><span class="dot"></span>Failed</div>
            <div class="kpi-value">\(failed)</div>
          </div>
          <div class="kpi kpi-running">
            <div class="kpi-label"><span class="dot"></span>Running</div>
            <div class="kpi-value">\(running)</div>
          </div>
          <div class="kpi kpi-disabled">
            <div class="kpi-label"><span class="dot"></span>Disabled</div>
            <div class="kpi-value">\(disabled)</div>
          </div>
          <div class="kpi">
            <div class="kpi-label">Success Rate</div>
            <div class="kpi-value">\(successRateText)</div>
          </div>
          <div class="kpi">
            <div class="kpi-label">Protected Size</div>
            <div class="kpi-value">\(escapeHTML(totalProtectedText))</div>
          </div>
        </div>
        <div class="mix-legend">
          \(mixLegend)
        </div>
        <div class="mix-bar">
          \(mixBar)
        </div>
        """
    }

    private func makeLogSummaryCardsHTML(for context: JobContext) -> String {
        guard let summary = context.summary else {
            return """
            <div class="status-card">
              <div class="status-card-title">Latest Run Log Summary</div>
              <div class="status-card-value">No log data</div>
            </div>
            """
        }

        let success = summary.entries.filter { reportLogClass(for: $0) == "success" }.count
        let warning = summary.entries.filter { reportLogClass(for: $0) == "warning" }.count
        let retry = summary.entries.filter { reportLogClass(for: $0) == "retry" }.count
        let failed = summary.entries.filter { reportLogClass(for: $0) == "failed" }.count

        return """
        <div class="status-card">
          <div class="status-card-title">Session State</div>
          <div class="status-card-value">\(escapeHTML(summary.state.capitalized))</div>
        </div>
        <div class="status-card">
          <div class="status-card-title">Session Result</div>
          <div class="status-card-value">\(escapeHTML(summary.result.capitalized))</div>
        </div>
        <div class="status-card">
          <div class="status-card-title">Log Counters</div>
          <div class="log-summary-row">
            <span class="log-pill log-pill-success">Success \(success)</span>
            <span class="log-pill log-pill-warning">Warning \(warning)</span>
            <span class="log-pill log-pill-retry">Retry \(retry)</span>
            <span class="log-pill log-pill-failed">Failed \(failed)</span>
          </div>
        </div>
        """
    }

    private func makeLogMessagesHTML(for context: JobContext) -> String {
        guard let summary = context.summary, !summary.entries.isEmpty else { return "" }
        let lines = summary.entries.prefix(30).map { entry -> String in
            let klass = reportLogClass(for: entry)
            let timeText = (entry.updateTime ?? entry.startTime).map { DetailDateFormatter.shared.string(from: $0) } ?? "—"
            return """
            <div class="log-line">
              <div class="log-time">\(escapeHTML(timeText))</div>
              <div class="log-level log-level-\(klass)">\(klass.uppercased())</div>
              <div class="log-text">\(escapeHTML(entry.message))</div>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <div class="log-messages">
          \(lines)
        </div>
        """
    }

    private func reportLogClass(for entry: JobRunLogEntry) -> String {
        let source = "\(entry.status) \(entry.message)".lowercased()
        if source.contains("fail") || source.contains("error") { return "failed" }
        if source.contains("retry") { return "retry" }
        if source.contains("warning") || source.contains("rpo violation") { return "warning" }
        if source.contains("success") || source.contains("finished") || source.contains("processed") { return "success" }
        return "info"
    }

    private func formatRuntimeForReport(job: VeeamJob, summary: JobRunLogSummary?) -> String {
        let start: Date?
        let end: Date?
        if let summary {
            start = summary.startedAt
            end = summary.endedAt ?? (job.isRunning ? Date() : nil)
        } else {
            start = job.lastRun
            end = job.isRunning ? Date() : nil
        }
        guard let start else { return "—" }
        let duration = max((end ?? Date()).timeIntervalSince(start), 0)
        let totalMinutes = max(Int(duration / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours) \(hours == 1 ? "Hour" : "Hours") and \(minutes) \(minutes == 1 ? "Minute" : "Minutes") (\(totalMinutes) Mins)"
        }
        return "\(totalMinutes) \(totalMinutes == 1 ? "Minute" : "Minutes") (\(totalMinutes) Mins)"
    }

    private func rawThroughputForReport(job: VeeamJob, summary: JobRunLogSummary?) -> (text: String, colorHex: String, sortValue: Int64) {
        if let bps = job.processingRateBytesPerSecond, bps > 0 {
            return formatReportThroughput(bps)
        }

        if let transferred = job.transferredSizeBytes,
           transferred > 0,
           let duration = runtimeDurationForReport(job: job, summary: summary),
           duration > 0 {
            let bps = Double(transferred) / duration
            return formatReportThroughput(bps)
        }

        if let summary,
           let bps = throughputBytesPerSecondFromReportLogs(summary.entries) {
            return formatReportThroughput(bps)
        }

        guard let vmBytes = parsedVMSizeInBytesForReport(job.vmStorageSize) else {
            return ("—", Theme.Hex.unknown, -1)
        }

        let start: Date?
        let end: Date?
        if let summary {
            start = summary.startedAt
            end = summary.endedAt ?? (job.isRunning ? Date() : nil)
        } else {
            start = job.lastRun
            end = job.isRunning ? Date() : nil
        }
        guard let start else { return ("—", Theme.Hex.unknown, -1) }
        let seconds = max((end ?? Date()).timeIntervalSince(start), 1)
        let bps = Double(vmBytes) / seconds
        return formatReportThroughput(bps)
    }

    private func runtimeDurationForReport(job: VeeamJob, summary: JobRunLogSummary?) -> TimeInterval? {
        let start: Date?
        let end: Date?
        if let summary {
            start = summary.startedAt
            end = summary.endedAt ?? (job.isRunning ? Date() : nil)
        } else {
            start = job.lastRun
            end = job.isRunning ? Date() : nil
        }
        guard let start else { return nil }
        return max((end ?? Date()).timeIntervalSince(start), 0)
    }

    private func formatReportThroughput(_ bps: Double) -> (text: String, colorHex: String, sortValue: Int64) {
        let mbps = bps / 1_048_576

        let color = Theme.Hex.throughput(forMbps: mbps)

        let text: String
        if bps >= 1_073_741_824 {
            text = String(format: "%.2f GB/SEC", bps / 1_073_741_824)
        } else if bps >= 1_048_576 {
            text = String(format: "%.1f MB/SEC", bps / 1_048_576)
        } else {
            text = String(format: "%.0f KB/SEC", bps / 1024)
        }
        return (text, color, Int64(bps.rounded()))
    }

    private func throughputBytesPerSecondFromReportLogs(_ entries: [JobRunLogEntry]) -> Double? {
        var best: Double?
        for entry in entries {
            let source = entry.message.lowercased()
            guard let range = source.range(of: #"read at\s+([0-9]+(?:\.[0-9]+)?)\s*([kmg])b/s"#, options: .regularExpression) else {
                continue
            }
            let chunk = String(source[range])
            guard let match = chunk.range(of: #"([0-9]+(?:\.[0-9]+)?)\s*([kmg])b/s"#, options: .regularExpression) else {
                continue
            }
            let body = String(chunk[match])
            let parts = body.replacingOccurrences(of: "/s", with: "").split(separator: " ", omittingEmptySubsequences: true)
            if parts.count < 2 { continue }
            guard let value = Double(parts[0]) else { continue }
            let unitPrefix = parts[1].lowercased()
            let bps: Double
            if unitPrefix.hasPrefix("kb") {
                bps = value * 1024
            } else if unitPrefix.hasPrefix("mb") {
                bps = value * 1_048_576
            } else if unitPrefix.hasPrefix("gb") {
                bps = value * 1_073_741_824
            } else {
                continue
            }
            best = max(best ?? 0, bps)
        }
        return best
    }

    private func parsedVMSizeInBytesForReport(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        guard let n = parts.first, let value = Double(n) else { return nil }
        let unit = (parts.dropFirst().first.map(String.init) ?? "B").uppercased()
        let multiplier: Double
        switch unit {
        case "KB", "KIB": multiplier = 1_024
        case "MB", "MIB": multiplier = 1_048_576
        case "GB", "GIB": multiplier = 1_073_741_824
        case "TB", "TIB": multiplier = 1_099_511_627_776
        case "PB", "PIB": multiplier = 1_125_899_906_842_624
        default: multiplier = 1
        }
        let bytes = value * multiplier
        guard bytes.isFinite, bytes >= 0 else { return nil }
        return Int64(bytes.rounded())
    }

    private func reportByteCountText(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func htmlReportLogoMarkup() -> String {
        if let bundledURL = Bundle.main.url(forResource: "hit-logo", withExtension: "svg"),
           let bundledSVG = try? String(contentsOf: bundledURL, encoding: .utf8),
           !bundledSVG.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return makeLogoImageTag(from: bundledSVG)
        }

        if !Self.embeddedReportLogoSVG.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return makeLogoImageTag(from: Self.embeddedReportLogoSVG)
        }

        return "<div style=\"font-weight:800;color:#ffffff;font-size:42px;line-height:1;\">V</div>"
    }

    private func makeLogoImageTag(from svg: String) -> String {
        let cleaned = svg
            .replacingOccurrences(of: "<\\?xml[^>]*\\?>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<!DOCTYPE[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            return "<div style=\"font-weight:800;color:#ffffff;font-size:42px;line-height:1;\">V</div>"
        }
        let base64 = data.base64EncodedString()
        return "<img src=\"data:image/svg+xml;base64,\(base64)\" alt=\"Report Logo\" />"
    }

    private static let embeddedReportLogoSVG: String = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="Veeam report logo">
      <defs>
        <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#0F8A43"/>
          <stop offset="100%" stop-color="#0A6332"/>
        </linearGradient>
      </defs>
      <rect x="6" y="6" width="116" height="116" rx="24" fill="url(#g)"/>
      <circle cx="64" cy="64" r="40" fill="#ffffff" opacity="0.15"/>
      <path d="M38 44h14l12 33 12-33h14L69 92H59L38 44z" fill="#ffffff"/>
    </svg>
    """

    private func htmlGroupDateString(from date: Date) -> String {
        Self.htmlGroupDateFormatter.string(from: date).uppercased()
    }

    private static let htmlGroupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MMM-dd"
        return formatter
    }()

    private func escapeHTML(_ input: String) -> String {
        input.htmlEscaped
    }
}


// MARK: - HTML identifier helper

private extension String {
    var htmlIDSafe: String {
        lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    }
}
