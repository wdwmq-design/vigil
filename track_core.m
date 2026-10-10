function [tracks, nCand] = track_core(Tdet, n, tc, dropFrames)
% TRACK_CORE  Multi-frame tracking with a constant-velocity Kalman filter.
%
%   [tracks, nCand] = track_core(Tdet, n, tc [, dropFrames])
%
%   Tdet       detection table from detect_core (needs frame, cx, cy, class, subtype)
%   n          number of frames
%   dropFrames (optional) frames whose detections are hidden - used by
%              evaluate_pipeline.m to test dead-reckoning on a held-out frame.
%
% Seeds tracks from detection pairs, gates with Mahalanobis distance, coasts
% through missed frames, picks the best non-overlapping tracks, then
% extrapolates tc.predictAhead frames with covariance.
if nargin < 4, dropFrames = []; end

cls = string(Tdet.class);
sub = string(Tdet.subtype);  sub(ismissing(sub)) = "";   % empty subtype can be read as missing
keep = ismember(cls, ["streak-like", "unknown"]);
for s = string(tc.excludeSub(:))'
    keep = keep & ~contains(sub, s);
end
Tc = Tdet(keep, :);

P = cell(1, n);                                          % P{k} = [cx cy] of candidates in frame k
for k = 1:n
    if any(k == dropFrames)
        P{k} = zeros(0, 2);
    else
        P{k} = [Tc.cx(Tc.frame == k), Tc.cy(Tc.frame == k)];
    end
end

%% Kalman model (dt = 1 frame)
dt = 1;
F = [1 0 dt 0; 0 1 0 dt; 0 0 1 0; 0 0 0 1];
G = [dt^2/2 0; 0 dt^2/2; dt 0; 0 dt];
Q = tc.sigmaAcc^2 * (G * G');
H = [1 0 0 0; 0 1 0 0];
Rm = tc.sigmaMeas^2 * eye(2);

%% Seed + grow tracks
cands = {};
for a = 1:n-1
    for b = a+1:min(n, a+1+tc.maxMiss)
        for ia = 1:size(P{a}, 1)
            for ib = 1:size(P{b}, 1)
                v  = (P{b}(ib,:) - P{a}(ia,:)) / ((b - a) * dt);
                sp = norm(v);
                if sp < tc.velMin || sp > tc.velMax, continue; end
                trk = growTrack(a, ia, b, ib, P, n, tc, F, Q, H, Rm);
                if sum(trk.hit) >= tc.minHits, cands{end+1} = trk; end %#ok<AGROW>
            end
        end
    end
end
nCand = numel(cands);
tracks = {};
if nCand == 0, return; end

%% Select best non-overlapping tracks (greedy by score)
score = cellfun(@(t) sum(t.hit) - 0.3*sum(~t.hit) - 0.1*mean(t.chi(t.hit)), cands);
[~, ord] = sort(score, 'descend');
used = zeros(0, 2);
for q = ord(:)'
    t = cands{q};
    pairs = [t.frame(t.hit)', t.det(t.hit)'];
    if any(ismember(pairs, used, 'rows')), continue; end
    used = [used; pairs]; %#ok<AGROW>
    t.id = numel(tracks) + 1;
    tracks{end+1} = t; %#ok<AGROW>
end

%% Dead-reckoning prediction beyond the last frame
for q = 1:numel(tracks)
    t = tracks{q};  x = t.x(:, end);  Pc = t.P(:,:,end);
    fut = zeros(tc.predictAhead, 4);  futP = zeros(2, 2, tc.predictAhead);
    for s = 1:tc.predictAhead
        x = F * x;  Pc = F * Pc * F' + Q;
        fut(s,:) = x';  futP(:,:,s) = Pc(1:2, 1:2);
    end
    t.future = fut;  t.futureCov = futP;
    t.futureFrames = t.frame(end) + (1:tc.predictAhead);
    t.speed   = hypot(t.x(3,end), t.x(4,end));
    t.heading = atan2d(-t.x(4,end), t.x(3,end));     % deg, 0 = right, 90 = up (image y points down)
    tracks{q} = t;
end
end

%% ---------------- Local functions ----------------
function trk = growTrack(a, ia, b, ib, P, n, tc, F, Q, H, Rm)
x  = [P{a}(ia,:)'; (P{b}(ib,:) - P{a}(ia,:))' / (b - a)];
Pc = diag([tc.sigmaMeas^2, tc.sigmaMeas^2, 25, 25]);
trk.frame = a;  trk.det = ia;  trk.x = x;  trk.P = Pc;
trk.hit = true; trk.chi = 0;  trk.z = P{a}(ia,:)';      % z = measured centroid (NaN when coasted)
miss = 0;
for f = a+1:n
    x = F * x;  Pc = F * Pc * F' + Q;                    % predict
    S = H * Pc * H' + Rm;
    best = 0;  bd = inf;
    for m = 1:size(P{f}, 1)
        nu = P{f}(m,:)' - H * x;
        d2 = nu' / S * nu;                               % Mahalanobis^2
        if d2 < bd, bd = d2; best = m; end
    end
    if bd < tc.gateChi2
        K  = Pc * H' / S;
        x  = x + K * (P{f}(best,:)' - H * x);            % update
        Pc = (eye(4) - K * H) * Pc;
        hit = true;  miss = 0;  id = best;  chi = bd;  z = P{f}(best,:)';
    else
        hit = false; miss = miss + 1;  id = 0;  chi = NaN;  z = [NaN; NaN];   % dead reckoning
    end
    trk.frame(end+1) = f;  trk.det(end+1) = id;  trk.x(:,end+1) = x;
    trk.P(:,:,end+1) = Pc; trk.hit(end+1) = hit; trk.chi(end+1) = chi;
    trk.z(:,end+1) = z;
    if miss > tc.maxMiss, break; end
end
while ~trk.hit(end)                                      % trim trailing coasts
    trk.frame(end) = [];  trk.det(end) = [];  trk.x(:,end) = [];
    trk.P(:,:,end) = [];  trk.hit(end) = [];  trk.chi(end) = [];  trk.z(:,end) = [];
end
end