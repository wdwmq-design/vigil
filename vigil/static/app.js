// VIGIL Scientific Workstation Client
// NASA JPL Solar System Dynamics-inspired scientific control interface.

let activeJobId = null;
let currentJobData = null;
let healthData = null;
let rawDetectionsList = [];
let selectedUploadFiles = [];
let selectedImportFile = null;

document.addEventListener("DOMContentLoaded", () => {
  setupNavigation();
  setupHealthCheck();
  setupJobHandlers();
  setupExecutionHandlers();
  setupCandidateFilters();
  loadCapabilitiesMatrix();
  loadSimulationTruth();
  loadSimulationMetadata();
  loadEvaluationMetrics();
  loadDemoManifest();
  loadJobsList();
});

// 1. Navigation (10 Modules + Capabilities)
function setupNavigation() {
  const navLinks = document.querySelectorAll(".nav-link-btn");
  navLinks.forEach(btn => {
    btn.addEventListener("click", () => {
      const viewId = btn.dataset.view;
      switchView(viewId);
    });
  });

  const trackingNavBtn = document.getElementById("trackingNavToExecBtn");
  if (trackingNavBtn) {
    trackingNavBtn.addEventListener("click", () => switchView("execution"));
  }

  const reportsNavBtn = document.getElementById("reportsNavToExecBtn");
  if (reportsNavBtn) {
    reportsNavBtn.addEventListener("click", () => switchView("execution"));
  }

  const refreshBtn = document.getElementById("refreshBtn");
  if (refreshBtn) {
    refreshBtn.addEventListener("click", () => {
      loadJobsList();
      if (activeJobId) loadJobDetails(activeJobId);
    });
  }
}

function switchView(viewName) {
  document.querySelectorAll(".nav-link-btn").forEach(el => {
    el.classList.toggle("active", el.dataset.view === viewName);
  });

  const views = {
    "overview": document.getElementById("viewOverview"),
    "image-analysis": document.getElementById("viewImageAnalysis"),
    "candidate-explorer": document.getElementById("viewCandidateExplorer"),
    "tracking": document.getElementById("viewTracking"),
    "trajectory-analysis": document.getElementById("viewTrajectoryAnalysis"),
    "simulation-lab": document.getElementById("viewSimulationLab"),
    "evaluation": document.getElementById("viewEvaluation"),
    "reports-export": document.getElementById("viewReportsExport"),
    "provenance": document.getElementById("viewProvenance"),
    "execution": document.getElementById("viewExecution"),
    "capabilities-matrix": document.getElementById("viewCapabilities"),
    "demonstration": document.getElementById("viewDemonstration")
  };

  Object.entries(views).forEach(([name, elem]) => {
    if (elem) elem.style.display = (name === viewName) ? "block" : "none";
  });
}

// 2. Health & MATLAB Verification Status
async function setupHealthCheck() {
  try {
    const res = await fetch("/health");
    healthData = await res.json();
    renderHealthStatus(healthData);
  } catch (err) {
    console.error("Health check failed:", err);
  }
}

function renderHealthStatus(data) {
  const pill = document.getElementById("sidebarGatePill");
  const bannerText = document.getElementById("gateBannerText");
  const backendBadge = document.getElementById("backendVersionBadge");

  backendBadge.textContent = `v${data.backend_version}-core`;

  if (data.matlab && data.matlab.installed) {
    pill.className = "gate-badge verified";
    pill.innerHTML = `● GATE A: MATLAB DETECTED (${escapeHtml(data.matlab.release || "ACTIVE")})`;
    bannerText.innerHTML = `MATLAB environment verified on host (${escapeHtml(data.matlab.release || "")}). Scientific algorithms execute locally.`;
  } else {
    pill.className = "gate-badge pending";
    pill.innerHTML = `● GATE A: MATLAB UNVERIFIED`;
    bannerText.innerHTML = `MATLAB executable not found on host. Mathematical engine execution is decoupled and awaiting Gate A verification.`;
  }
}

