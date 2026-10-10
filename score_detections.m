function m = score_detections(Tdet, truth, n, radius)
% SCORE_DETECTIONS  Per-frame precision / recall / F1 of debris candidates.
%   truth(k,2:3) = [x y] of the true debris in frame k (NaN row = absent).
%   A frame is a TP if any candidate lies within `radius` px of truth.
%   Every other candidate in a frame (including duplicates on the truth) is an FP.
TP = 0; FP = 0; FN = 0;
for k = 1:n
    hasTruth = k <= size(truth, 1) && ~any(isnan(truth(k, 2:3)));
    c  = Tdet(Tdet.frame == k & Tdet.isCandidate, :);
    nc = height(c);
    hit = false;
    if hasTruth && nc > 0
        d   = hypot(c.cx - truth(k,2), c.cy - truth(k,3));
        hit = any(d <= radius);
        FP  = FP + nc - hit;
    else
        FP  = FP + nc;
    end
    if hasTruth
        TP = TP + hit;  FN = FN + ~hit;
    end
end
prec = TP / max(TP + FP, 1);
rec  = TP / max(TP + FN, 1);
m = struct('TP', TP, 'FP', FP, 'FN', FN, 'precision', prec, 'recall', rec, ...
    'F1', 2*prec*rec / max(prec + rec, eps));
end