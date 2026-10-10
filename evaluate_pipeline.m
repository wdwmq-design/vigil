%% evaluate_pipeline.m
% Honest robustness evaluation of detection + tracking.
%
% Your tuned numbers are in-sample (parameters were adjusted while looking at
% this very sequence). This script gives three views that are harder to game:
%
%   A. NOISE SWEEP      add extra Gaussian noise to the frames, rerun the whole
%                       pipeline (several random repeats), report track-level
%                       precision / recall.
%   B. PARAMETER SWEEP  vary kSigma and smoothSigma around the defaults; if
%                       results collapse after a small change the tuning is brittle.
%   C. HELD-OUT FRAME   hide each frame's detections in turn and check how well
%                       the Kalman filter dead-reckons through it.
%
% For truly unbiased numbers: generate several datasets with different random
% seeds (make_debris_dataset), put each in its own folder with the same layout
% (frames_bmp_debris\*.bmp + debris_truth.mat), list them in ev.dataDirs, tune
% on one, and report the others.
%
% Runtime: detect_core is run (nNoise*nRep + nK*nS) times per dataset. Set
% ev.quick = true for a fast pass.

clear; clc; close all;

here = fileparts(mfilename('fullpath')); if isempty(here), here = pwd; end
[cfg0, tc, ~] = debris_defaults();
cfg0.verbose = false;

ev.dataDirs    = {fullfile(here, 'data')};      % add more dataset folders here
ev.noiseFactor = [0 0.5 1 2];                   % extra noise, in units of the frames' own sigma
ev.nRep        = 3;                             % random repeats per noise level
ev.kSigmaGrid  = [3 4 5];
ev.smoothGrid  = [1 1.5 2];
ev.quick       = false;
if ev.quick
    ev.noiseFactor = [0 1];  ev.nRep = 1;  ev.kSigmaGrid = [4];  ev.smoothGrid = [1.5];
end

resDir = fullfile(here, 'data', 'results');
if ~exist(resDir, 'dir'), mkdir(resDir); end
allRows = {};