// 3. Job Handlers (Bundled Ingestion & Custom Upload)
function setupJobHandlers() {
  const stageBundled = async (btn) => {
    btn.disabled = true;
    btn.textContent = "Staging...";
    try {
      const res = await fetch("/jobs/bundled/synthetic", { method: "POST" });
      const data = await res.json();
      if (res.ok) {
        await loadJobsList();
        selectJob(data.job_id);
        switchView("image-analysis");
      } else {
        alert("Failed to stage synthetic dataset: " + JSON.stringify(data.detail));
      }
    } catch (e) {
      alert("Error staging bundled dataset: " + e.message);
    } finally {
      btn.disabled = false;
      btn.textContent = "Stage Bundled Dataset";
    }
  };

  const overviewStageBtn = document.getElementById("overviewStageBundledBtn");
  if (overviewStageBtn) overviewStageBtn.addEventListener("click", () => stageBundled(overviewStageBtn));

  // Custom upload form in Image Analysis
  const imgDropzone = document.getElementById("imgDropzone");
  const imgFileInput = document.getElementById("imgFileInput");
  const imgSubmitUploadBtn = document.getElementById("imgSubmitUploadBtn");
  const imgUploadStatus = document.getElementById("imgUploadStatus");

  if (imgDropzone && imgFileInput) {
    imgDropzone.addEventListener("click", () => imgFileInput.click());
    imgFileInput.addEventListener("change", (e) => {
      selectedUploadFiles = Array.from(e.target.files).filter(f => f.name.toLowerCase().endsWith(".bmp"));
      if (selectedUploadFiles.length === 0) {
        imgUploadStatus.innerHTML = `<span style="color: #DC2626;">No .bmp files selected.</span>`;
        imgSubmitUploadBtn.disabled = true;
        return;
      }
      imgUploadStatus.innerHTML = `<span style="color: #065F46; font-weight: 600;">${selectedUploadFiles.length} BMP frame(s) selected.</span>`;
      imgSubmitUploadBtn.disabled = false;
    });
  }

  const imgUploadForm = document.getElementById("imgUploadForm");
  if (imgUploadForm) {
    imgUploadForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      if (selectedUploadFiles.length === 0) return;

      imgSubmitUploadBtn.disabled = true;
      imgSubmitUploadBtn.textContent = "Validating...";
      imgUploadStatus.innerHTML = "Inspecting 8-bpp greyscale headers...";

      const formData = new FormData();
      selectedUploadFiles.forEach(f => formData.append("files", f));

      try {
        const res = await fetch("/jobs", { method: "POST", body: formData });
        const data = await res.json();
        if (res.ok) {
          imgUploadStatus.innerHTML = `<span style="color: #065F46;">Validated. Created job ${data.job_id}.</span>`;
          if (data.warnings && data.warnings.length > 0) {
            imgUploadStatus.innerHTML += `<div style="color: #D97706; margin-top: 2px;">⚠ ${data.warnings.join(" ")}</div>`;
          }
          await loadJobsList();
          selectJob(data.job_id);
          switchView("image-analysis");
        } else {
          const err = data.error || data.detail;
          imgUploadStatus.innerHTML = `<span style="color: #DC2626;">Validation error [${err.code || "FAIL"}]: ${escapeHtml(err.detail || err.reason || JSON.stringify(err))}</span>`;
        }
      } catch (err) {
        imgUploadStatus.innerHTML = `<span style="color: #DC2626;">Upload error: ${err.message}</span>`;
      } finally {
        imgSubmitUploadBtn.disabled = false;
        imgSubmitUploadBtn.textContent = "Validate & Ingest Stack";
      }
    });
  }

  // Import shipped baseline button
  const importShippedBtn = document.getElementById("importShippedBaselineBtn");
  if (importShippedBtn) {
    importShippedBtn.addEventListener("click", async () => {
      if (!activeJobId) return;
      importShippedBtn.disabled = true;
      importShippedBtn.textContent = "Importing reference baseline...";
      try {
        const res = await fetch(`/jobs/${activeJobId}/import-shipped-baseline`, { method: "POST" });
        if (res.ok) {
          await loadJobDetails(activeJobId);
          await loadJobsList();
          switchView("candidate-explorer");
        } else {
          alert("Baseline import error");
        }
      } catch (err) {
        alert("Import error: " + err.message);
      } finally {
        importShippedBtn.disabled = false;
        importShippedBtn.textContent = "Import Shipped Baseline Run";
      }
    });
  }
}

// 4. Job List Rendering (Technical Table)
async function loadJobsList() {
  try {
    const res = await fetch("/jobs");
    const data = await res.json();
    const jobs = data.jobs || [];

    renderOverviewJobsTable(jobs);
    if (!activeJobId && jobs.length > 0) {
      selectJob(jobs[0].job_id);
    }
  } catch (err) {
    console.error("Failed to load jobs:", err);
  }
}

function renderOverviewJobsTable(jobs) {
  const overviewTbody = document.getElementById("overviewJobsTableBody");
  const countBadge = document.getElementById("overviewJobCount");
  if (countBadge) countBadge.textContent = `${jobs.length} Job${jobs.length === 1 ? "" : "s"}`;

  if (!overviewTbody) return;
  if (jobs.length === 0) {
    overviewTbody.innerHTML = `<tr><td colspan="4" style="text-align: center; color: var(--text-muted); padding: 12px;">No jobs staged.</td></tr>`;
    return;
  }

  overviewTbody.innerHTML = jobs.map(j => {
    const isSynthetic = j.dataset_kind === "synthetic_bundled";
    const kindBadge = isSynthetic
      ? `<span class="sci-badge sci-badge-synthetic">SYNTHETIC</span>`
      : `<span class="sci-badge sci-badge-upload">UPLOAD</span>`;

    const stateClass = {
      validated: "sci-badge-upload",
      awaiting_matlab: "sci-badge-warning",
      running: "sci-badge-warning",
      completed: "sci-badge-success",
      completed_empty: "sci-badge-upload",
      imported: "sci-badge-success",
      failed: "sci-badge-danger"
    }[j.state] || "sci-badge-upload";

    return `
      <tr>
        <td class="mono-cell" style="font-weight: 600;">${escapeHtml(j.job_id)}</td>
        <td>${kindBadge}</td>
        <td><span class="sci-badge ${stateClass}">${j.state.toUpperCase()}</span></td>
        <td>
          <button class="sci-btn sci-btn-sm" onclick="selectJob('${j.job_id}')">Open</button>
        </td>
      </tr>
    `;
  }).join("");
}

// 5. Job Selection & Details
async function selectJob(jobId) {
  activeJobId = jobId;
  document.getElementById("activeJobLabel").textContent = jobId;
  await loadJobDetails(jobId);
}

async function loadJobDetails(jobId) {
  try {
    const res = await fetch(`/jobs/${jobId}`);
    if (!res.ok) return;
    const data = await res.json();
    currentJobData = data;
    renderJobDetails(data);
  } catch (err) {
    console.error("Failed to load job details:", err);
  }
}

