%% detect_debris.m
% Stage 3: per-frame detection of debris candidates.
% Ground truth is NOT used for detection; it is only loaded in step 7 to
% score the result and in the preview plot.
%
% Algorithm lives in detect_core.m (so evaluate_pipeline.m can reuse it).
% Parameters live in debris_defaults.m (override any of them below).
%
% Needs the Image Processing Toolbox (bwconncomp, regionprops, imclose).
% Input : data\frames_bmp_debris\*.bmp   (from make_debris_dataset.m)
% Output: data\results\detections.csv / detections.json / detections.mat
%         data\results\detection_preview.png

clear; clc; close all;

%% ---------------- Configuration ----------------
cfg = debris_defaults();
% cfg.kSigma = 4.0;      % <- override individual parameters here if you like

%% ---------------- Paths / load ----------------
here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd; end
inDir  = fullfile(here, 'data', 'frames_bmp_debris');
resDir = fullfile(here, 'data', 'results');
if ~exist(resDir, 'dir'), mkdir(resDir); end

stack = load_frames(inDir);
n = size(stack, 3);

%% ---------------- Detect ----------------
[Tdet, info] = detect_core(stack, cfg);
if isempty(Tdet), error('Nothing detected - lower cfg.kSigma.'); end
det = table2struct(Tdet)';       % keep JSON/MAT output consistent with the table

fprintf('\n=== Detections: %d regions, %d debris candidates ===\n', height(Tdet), sum(Tdet.isCandidate));
disp(groupsummary(Tdet, 'class'));
if cfg.verbose, printDetections(Tdet); end

%% ---------------- 7. Score against ground truth (scoring only) ----------------
metrics = struct('TP', NaN, 'FP', NaN, 'FN', NaN, 'precision', NaN, 'recall', NaN, 'F1', NaN);
truthFile = fullfile(here, 'data', 'debris_truth.mat');
if exist(truthFile, 'file')
    S = load(truthFile, 'truth');  truth = S.truth;
    metrics = score_detections(Tdet, truth, n, cfg.matchRadius);
    fprintf('\nPer-frame detector vs truth (before tracking):\n');
    fprintf('  TP=%d  FP=%d  FN=%d   precision=%.2f  recall=%.2f  F1=%.2f\n', ...
            metrics.TP, metrics.FP, metrics.FN, metrics.precision, metrics.recall, metrics.F1);
    fprintf('  (FPs here include the meteor/other one-frame streaks; the tracker removes them.)\n');
    fprintf('  NOTE: parameters were tuned on this same sequence, so these numbers are in-sample.\n');
    fprintf('        Use evaluate_pipeline.m for noise / parameter robustness checks.\n');
end

%% ---------------- Save ----------------
nFrames = n;
writetable(Tdet, fullfile(resDir, 'detections.csv'));
save(fullfile(resDir, 'detections.mat'), 'cfg', 'det', 'info', 'metrics', 'nFrames');
fid = fopen(fullfile(resDir, 'detections.json'), 'w');
fwrite(fid, jsonencode(struct('params', cfg, 'thresholds', info, ...
        'metrics', metrics, 'detections', det), 'PrettyPrint', true));
fclose(fid);

%% ---------------- Preview ----------------
colMap = containers.Map({'streak-like','artifact-like','compact','unknown'}, ...
                        {[0.2 1 0.2], [1 0.3 1], [0.2 0.9 1], [1 0.8 0.2]});
nTiles = n + 2;                                   % frames + centroid panel + legend panel
nCols  = ceil(sqrt(nTiles * 1.5));
nRows  = ceil(nTiles / nCols);
fig = figure('Color', 'k', 'Position', [30 30 1450 700]);
for k = 1:n
    subplot(nRows, nCols, k);
    imshow(stack(:,:,k), [0 255]); hold on;
    for q = find(Tdet.frame == k)'
        col = colMap(Tdet.class{q});  lw = 1;
        if Tdet.isCandidate(q), col = [1 0.2 0.2]; lw = 2; end
        rectangle('Position', [Tdet.bboxX(q) Tdet.bboxY(q) Tdet.bboxW(q) Tdet.bboxH(q)], ...
                  'EdgeColor', col, 'LineWidth', lw);
        plot(Tdet.cx(q), Tdet.cy(q), '+', 'Color', col, 'MarkerSize', 6);   % centroid marker
    end
    title(sprintf('Frame %d   (red = debris candidate)', k), 'Color', 'w', 'FontSize', 7);
