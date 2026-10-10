%% track_debris.m
% Stage 4: multi-frame tracking.
%   - Kalman filter (constant velocity), Mahalanobis gating, dead reckoning
%   - PINN trajectory (motion-data loss + acceleration penalty) per track
%   - 3-sigma prediction ellipses
%   - Track-level scoring vs truth (ALL tracks, not just track 1)
%   - Held-out prediction backtest: Kalman vs PINN vs straight line
%
% Algorithms: track_core.m, kf_predict.m, pinn_trajectory.m, score_tracks.m
% Parameters: debris_defaults.m
% Input : data\results\detections.csv (from detect_debris.m)
% Output: data\results\tracks.mat / tracks.json / tracks.csv / tracking_preview.png

clear; clc; close all;

%% ---------------- Configuration ----------------
[~, tc, popts] = debris_defaults();
% tc.minHits = 3;      % <- override individual parameters here if you like

%% ---------------- Load ----------------
here = fileparts(mfilename('fullpath')); if isempty(here), here = pwd; end
resDir = fullfile(here, 'data', 'results');
if ~exist(resDir, 'dir'), mkdir(resDir); end
T = readtable(fullfile(resDir, 'detections.csv'));
matFile = fullfile(resDir, 'detections.mat');
n = max(T.frame);
if exist(matFile, 'file')
    M = load(matFile, 'nFrames');
    if isfield(M, 'nFrames'), n = M.nFrames; end      % true frame count, even if last frames had no detections
end

%% ---------------- Track ----------------
[tracks, nCand] = track_core(T, n, tc);
fprintf('%d candidate tracks built from seeds\n', nCand);
if isempty(tracks), error('No tracks - relax tc.minHits / tc.gateChi2 or check detections.'); end
fprintf('%d confirmed track(s)\n', numel(tracks));

%% ---------------- PINN trajectory for every track ----------------
for q = 1:numel(tracks)
    t = tracks{q};
    idx = find(t.hit);
    tq  = [t.frame(:); t.futureFrames(:)];
    t.pinn = [];
    if numel(idx) >= 3
        pz = t.z(:, idx)';                                 % measured centroids
        t.pinn = pinn_trajectory(t.frame(idx), pz, tq, popts);
        t.pinn.queryFrames = tq(:)';
    else
        fprintf('Track %d: only %d hits, PINN skipped (needs 3).\n', t.id, numel(idx));
    end
    tracks{q} = t;
end

%% ---------------- Score against truth (scoring only) ----------------
truthFile = fullfile(here, 'data', 'debris_truth.mat');
if exist(truthFile, 'file')
    S = load(truthFile, 'truth'); truth = S.truth;
    sc = score_tracks(tracks, truth, n, tc.matchRadius);
    fprintf('\n=== Track-level scoring vs truth (all %d tracks) ===\n', sc.nTracks);
    for q = 1:sc.nTracks
        fprintf('  Track %d: hits %d | within %d px of truth: %d | RMSE %.2f px | %s\n', ...
            q, sc.hits(q), tc.matchRadius, sc.hitsNearTruth(q), sc.rmse(q), ...
            ternary(sc.isTrue(q), 'TRUE track', 'FALSE track'));
    end
    fprintf('  Track precision = %.2f (%d true / %d tracks)\n', sc.trackPrecision, sc.nTrue, sc.nTracks);
    fprintf('  Frame recall    = %.2f (measured) | %.2f (incl. dead-reckoned)\n', ...
        sc.frameRecall, sc.frameRecallCoast);
    fprintf('  Track F1        = %.2f\n', sc.trackF1);
    if sc.best > 0
        t = tracks{sc.best};
        fprintf('  Best track %d: speed %.1f px/frame, heading %.1f deg\n', t.id, t.speed, t.heading);
    end
end

%% ---------------- Held-out prediction backtest ----------------
% For each track, train on the first c measured points only, predict the
% remaining measured frames, and compare with truth (or the measurement if
% no truth). Compares Kalman, PINN and a plain straight-line fit.
fprintf('\n=== Held-out prediction backtest (train on first c hits, predict the rest) ===\n');
methods = {'Kalman', 'PINN', 'Line'};
errs = cell(1, 3);
for q = 1:numel(tracks)
    t = tracks{q};  idx = find(t.hit);  nh = numel(idx);
    if nh < 4, continue; end
    fh = t.frame(idx)';  zh = t.z(:, idx)';
    for c = 3:nh-1
        tTest = fh(c+1:nh);
        if exist('truth', 'var') && all(tTest <= size(truth, 1)) && ~any(isnan(truth(tTest, 2)))
            ref = truth(tTest, 2:3);
        else
            ref = zh(c+1:nh, :);
        end
        xyK = kf_predict(fh(1:c), zh(1:c,:), tTest, tc.sigmaMeas, tc.sigmaAcc);
        po  = pinn_trajectory(fh(1:c), zh(1:c,:), tTest, popts);
        errs{1}(end+1:end+numel(tTest)) = hypot(xyK(:,1) - ref(:,1), xyK(:,2) - ref(:,2));
        errs{2}(end+1:end+numel(tTest)) = hypot(po.pred(:,1) - ref(:,1), po.pred(:,2) - ref(:,2));
        errs{3}(end+1:end+numel(tTest)) = hypot(po.linear(:,1) - ref(:,1), po.linear(:,2) - ref(:,2));
    end