function renderJobDetails(data) {
  const { job, status, results } = data;

  // Header active job badge
  const badge = document.getElementById("activeJobBadge");
  badge.style.display = "inline-block";
  badge.className = `sci-badge ${status.state === "completed" || status.state === "imported" ? "sci-badge-success" : "sci-badge-warning"}`;
  badge.textContent = status.state.toUpperCase();

  // Execution view badge
  const execStateBadge = document.getElementById("execStateBadge");
  if (execStateBadge) {
    execStateBadge.className = `sci-badge ${badge.className}`;
    execStateBadge.textContent = status.state.toUpperCase();
  }

  // State transitions history in execution panel
  const historyContainer = document.getElementById("stateTransitionHistory");
  if (historyContainer) {
    historyContainer.innerHTML = (status.history || []).map(h => {
      return `<div><span style="color: #64748B;">[${formatTimestamp(h.timestamp)}]</span> <span style="color: #93C5FD;">STATE:</span> ${h.state}</div>`;
    }).join("");
  }

  // If synthetic and unexecuted, show "Import Shipped Baseline Run" button
  const importShippedBtn = document.getElementById("importShippedBaselineBtn");
  if (importShippedBtn) {
    importShippedBtn.style.display = (job.dataset_kind === "synthetic_bundled" && status.state === "validated") ? "inline-flex" : "none";
  }

  loadJobFrames(activeJobId);
  loadConfigDiff(activeJobId);
  document.getElementById("jobMetadataViewer").textContent = JSON.stringify(job, null, 2);
  renderPipelineHashes(job.pipeline_files || {});
  renderImageAnalysisView(data);
  loadDetectionsForExplorer(data);
  renderTrackingView(data);
  renderReportsArtifacts(data);
}

// 6. Job Frames List
async function loadJobFrames(jobId) {
  try {
    const res = await fetch(`/jobs/${jobId}/frames`);
    if (!res.ok) return;
    const data = await res.json();
    const frames = data.frames || [];

    const countBadge = document.getElementById("activeStackFrameCount");
    if (countBadge) countBadge.textContent = `${frames.length} Frames`;

    const strip = document.getElementById("frameThumbStrip");
    if (!strip) return;

    if (frames.length === 0) {
      strip.innerHTML = `<div style="font-size: 11px; color: var(--text-muted); padding: 8px;">No frames in stack.</div>`;
      return;
    }

    strip.innerHTML = frames.map(f => {
      return `
        <div class="frame-card">
          <div style="font-weight: 600; font-family: var(--font-mono);">${escapeHtml(f.filename)}</div>
          <div style="color: var(--text-muted); font-size: 10px; margin-top: 2px;">${(f.size_bytes / 1024).toFixed(0)} KB · 8-bpp</div>
          <a href="${f.url}" target="_blank" class="sci-btn sci-btn-sm" style="margin-top: 4px; width: 100%;">View Raw</a>
        </div>
      `;
    }).join("");
  } catch (err) {
    console.error("Failed to load frames:", err);
  }
}

// 7. Image Analysis Rendering
function renderImageAnalysisView(data) {
  const { job_id, results } = data || {};

  const detImg = document.getElementById("analysisDetPreviewImg");
  const detLink = document.getElementById("detImgDownloadLink");
  const blinkImg = document.getElementById("analysisBlinkGifImg");
  const blinkLink = document.getElementById("blinkImgDownloadLink");
  const montageImg = document.getElementById("analysisMontageImg");
  const montageLink = document.getElementById("montageImgDownloadLink");

  // Detection Preview (use active job if available, else primary simulation baseline)
  const detUrl = (results && results.has_detection_preview)
    ? `/jobs/${job_id}/results/detection_preview.png`
    : `/simulation/results/files/detection_preview.png`;
  if (detImg) { detImg.src = detUrl; detImg.style.display = "block"; }
  if (detLink) detLink.href = detUrl;

  // Blink Comparator
  const blinkUrl = (results && results.has_blink_gif)
    ? `/jobs/${job_id}/results/blink.gif`
    : `/simulation/results/files/blink.gif`;
  if (blinkImg) { blinkImg.src = blinkUrl; blinkImg.style.display = "block"; }
  if (blinkLink) blinkLink.href = blinkUrl;

  // Frame Stack Montage
  const montageUrl = (results && results.has_frames_montage)
    ? `/jobs/${job_id}/results/frames_montage.png`
    : `/simulation/results/files/frames_montage.png`;
  if (montageImg) { montageImg.src = montageUrl; montageImg.style.display = "block"; }
  if (montageLink) montageLink.href = montageUrl;
}

// 8. Candidate Explorer & Filters
function setupCandidateFilters() {
  const filterClass = document.getElementById("candFilterClass");
  const filterIsCand = document.getElementById("candFilterIsCand");
  const filterFrame = document.getElementById("candFilterFrame");
  const searchInput = document.getElementById("candSearchInput");

  const applyFilters = () => {
    if (!rawDetectionsList) return;
    const cVal = filterClass ? filterClass.value : "ALL";
    const iVal = filterIsCand ? filterIsCand.value : "ALL";
    const fVal = filterFrame ? filterFrame.value : "ALL";
    const qVal = searchInput ? searchInput.value.toLowerCase().trim() : "";

    const filtered = rawDetectionsList.filter(d => {
      if (cVal !== "ALL" && d.class !== cVal) return false;
      if (iVal === "YES" && !d.isCandidate) return false;
      if (iVal === "NO" && d.isCandidate) return false;
      if (fVal !== "ALL" && String(d.frame) !== fVal) return false;
      if (qVal) {
        const textBlob = `${d.frame} ${d.id} ${d.class} ${d.subtype || ""} ${d.cx} ${d.cy}`.toLowerCase();
        if (!textBlob.includes(qVal)) return false;
      }
      return true;
    });

    renderExplorerTable(filtered);
  };

  if (filterClass) filterClass.addEventListener("change", applyFilters);
  if (filterIsCand) filterIsCand.addEventListener("change", applyFilters);
  if (filterFrame) filterFrame.addEventListener("change", applyFilters);
  if (searchInput) searchInput.addEventListener("input", applyFilters);
}

