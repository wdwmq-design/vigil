function s = score_tracks(tracks, truth, n, radius)
% SCORE_TRACKS  Track-level scoring against ground truth (scoring only).
%
% A track is TRUE if at least half of its measured hits lie within `radius` px
% of the truth in the same frame; otherwise it is a FALSE track.
%   trackPrecision = true tracks / all tracks
%   frameRecall    = truth frames covered by a measured hit of a true track
%   frameRecallCoast = same, but a coasted (dead-reckoned) position also counts
%   best           = index of the true track with the most hits (0 if none)
nT = numel(tracks);
truthFrames = find(~isnan(truth(1:min(n, size(truth,1)), 2)));
coveredHit = false(n, 1);  coveredAny = false(n, 1);
isTrue = false(1, nT);  hits = zeros(1, nT);  near = zeros(1, nT);  rmse = nan(1, nT);

for q = 1:nT
    t  = tracks{q};
    fr = t.frame(:);
    tr = nan(numel(fr), 2);
    ok = fr <= size(truth, 1);
    tr(ok, :) = truth(fr(ok), 2:3);
    err = hypot(t.x(1,:)' - tr(:,1), t.x(2,:)' - tr(:,2));
    nearHit = t.hit(:) & err <= radius;
    nearAny = err <= radius;
    hits(q) = sum(t.hit);  near(q) = sum(nearHit);
    rmse(q) = sqrt(mean(err(~isnan(err)).^2));
    isTrue(q) = near(q) >= 0.5 * hits(q);
    if isTrue(q)
        coveredHit(fr(nearHit)) = true;
        coveredAny(fr(nearAny)) = true;
    end
end

nTrue = sum(isTrue);
s.nTracks = nT;  s.nTrue = nTrue;  s.nFalse = nT - nTrue;
s.trackPrecision   = nTrue / max(nT, 1);
s.frameRecall      = sum(coveredHit(truthFrames)) / max(numel(truthFrames), 1);
s.frameRecallCoast = sum(coveredAny(truthFrames)) / max(numel(truthFrames), 1);
s.trackF1 = 2 * s.trackPrecision * s.frameRecall / max(s.trackPrecision + s.frameRecall, eps);
s.isTrue = isTrue;  s.hits = hits;  s.hitsNearTruth = near;  s.rmse = rmse;
if nTrue > 0
    h = hits;  h(~isTrue) = -1;
    [~, s.best] = max(h);
else
    s.best = 0;
end
end