end
if isempty(errs{1})
    fprintf('  Not enough measured points (need >= 4 hits in a track).\n');
else
    for i = 1:3
        fprintf('  %-7s mean error %.2f px | max %.2f px | N = %d predictions\n', ...
            methods{i}, mean(errs{i}), max(errs{i}), numel(errs{i}));
    end
    fprintf('  (With only a handful of frames these are indicative, not statistically strong.)\n');
end

%% ---------------- Save (CSV / MAT / JSON for the website) ----------------
rows = [];
for q = 1:numel(tracks)
    t = tracks{q};  m = numel(t.frame);
    sx = squeeze(sqrt(t.P(1,1,:)));  sy = squeeze(sqrt(t.P(2,2,:)));
    if ~isempty(t.pinn)
        px = t.pinn.pred(1:m, 1);  py = t.pinn.pred(1:m, 2);
    else
        px = nan(m, 1);  py = nan(m, 1);
    end
    rows = [rows; repmat(t.id, m, 1), t.frame(:), t.x(1,:)', t.x(2,:)', ...
            t.x(3,:)', t.x(4,:)', double(t.hit(:)), sx, sy, px, py]; %#ok<AGROW>
end
Ttr = array2table(rows, 'VariableNames', ...
    {'track','frame','x','y','vx','vy','measured','sigX','sigY','pinnX','pinnY'});
writetable(Ttr, fullfile(resDir, 'tracks.csv'));
save(fullfile(resDir, 'tracks.mat'), 'tracks', 'tc', 'popts');
out = struct('params', tc, 'tracks', {cellfun(@(t) rmfield(t, 'P'), tracks, 'UniformOutput', false)});
fid = fopen(fullfile(resDir, 'tracks.json'), 'w');
fwrite(fid, jsonencode(out, 'PrettyPrint', true)); fclose(fid);

%% ---------------- Preview ----------------
inDir = fullfile(here, 'data', 'frames_bmp_debris');
A = load_frames(inDir);  A = A(:,:,1);
fig = figure('Color', 'k', 'Position', [60 60 900 650]);
imshow(A, [0 255]); hold on;
cmap = parula(n);
for q = 1:numel(tracks)
    t = tracks{q};
    plot(t.x(1,:), t.x(2,:), 'w-', 'LineWidth', 1.5);
    for i = 1:numel(t.frame)
        if t.hit(i), mk = 'o'; else, mk = 's'; end         % square = coasted (dead reckoning)
        plot(t.x(1,i), t.x(2,i), mk, 'MarkerSize', 9, 'MarkerFaceColor', cmap(t.frame(i),:), 'MarkerEdgeColor', 'w');
    end
    plot([t.x(1,end) t.future(:,1)'], [t.x(2,end) t.future(:,2)'], 'y--', 'LineWidth', 1.5);
    for s = 1:tc.predictAhead
        plotEllipse(t.future(s,1:2), t.futureCov(:,:,s), 3, [1 1 0]);
    end
    if ~isempty(t.pinn)
        m = numel(t.frame);
        plot(t.pinn.pred(m+1:end,1), t.pinn.pred(m+1:end,2), 'm-.', 'LineWidth', 1.5);
        plot(t.pinn.pred(m+1:end,1), t.pinn.pred(m+1:end,2), 'm^', 'MarkerSize', 6, 'MarkerFaceColor', 'm');
    end
end
if exist('truth', 'var'), plot(truth(:,2), truth(:,3), 'c:', 'LineWidth', 1); end
title('Kalman track (o measured, square dead-reckoned, yellow prediction +3\sigma, magenta PINN)', 'Color', 'w');
saveas(fig, fullfile(resDir, 'tracking_preview.png'));
fprintf('\nResults saved in %s\n', resDir);

fprintf('\n=== Tracking plot legend ===\n');
fprintf('  WHITE line       Kalman-filtered track\n');
fprintf('  circle (o)       measured detection (dot color = frame, parula: dark blue first, yellow last)\n');
fprintf('  square           dead-reckoned (no detection that frame, filter coasted)\n');
fprintf('  YELLOW dashed    Kalman predicted future positions, ellipses = 3-sigma uncertainty\n');
fprintf('  MAGENTA          PINN predicted future positions\n');
fprintf('  CYAN dotted      ground truth\n');

%% ---------------- Optional blink comparator ----------------
% Set tc.blink = true in debris_defaults.m, or call blink_frames yourself.
if isfield(tc, 'blink') && tc.blink
    blink_frames();        % all-frames image, then continuous blink + GIF. Add struct('overlay','both') for boxes + tracks.
end

%% ---------------- Local functions ----------------
function plotEllipse(mu, C, k, col)
    t = linspace(0, 2*pi, 60);
    [V, D] = eig(C);
    e = V * sqrt(D) * k * [cos(t); sin(t)];
    plot(mu(1) + e(1,:), mu(2) + e(2,:), 'Color', col);
end

function r = ternary(c, a, b)
    if c, r = a; else, r = b; end
end