async function loadDetectionsForExplorer(data) {
  const { job_id, results } = data || {};
  const tbody = document.getElementById("explorerTableBody");
  const countBadge = document.getElementById("candidateFilterCountBadge");

  const url = (results && results.has_detections_json)
    ? `/jobs/${job_id}/results/detections.json`
    : `/simulation/results/detections`;

  try {
    const res = await fetch(url);
    if (!res.ok) {
      rawDetectionsList = [];
      if (tbody) tbody.innerHTML = `<tr><td colspan="12" style="text-align: center; color: var(--text-muted); padding: 20px;">No detection records available.</td></tr>`;
      if (countBadge) countBadge.textContent = `0 Detections`;
      return;
    }
    const detJson = await res.json();
    rawDetectionsList = detJson.detections || [];
    const sourceSuffix = (results && results.has_detections_json) ? "" : " (Simulation Baseline)";
    if (countBadge) countBadge.textContent = `${rawDetectionsList.length} Detections${sourceSuffix}`;
    renderExplorerTable(rawDetectionsList);
  } catch (err) {
    console.error("Failed to load detections.json:", err);
  }
}

function renderExplorerTable(detections) {
  const tbody = document.getElementById("explorerTableBody");
  const countBadge = document.getElementById("candidateFilterCountBadge");
  if (countBadge) countBadge.textContent = `${detections.length} Detections`;

  if (!tbody) return;
  if (detections.length === 0) {
    tbody.innerHTML = `<tr><td colspan="12" style="text-align: center; color: var(--text-muted); padding: 20px;">No matching detections found.</td></tr>`;
    return;
  }

  tbody.innerHTML = detections.map((d, idx) => {
    const isCand = d.isCandidate;
    const candBadge = isCand
      ? `<span class="sci-badge sci-badge-candidate">CANDIDATE</span>`
      : `<span style="color: var(--text-muted);">-</span>`;

    const subtypeText = d.subtype ? escapeHtml(d.subtype) : "-";
    const bboxText = `[${d.bboxX.toFixed(1)}, ${d.bboxY.toFixed(1)}, ${d.bboxW.toFixed(0)}, ${d.bboxH.toFixed(0)}]`;

    return `
      <tr onclick="inspectCandidate(${idx})" style="cursor: pointer;">
        <td class="mono-cell">F${d.frame}</td>
        <td class="mono-cell">#${d.id}</td>
        <td>${escapeHtml(d.class)}</td>
        <td style="color: var(--text-secondary);">${subtypeText}</td>
        <td>${candBadge}</td>
        <td class="num-cell">(${d.cx.toFixed(1)}, ${d.cy.toFixed(1)})</td>
        <td class="num-cell">${d.area}</td>
        <td class="num-cell">${d.length.toFixed(1)}</td>
        <td class="num-cell">${d.elongation.toFixed(2)}</td>
        <td class="num-cell">${d.meanZ.toFixed(1)}</td>
        <td class="num-cell">${d.peakZ.toFixed(1)}</td>
        <td class="mono-cell" style="font-size: 10px;">${bboxText}</td>
      </tr>
    `;
  }).join("");
}

window.inspectCandidate = function(idx) {
  if (!rawDetectionsList || !rawDetectionsList[idx]) return;
  const d = rawDetectionsList[idx];
  const box = document.getElementById("candidateDetailBox");
  if (!box) return;

  box.style.display = "block";
  document.getElementById("detailCandTitle").textContent = `Frame ${d.frame} · Candidate #${d.id} (${d.class})`;
  document.getElementById("detailCxCy").textContent = `(${d.cx.toFixed(2)}, ${d.cy.toFixed(2)}) px`;
  document.getElementById("detailBBox").textContent = `[x=${d.bboxX.toFixed(1)}, y=${d.bboxY.toFixed(1)}, w=${d.bboxW.toFixed(1)}, h=${d.bboxH.toFixed(1)}]`;
  document.getElementById("detailOrientation").textContent = `${d.orientation.toFixed(1)}°`;
  document.getElementById("detailDashCount").textContent = `${d.dashCount || 1} component(s)`;
  document.getElementById("detailPeakZraw").textContent = `${d.peakZraw.toFixed(1)} SNR`;
  document.getElementById("detailContrast").textContent = `${d.contrast.toFixed(1)} SNR`;
  document.getElementById("detailAxes").textContent = `Major=${d.major.toFixed(1)} px, Minor=${d.minor.toFixed(1)} px`;
  
  let reason = "Classified as non-candidate based on threshold limits.";
  if (d.isCandidate) reason = "Morphological streak-like region passing elongation and length gates; forwarded to tracker.";
  else if (d.class === "artifact-like") reason = "Elevated single-pixel SNR or stationary across frames (cosmic ray / hot pixel / fixed star).";
  else if (d.class === "compact") reason = "Elongation < 2.0 or length < 10px (compact star / point source).";
  document.getElementById("detailReason").textContent = reason;
};

// 9. Tracking View (Honest Empty State)
async function renderTrackingView(data) {
  const { job_id, results } = data;
  const emptyState = document.getElementById("trackingEmptyState");
  const activeContent = document.getElementById("trackingActiveContent");

  if (!results.has_tracks_csv) {
    if (emptyState) emptyState.style.display = "block";
    if (activeContent) activeContent.style.display = "none";
    return;
  }

  if (emptyState) emptyState.style.display = "none";
  if (activeContent) activeContent.style.display = "block";

  const trackingPreviewImg = document.getElementById("trackingPreviewImg");
  if (results.has_tracking_preview && trackingPreviewImg) {
    trackingPreviewImg.src = `/jobs/${job_id}/results/tracking_preview.png`;
    trackingPreviewImg.style.display = "block";
  }

  try {
    const res = await fetch(`/jobs/${job_id}/results/tracks.csv`);
    const csvText = await res.text();
    renderTracksTable(parseCsv(csvText));
  } catch (err) {
    console.error("Failed to load tracks.csv:", err);
  }
}