end
subplot(nRows, nCols, n + 1);
imshow(stack(:,:,1), [0 255]); hold on;
cand = Tdet(Tdet.isCandidate, :);
cmap = parula(n);
if ~isempty(cand)
    scatter(cand.cx, cand.cy, 60, cmap(cand.frame,:), 'filled', 'MarkerEdgeColor', 'w');
end
if exist('truth', 'var'), plot(truth(:,2), truth(:,3), 'w--', 'LineWidth', 1); end
title('Candidate centroids (color = frame, dashed = truth)', 'Color', 'w', 'FontSize', 7);

leg = { ...
    'RED (thick)',  [1.0 0.2 0.2], 'debris candidate (short streak) -> sent to tracker', 'debris candidate'; ...
    'GREEN',        [0.2 1.0 0.2], 'streak-like, not debris: dashed (aircraft) or long (satellite)', 'dashed / long streak'; ...
    'MAGENTA',      [1.0 0.3 1.0], 'artifact: hot pixel / cosmic ray / stationary fixed object', 'artifact / fixed object'; ...
    'CYAN',         [0.2 0.9 1.0], 'compact: star or noise blob', 'compact blob'; ...
    'YELLOW',       [1.0 0.8 0.2], 'unknown (tracker still accepts these)', 'unknown (tracked)'};
fprintf('\n=== Box color legend ===\n');
for i = 1:size(leg, 1)
    fprintf('  %-13s %s\n', leg{i,1}, leg{i,3});
end
subplot(nRows, nCols, n + 2); cla; axis off;
text(0, 1.00, 'Box colors (+ = centroid)', 'Color', 'w', 'FontWeight', 'bold', ...
    'FontSize', 8, 'Units', 'normalized', 'Clipping', 'off');
for i = 1:size(leg, 1)
    text(0, 1 - 0.14*i, sprintf('%s: %s', leg{i,1}, leg{i,4}), ...      % short text fits the panel
        'Color', leg{i,2}, 'FontSize', 7, 'Units', 'normalized', 'Clipping', 'off');
end
saveas(fig, fullfile(resDir, 'detection_preview.png'));
fprintf('\nResults saved in %s\n', resDir);

%% ---------------- Optional blink comparator ----------------
% Set cfg.blink = true in debris_defaults.m, or call blink_frames yourself.
if isfield(cfg, 'blink') && cfg.blink
    blink_frames();        % all-frames image, then continuous blink + GIF. Add struct('overlay','detections') for boxes.
end

%% ---------------- Local functions ----------------
function printDetections(Tdet)
% Command-window report: bounding box, centroid, size, area for every region.
    fprintf('\n=== Detection coordinates (px; bbox = [x y w h], centroid = SNR-weighted) ===\n');
    for q = 1:height(Tdet)
        fprintf(['F%02d #%02d %-14s %-30s bbox=[%7.1f %7.1f %6.1f %6.1f]  ' ...
                 'centroid=(%7.1f,%7.1f)  area=%4d  len=%6.1f  elong=%5.2f  meanZ=%5.1f\n'], ...
            Tdet.frame(q), Tdet.id(q), Tdet.class{q}, Tdet.subtype{q}, ...
            Tdet.bboxX(q), Tdet.bboxY(q), Tdet.bboxW(q), Tdet.bboxH(q), ...
            Tdet.cx(q), Tdet.cy(q), Tdet.area(q), Tdet.length(q), Tdet.elongation(q), Tdet.meanZ(q));
    end
end