for di = 1:numel(ev.dataDirs)
    dd = ev.dataDirs{di};
    stack = load_frames(fullfile(dd, 'frames_bmp_debris'));
    S = load(fullfile(dd, 'debris_truth.mat'), 'truth');  truth = S.truth;
    n = size(stack, 3);
    med = median(stack, 3);
    D1 = stack(:,:,1) - med;
    sig0 = 1.4826 * median(abs(D1(:) - median(D1(:))));
    fprintf('\n##### Dataset %d: %s  (%d frames, frame noise sigma ~ %.2f counts)\n', di, dd, n, sig0);

    %% ---- A. noise sweep ----
    fprintf('\n--- A. Noise sweep (default parameters) ---\n');
    fprintf('%-8s %-5s | %-9s %-9s %-9s | %-6s %-6s %-6s | %-6s\n', ...
        'extra', 'rep', 'detPrec', 'detRec', 'detF1', 'tracks', 'trPrec', 'frRec', 'RMSE');
    for f = ev.noiseFactor
        for rep = 1:ev.nRep
            rng(1000 * di + 10 * rep + round(10 * f));
            noisy = stack + f * sig0 * randn(size(stack));
            r = runOnce(noisy, truth, n, cfg0, tc);
            fprintf('%-8.1f %-5d | %-9.2f %-9.2f %-9.2f | %-6d %-6.2f %-6.2f | %-6.2f\n', f, rep, ...
                r.det.precision, r.det.recall, r.det.F1, r.trk.nTracks, r.trk.trackPrecision, ...
                r.trk.frameRecall, r.rmse);
            allRows{end+1} = {di, 'noise', f, rep, r}; %#ok<SAGROW>
        end
    end

    %% ---- B. parameter sweep ----
    fprintf('\n--- B. Parameter sweep (no extra noise) ---\n');
    fprintf('%-8s %-8s | %-9s %-9s | %-6s %-6s %-6s | %-6s\n', ...
        'kSigma', 'smooth', 'detPrec', 'detRec', 'tracks', 'trPrec', 'frRec', 'RMSE');
    for ks = ev.kSigmaGrid
        for sm = ev.smoothGrid
            cfg = cfg0;  cfg.kSigma = ks;  cfg.smoothSigma = sm;
            r = runOnce(stack, truth, n, cfg, tc);
            fprintf('%-8.1f %-8.1f | %-9.2f %-9.2f | %-6d %-6.2f %-6.2f | %-6.2f\n', ks, sm, ...
                r.det.precision, r.det.recall, r.trk.nTracks, r.trk.trackPrecision, r.trk.frameRecall, r.rmse);
            allRows{end+1} = {di, 'param', ks * 100 + sm, 1, r}; %#ok<SAGROW>
        end
    end

    %% ---- C. held-out frame (dead reckoning) ----
    fprintf('\n--- C. Hold-out: hide one frame, does the filter coast through it? ---\n');
    [Tdet, ~] = detect_core(stack, cfg0);
    heldErr = nan(1, n);
    for k = 1:n
        trk = track_core(Tdet, n, tc, k);
        if isempty(trk), fprintf('  frame %d hidden: no tracks formed\n', k); continue; end
        sc = score_tracks(trk, truth, n, tc.matchRadius);
        if sc.best == 0, fprintf('  frame %d hidden: no true track survived\n', k); continue; end
        t = trk{sc.best};
        j = find(t.frame == k, 1);
        if isempty(j) || ~(k <= size(truth, 1)) || any(isnan(truth(k, 2:3)))
            fprintf('  frame %d hidden: true track does not span this frame (start/end of sequence)\n', k);
            continue;
        end
        heldErr(k) = hypot(t.x(1,j) - truth(k,2), t.x(2,j) - truth(k,3));
        fprintf('  frame %d hidden: dead-reckoned error = %.2f px (%s)\n', k, heldErr(k), ...
            ternary(heldErr(k) <= tc.matchRadius, 'within match radius', 'MISSED'));
    end
    fprintf('  mean held-out error over %d frames: %.2f px\n', sum(~isnan(heldErr)), mean(heldErr, 'omitnan'));
end

%% ---- Save summary ----
rowsOut = zeros(0, 9);
for i = 1:numel(allRows)
    a = allRows{i};  r = a{5};
    rowsOut(end+1, :) = [a{1}, strcmp(a{2}, 'noise'), a{3}, a{4}, r.det.precision, r.det.recall, ...
                         r.trk.trackPrecision, r.trk.frameRecall, r.rmse]; %#ok<SAGROW>
end
Tsum = array2table(rowsOut, 'VariableNames', ...
    {'dataset','isNoiseSweep','setting','rep','detPrecision','detRecall','trackPrecision','frameRecall','rmse'});
writetable(Tsum, fullfile(resDir, 'evaluation.csv'));
fprintf('\nSummary saved to %s\n', fullfile(resDir, 'evaluation.csv'));

%% ---------------- Local functions ----------------
function r = runOnce(stack, truth, n, cfg, tc)
% Full pipeline on one stack -> detection + track-level metrics.
    [Tdet, ~] = detect_core(stack, cfg);
    r.det = score_detections(Tdet, truth, n, cfg.matchRadius);
    if isempty(Tdet) || height(Tdet) == 0
        trk = {};
    else
        trk = track_core(Tdet, n, tc);
    end
    if isempty(trk)
        r.trk = struct('nTracks', 0, 'trackPrecision', 0, 'frameRecall', 0, 'best', 0, 'rmse', NaN);
        r.rmse = NaN;
    else
        r.trk = score_tracks(trk, truth, n, tc.matchRadius);
        if r.trk.best > 0, r.rmse = r.trk.rmse(r.trk.best); else, r.rmse = NaN; end
    end
end

function r = ternary(c, a, b)
    if c, r = a; else, r = b; end
end