function renderTracksTable(rows) {
  const tbody = document.getElementById("tracksTableBody");
  if (!tbody) return;
  if (!rows || rows.length <= 1) {
    tbody.innerHTML = `<tr><td colspan="7" style="text-align: center; color: var(--text-muted); padding: 16px;">No confirmed tracks recorded.</td></tr>`;
    return;
  }

  const dataRows = rows.slice(1).filter(r => r.length >= 10);
  tbody.innerHTML = dataRows.map(cols => {
    const trackId = cols[0];
    const frame = cols[1];
    const x = parseFloat(cols[2]).toFixed(1);
    const y = parseFloat(cols[3]).toFixed(1);
    const vx = parseFloat(cols[4]).toFixed(1);
    const vy = parseFloat(cols[5]).toFixed(1);
    const measured = cols[6] === "1" ? "○ Measured" : "□ Coasted";
    const sigX = parseFloat(cols[7]).toFixed(2);
    const sigY = parseFloat(cols[8]).toFixed(2);
    const pinnX = cols[9] && cols[9].toLowerCase() !== "nan" ? parseFloat(cols[9]).toFixed(1) : "-";
    const pinnY = cols[10] && cols[10].toLowerCase() !== "nan" ? parseFloat(cols[10]).toFixed(1) : "-";

    return `
      <tr>
        <td class="mono-cell" style="font-weight: 600;">Track ${trackId}</td>
        <td class="mono-cell">F${frame}</td>
        <td class="num-cell">(${x}, ${y})</td>
        <td class="num-cell">(${vx}, ${vy})</td>
        <td>${measured}</td>
        <td class="num-cell">(${sigX}, ${sigY})</td>
        <td class="num-cell">${pinnX}, ${pinnY}</td>
      </tr>
    `;
  }).join("");
}

// 10. Reports & Artifacts Table
function renderReportsArtifacts(data) {
  const { job_id, results, job } = data;
  const tbody = document.getElementById("reportsArtifactsTableBody");
  if (!tbody) return;

  const artifacts = [
    { file: "detections.csv", desc: "22-column tabular detection measurements", format: "CSV Table", exists: results.has_detections_csv },
    { file: "detections.json", desc: "Detection metrics, thresholds, and region properties", format: "JSON Data", exists: results.has_detections_json },
    { file: "detection_preview.png", desc: "Telescope frame candidate overlays & centroid plots", format: "PNG Image", exists: results.has_detection_preview },
    { file: "blink.gif", desc: "Temporal multi-frame comparator animation", format: "Animated GIF", exists: results.has_blink_gif },
    { file: "tracks.csv", desc: "11-column Kalman & PINN kinematic tracks", format: "CSV Table", exists: results.has_tracks_csv },
    { file: "job.json", desc: "Cryptographic provenance & input frame SHA-256 digests", format: "JSON Provenance", exists: true, directUrl: `/jobs/${job_id}` },
    { file: "config_diff.txt", desc: "Line-by-line configuration diff for debris_defaults.m", format: "Text Diff", exists: true, directUrl: `/jobs/${job_id}/diff` }
  ];

  tbody.innerHTML = artifacts.map(a => {
    const statusBadge = a.exists
      ? `<span class="sci-badge sci-badge-success">AVAILABLE</span>`
      : `<span class="sci-badge sci-badge-planned">UNGENERATED</span>`;

    const actionBtn = a.exists
      ? `<a href="${a.directUrl || `/jobs/${job_id}/results/${a.file}`}" download="${a.file}" class="sci-btn sci-btn-sm">Download</a>`
      : `<button class="sci-btn sci-btn-sm" disabled>Download</button>`;

    return `
      <tr>
        <td class="mono-cell" style="font-weight: 600;">${escapeHtml(a.file)}</td>
        <td>${escapeHtml(a.desc)}</td>
        <td style="color: var(--text-secondary); font-size: 11px;">${escapeHtml(a.format)}</td>
        <td>${statusBadge}</td>
        <td style="text-align: right;">${actionBtn}</td>
      </tr>
    `;
  }).join("");

  const downloadBundleBtn = document.getElementById("reportsDownloadBundleBtn");
  if (downloadBundleBtn) {
    downloadBundleBtn.onclick = () => {
      window.location.href = `/jobs/${job_id}/bundle`;
    };
  }
}

// 11. Simulation Ground Truth Loader
async function loadSimulationTruth() {
  try {
    const res = await fetch("/simulation/truth");
    const data = await res.json();
    const records = data.records || [];
    const tbody = document.getElementById("simTruthTableBody");
    if (!tbody) return;

    if (records.length === 0) {
      tbody.innerHTML = `<tr><td colspan="5" style="text-align: center; color: var(--text-muted); padding: 10px;">No truth records found.</td></tr>`;
      return;
    }

    tbody.innerHTML = records.map(r => {
      return `
        <tr>
          <td class="mono-cell">Frame ${r.frame}</td>
          <td class="num-cell">(${r.cx.toFixed(2)}, ${r.cy.toFixed(2)})</td>
          <td class="num-cell">(${r.x1.toFixed(1)}, ${r.y1.toFixed(1)})</td>
          <td class="num-cell">(${r.x2.toFixed(1)}, ${r.y2.toFixed(1)})</td>
          <td class="num-cell">${r.flux_e.toFixed(0)} e-</td>
        </tr>
      `;
    }).join("");
  } catch (err) {
    console.error("Failed to load simulation truth:", err);
  }
}

