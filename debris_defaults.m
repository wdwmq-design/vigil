function [cfg, tc, popts] = debris_defaults()
% DEBRIS_DEFAULTS  Single source of truth for all pipeline parameters.
% detect_debris.m, track_debris.m and evaluate_pipeline.m all call this, so
% the numbers you tune are the numbers the evaluation uses.

%% ---- Detection (detect_core.m) ----
cfg.bgMode       = 'temporal';  % 'temporal' (default) or 'spatial' (if stars shift between frames)
cfg.smoothSigma  = 1.5;         % px, Gaussian matched filter
cfg.noiseBins    = 16;          % bins of background level for sigma(bg)
cfg.kSigma       = 4.0;         % base threshold in sigma
cfg.otsuFloor    = 2.5;         % Otsu is run on Z values above this
cfg.otsuClip     = 15;          % ... clipped here so bright objects don't dominate
cfg.tMax         = 8.0;         % never let the threshold exceed this (keeps faint debris)
cfg.minArea      = 5;           % px, reject smaller regions
cfg.dashGap      = 30;          % px, closing radius used to group dashes
cfg.minStreakLen = 10;          % px (estimated true length)
cfg.elongMin     = 2.0;         % major/minor
cfg.longStreak   = 100;         % px -> 'long' (satellite-like)
cfg.minDashes    = 3;           % pieces needed to call a line 'dashed'
cfg.dashMinLen   = 25;          % px (lets 2-3 leftover dashes still count as dashed)
cfg.artifactZ    = 40;          % unsmoothed peak SNR above this = sharp artifact candidate
cfg.artifactMaxArea = Inf;      % px; sharp artifact must ALSO have area <= this.
%   Inf = original behaviour. Set ~150 so a genuinely bright,
%   large object is not auto-labelled "cosmic ray".
cfg.minContrastZ = 0;           % mean SNR of region; streak-like regions below this -> 'unknown'.
%   0 = off (original behaviour). Try 6 to drop faint blobs.
cfg.stationaryRadius    = 10;   % px - centroid of a fixed blob jitters ~5 px
cfg.stationaryMinFrames = 3;    % ... seen in at least this many frames
cfg.matchRadius  = 12;          % px, detection counts as hit if within this of truth
cfg.verbose      = true;        % print per-frame table and every bbox/centroid
cfg.blink        = true;       % true = open the blink comparator (with detection boxes) when done

%% ---- Tracking (track_core.m) ----
tc.sigmaMeas = 2.0;   % px, centroid measurement noise
tc.sigmaAcc  = 0.5;   % px/frame^2, process noise (allows slight acceleration)
tc.gateChi2  = 9.21;  % chi-square 99%, 2 dof
tc.minHits   = 3;     % detections needed to confirm a track
tc.maxMiss   = 1;     % consecutive missed frames allowed (dead reckoning)
tc.velMin    = 3;     % px/frame, reject stationary things
tc.velMax    = 200;   % px/frame
tc.predictAhead = 3;  % frames to extrapolate beyond the last one
tc.matchRadius  = 12; % px, for scoring vs truth
tc.excludeSub   = ["dashed", "stationary"];  % subtypes the tracker never accepts
tc.blink        = false;  % true = open the blink comparator (detections + tracks) when done

%% ---- PINN trajectory (pinn_trajectory.m) ----
popts.hidden      = 8;      % tanh units
popts.epochs      = 3000;   % Adam steps per ensemble member
popts.lr          = 0.01;
popts.lambdaAcc   = 1;      % weight of the acceleration (physics) penalty
popts.accScale    = tc.sigmaAcc;   % px/frame^2 - same scale as Kalman process noise
popts.sigmaMeas   = tc.sigmaMeas;  % px
popts.nColloc     = 40;     % collocation points where physics loss is enforced
popts.weightDecay = 1e-4;
popts.nEnsemble   = 5;      % members; spread of predictions = uncertainty
popts.seed        = 1;
end