// 12. Capabilities Matrix Loader
async function loadCapabilitiesMatrix() {
  try {
    const res = await fetch("/capabilities");
    const data = await res.json();
    const caps = data.capabilities || [];
    const tbody = document.getElementById("capabilitiesTableBody");
    if (!tbody) return;

    const statusBadges = {
      "IMPLEMENTED": `<span class="sci-badge sci-badge-implemented">IMPLEMENTED</span>`,
      "PARTIALLY_IMPLEMENTED": `<span class="sci-badge sci-badge-partially">PARTIALLY IMPLEMENTED</span>`,
      "UNVERIFIED": `<span class="sci-badge sci-badge-unverified">UNVERIFIED (Gate A)</span>`,
      "PLANNED": `<span class="sci-badge sci-badge-planned">PLANNED</span>`
    };

    tbody.innerHTML = caps.map(c => {
      const badge = statusBadges[c.status] || `<span class="sci-badge">${c.status}</span>`;
      return `
        <tr>
          <td><strong>${escapeHtml(c.name)}</strong></td>
          <td>${badge}</td>
          <td class="mono-cell" style="font-size: 11px; color: var(--text-secondary);">${escapeHtml(c.engine)}</td>
          <td style="font-size: 11px; color: var(--text-secondary);">${escapeHtml(c.description)}</td>
        </tr>
      `;
    }).join("");
  } catch (err) {
    console.error("Failed to load capabilities matrix:", err);
  }
}

// 13. Execution & Gate A Handlers
function setupExecutionHandlers() {
  const runBtn = document.getElementById("runMatlabBtn");
  const downloadBundleBtn = document.getElementById("downloadBundleBtn");
  const execAlert = document.getElementById("execMsgAlert");

  if (runBtn) {
    runBtn.addEventListener("click", async () => {
      if (!activeJobId) {
        alert("Please select a job first.");
        return;
      }
      runBtn.disabled = true;
      runBtn.textContent = "Checking Engine...";
      if (execAlert) execAlert.style.display = "none";

      try {
        const res = await fetch(`/jobs/${activeJobId}/run`, { method: "POST" });
        const data = await res.json();
        if (execAlert) {
          execAlert.style.display = "block";
          if (data.status === "awaiting_matlab") {
            execAlert.style.backgroundColor = "var(--amber-bg)";
            execAlert.style.color = "var(--amber-status)";
            execAlert.style.border = "1px solid var(--amber-border)";
            execAlert.innerHTML = `<strong>Awaiting Gate A:</strong> ${escapeHtml(data.message)}<div style="margin-top: 4px;">Use "Export Bundle (.zip)" to run on a colleague's MATLAB installation.</div>`;
          } else if (data.status === "completed" || data.status === "imported") {
            execAlert.style.backgroundColor = "var(--emerald-bg)";
            execAlert.style.color = "var(--emerald-status)";
            execAlert.style.border = "1px solid var(--emerald-border)";
            execAlert.innerHTML = `<strong>Success:</strong> MATLAB execution finished cleanly. Output files generated.`;
          } else {
            execAlert.style.backgroundColor = "var(--rose-bg)";
            execAlert.style.color = "var(--rose-status)";
            execAlert.style.border = "1px solid var(--rose-border)";
            execAlert.innerHTML = `<strong>Execution Error [${data.error_code || "FAIL"}]:</strong> ${escapeHtml(data.error_message || "MATLAB execution failed.")}`;
          }
        }

        await loadJobDetails(activeJobId);
        await loadJobsList();
      } catch (e) {
        if (execAlert) {
          execAlert.style.display = "block";
          execAlert.style.backgroundColor = "var(--rose-bg)";
          execAlert.style.color = "var(--rose-status)";
          execAlert.textContent = "Error executing job: " + e.message;
        }
      } finally {
        runBtn.disabled = false;
        runBtn.textContent = "Execute Pipeline";
      }
    });
  }

  if (downloadBundleBtn) {
    downloadBundleBtn.addEventListener("click", () => {
      if (!activeJobId) {
        alert("Please select a job first.");
        return;
      }
      window.location.href = `/jobs/${activeJobId}/bundle`;
    });
  }

  // Import Results Dropzone
  const importDropzone = document.getElementById("importDropzone");
  const importFileInput = document.getElementById("importFileInput");
  const submitImportBtn = document.getElementById("submitImportBtn");
  const importStatus = document.getElementById("importStatus");

  if (importDropzone && importFileInput) {
    importDropzone.addEventListener("click", () => importFileInput.click());
    importFileInput.addEventListener("change", (e) => {
      const files = Array.from(e.target.files).filter(f => f.name.toLowerCase().endsWith(".zip"));
      if (files.length > 0) {
        selectedImportFile = files[0];
        importStatus.innerHTML = `<span style="color: #065F46; font-weight: 600;">Selected: ${escapeHtml(selectedImportFile.name)}</span>`;
        submitImportBtn.disabled = false;
      }
    });
  }

  const importForm = document.getElementById("importForm");
  if (importForm) {
    importForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      if (!selectedImportFile || !activeJobId) return;

      submitImportBtn.disabled = true;
      submitImportBtn.textContent = "Verifying Schema...";
      importStatus.innerHTML = "Verifying 22-column detections & 11-column tracks schema...";

      const formData = new FormData();
      formData.append("file", selectedImportFile);

      try {
        const res = await fetch(`/jobs/${activeJobId}/import`, { method: "POST", body: formData });
        const data = await res.json();
        if (res.ok) {
          importStatus.innerHTML = `<span style="color: #065F46;">Import accepted: Schema verified.</span>`;
          await loadJobDetails(activeJobId);
          await loadJobsList();
          switchView("candidate-explorer");
        } else {
          const err = data.error || data.detail;
          importStatus.innerHTML = `<span style="color: #DC2626;">Schema Rejection [${err.code || "E_SCHEMA"}]: ${escapeHtml(err.reason || err.detail || JSON.stringify(err))}</span>`;
        }
      } catch (err) {
        importStatus.innerHTML = `<span style="color: #DC2626;">Import error: ${err.message}</span>`;
      } finally {
        submitImportBtn.disabled = false;
        submitImportBtn.textContent = "Verify & Ingest Results";
      }
    });
  }
}

// 14. Config Diff Loader
async function loadConfigDiff(jobId) {
  try {
    const res = await fetch(`/jobs/${jobId}/diff`);
    if (!res.ok) return;
    const data = await res.json();
    const diffViewer = document.getElementById("configDiffViewer");
    if (!diffViewer) return;

    if (!data.diff) {
      diffViewer.textContent = "No modifications. File is identical to original.";
      return;
    }
    const lines = data.diff.split("\n");
    diffViewer.innerHTML = lines.map(line => {
      if (line.startsWith("+") && !line.startsWith("+++")) {
        return `<span class="diff-add">${escapeHtml(line)}</span>`;
      } else if (line.startsWith("-") && !line.startsWith("---")) {
        return `<span class="diff-rem">${escapeHtml(line)}</span>`;
      } else if (line.startsWith("@@")) {
        return `<span class="diff-hunk">${escapeHtml(line)}</span>`;
      }
      return escapeHtml(line);
    }).join("\n");
  } catch (err) {
    console.error("Failed to load config diff:", err);
  }
}

// 15. Pipeline Hashes
function renderPipelineHashes(hashes) {
  const tbody = document.getElementById("pipelineHashesTableBody");
  if (!tbody) return;

  const fileDescriptions = {
    "main.m": "Stage 3 Optical Detection Driver",
    "track_debris.m": "Stage 4 Multi-Frame Tracking Driver",
    "detect_core.m": "Morphology & Connected Component Segmentation",
    "track_core.m": "Kalman Filtering & Mahalanobis Gating Filter",
    "kf_predict.m": "Linear State Extrapolation Model",
    "pinn_trajectory.m": "Physics-Informed Neural Network Regularizer",
    "score_detections.m": "Per-Frame Detection Benchmark vs Ground Truth",
    "score_tracks.m": "Track-Level Metric Benchmark vs Ground Truth",
    "load_frames.m": "8-bit Monochrome Stack Ingestion Engine",
    "blink_frames.m": "Temporal Image Comparator & GIF Compiler",
    "add_realistic_noise.m": "Synthetic Debris & CCD Artifact Generator",
    "evaluate_pipeline.m": "Parameter Sweep & In-Sample Evaluator"
  };

  const rows = Object.entries(hashes).map(([filename, digest]) => {
    const role = fileDescriptions[filename] || "Mathematical Subroutine";
    const status = digest !== "MISSING"
      ? `<span class="sci-badge sci-badge-success">PRESERVED</span>`
      : `<span class="sci-badge sci-badge-danger">MISSING</span>`;

    return `
      <tr>
        <td class="mono-cell" style="font-weight: 600;">${escapeHtml(filename)}</td>
        <td>${escapeHtml(role)}</td>
        <td class="mono-cell" style="font-size: 10px; color: var(--text-secondary);">${escapeHtml(digest)}</td>
        <td style="text-align: right;">${status}</td>
      </tr>
    `;
  });

  tbody.innerHTML = rows.join("");
}

// Utilities
function parseCsv(text) {
  return text.trim().split("\n").map(l => l.split(",").map(c => c.trim()));
}

function escapeHtml(str) {
  if (typeof str !== "string") return str;
  return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function formatTimestamp(isoStr) {
  if (!isoStr) return "-";
  try {
    const d = new Date(isoStr);
    return d.toISOString().replace("T", " ").substring(0, 19);
  } catch {
    return isoStr;
  }
}

// 15b. Quantitative Evaluation Loader (data/results/detections.json)
async function loadEvaluationMetrics() {
  try {
    const res = await fetch("/simulation/results");
    if (!res.ok) return;
    const data = await res.json();
    const metrics = data.metrics || {};
    const thresholds = data.thresholds || [];

    const recallEl = document.getElementById("evalRecallVal");
    const recallSub = document.getElementById("evalRecallSub");
    const precEl = document.getElementById("evalPrecisionVal");
    const precSub = document.getElementById("evalPrecisionSub");
    const f1El = document.getElementById("evalF1Val");

    if (recallEl && metrics.recall !== undefined) {
      recallEl.textContent = (metrics.recall * 100).toFixed(1) + "%";
      if (recallSub) recallSub.textContent = `TP = ${metrics.TP}, FN = ${metrics.FN} (matchRadius = 12 px)`;
    }
    if (precEl && metrics.precision !== undefined) {
      precEl.textContent = (metrics.precision * 100).toFixed(1) + "%";
      if (precSub) precSub.textContent = `TP = ${metrics.TP}, FP = ${metrics.FP} (includes distractors)`;
    }
    if (f1El && metrics.F1 !== undefined) {
      f1El.textContent = metrics.F1.toFixed(2);
    }

    // Populate Thresholds Table
    const tbody = document.getElementById("evalThresholdsTableBody");
    if (tbody && thresholds.length > 0) {
      tbody.innerHTML = thresholds.map((t, i) => `
        <tr>
          <td class="mono-cell">Frame ${i + 1}</td>
          <td class="num-cell">${t.sig0.toFixed(2)} DN</td>
          <td class="num-cell">${t.otsuT.toFixed(2)} DN</td>
          <td class="num-cell">${t.T.toFixed(2)} DN</td>
          <td>Temporal Median</td>
          <td class="mono-cell">1.50 px</td>
        </tr>
      `).join("");
    }
  } catch (err) {
    console.error("Failed to load evaluation metrics:", err);
  }
}

// 15c. Simulation Metadata & Defects Loader (data/debris_truth.mat)
async function loadSimulationMetadata() {
  try {
    const res = await fetch("/simulation/metadata");
    if (!res.ok) return;
    const data = await res.json();
    if (!data.available) return;

    const velText = document.getElementById("simVelText");
    if (velText && data.velocity) {
      const vx = data.velocity.vx;
      const vy = data.velocity.vy;
      const speed = Math.hypot(vx, vy).toFixed(2);
      velText.textContent = `vx = ${vx >= 0 ? "+" : ""}${vx} px/frame, vy = ${vy >= 0 ? "+" : ""}${vy} px/frame (Speed = ${speed} px/frame)`;
    }

    const defectsText = document.getElementById("simDefectsText");
    if (defectsText && data.defects) {
      defectsText.textContent = `Hot: ${data.defects.hot_pixels} px · Dead: ${data.defects.dead_pixels} px · Stuck: ${data.defects.stuck_pixels} px · Col: ${data.defects.dead_column_pixels} px`;
    }
  } catch (err) {
    console.error("Failed to load simulation metadata:", err);
  }
}

// 16. Demonstration Media Loader
async function loadDemoManifest() {
  const videoContainer = document.getElementById("demoVideoContainer");
  const galleryContainer = document.getElementById("demoGalleryContainer");

  try {
    const res = await fetch("/demo/manifest");
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();

    if (!data.available || !data.files || data.files.length === 0) {
      if (videoContainer) {
        videoContainer.innerHTML = `
          <div class="demo-empty-state">
            <span class="sci-badge sci-badge-warning">NO DEMO MEDIA</span>
            <p style="font-size: 12px; color: var(--text-secondary); margin-top: 6px;">
              No demonstration files found in <code>assets/matlab-demo/</code>.
            </p>
          </div>`;
      }
      if (galleryContainer) {
        galleryContainer.innerHTML = `
          <div class="demo-empty-state">
            <p style="font-size: 12px; color: var(--text-muted);">No supporting demonstration images available.</p>
          </div>`;
      }
      return;
    }

    const videos = data.files.filter(f => f.media_type === "video");
    const images = data.files.filter(f => f.media_type === "image");

    // Render video
    if (videoContainer) {
      if (videos.length > 0) {
        const vid = videos[0];
        videoContainer.innerHTML = `
          <div class="demo-video-wrapper">
            <video id="matlabDemoVideo" controls preload="metadata" playsinline class="demo-video-player">
              <source src="${vid.url}" type="video/mp4">
              Your browser does not support HTML5 video playback.
            </video>
            <div class="demo-media-meta">
              <div>
                <strong style="color: var(--text-main); font-family: var(--font-mono);">${escapeHtml(vid.filename)}</strong>
                <span style="color: var(--text-muted); font-size: 11px; margin-left: 8px;">
                  (${(vid.size_bytes / (1024 * 1024)).toFixed(2)} MB · H.264 MP4)
                </span>
              </div>
              <div style="font-size: 11px; color: var(--text-secondary); margin-top: 4px;">
                Demonstration screen recording of native MATLAB pipeline execution.
              </div>
            </div>
          </div>
        `;

        const videoEl = document.getElementById("matlabDemoVideo");
        if (videoEl) {
          videoEl.addEventListener("error", (e) => {
            console.error("Video playback error:", e);
            videoContainer.innerHTML = `
              <div class="demo-empty-state">
                <span class="sci-badge sci-badge-danger">VIDEO ERROR</span>
                <p style="font-size: 12px; color: var(--rose-status); margin-top: 6px;">
                  Failed to load or decode video: ${escapeHtml(vid.filename)}.
                </p>
              </div>`;
          });
        }
      } else {
        videoContainer.innerHTML = `
          <div class="demo-empty-state">
            <span class="sci-badge sci-badge-planned">NO VIDEO</span>
            <p style="font-size: 12px; color: var(--text-secondary); margin-top: 6px;">
              No demonstration video found in asset directory.
            </p>
          </div>`;
      }
    }

    // Render image gallery
    if (galleryContainer) {
      if (images.length > 0) {
        galleryContainer.innerHTML = images.map((img) => {
          let caption = "MATLAB Analysis Output Screenshot";
          let details = "External MATLAB figure capture.";
          
          if (img.filename.includes("02.46.34")) {
            caption = "Stage 3 Detection Overview (MATLAB Figure 1)";
            details = "4-frame candidate streak overlays (red), artifact & fixed object markers, and centroid trajectory plot.";
          } else if (img.filename.includes("02.46.35")) {
            caption = "Stage 4 Kalman Kinematic Track (MATLAB Figure 1)";
            details = "Measured frame positions, dead-reckoned coasting, forward prediction (+3σ), and regularized trajectory fit.";
          }

          return `
            <div class="demo-gallery-card">
              <div class="demo-image-frame">
                <img src="${img.url}" alt="${escapeHtml(caption)}" loading="lazy" onclick="window.open('${img.url}', '_blank')">
              </div>
              <div class="demo-card-body">
                <div style="font-weight: 600; font-size: 12px; color: var(--text-main); margin-bottom: 2px;">
                  ${escapeHtml(caption)}
                </div>
                <div style="font-size: 11px; color: var(--text-secondary); line-height: 1.4; margin-bottom: 6px;">
                  ${escapeHtml(details)}
                </div>
                <div style="display: flex; align-items: center; justify-content: space-between; font-size: 10px; color: var(--text-muted); border-top: 1px solid var(--border-subtle); padding-top: 6px;">
                  <span class="mono-cell">${escapeHtml(img.filename)}</span>
                  <span>${(img.size_bytes / 1024).toFixed(0)} KB</span>
                </div>
              </div>
            </div>
          `;
        }).join("");
      } else {
        galleryContainer.innerHTML = `
          <div class="demo-empty-state">
            <p style="font-size: 12px; color: var(--text-muted);">No supporting screenshots available.</p>
          </div>`;
      }
    }
  } catch (err) {
    console.error("Failed to load demo manifest:", err);
    if (videoContainer) {
      videoContainer.innerHTML = `
        <div class="demo-empty-state">
          <span class="sci-badge sci-badge-danger">MANIFEST ERROR</span>
          <p style="font-size: 12px; color: var(--text-secondary); margin-top: 6px;">
            Could not fetch demonstration manifest: ${escapeHtml(err.message)}
          </p>
        </div>`;
    }
  }
}

