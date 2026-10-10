function [Tdet, info, Zstore] = detect_core(stack, cfg)
% DETECT_CORE  Per-frame debris-candidate detection. NO ground truth is used.
%
%   [Tdet, info, Zstore] = detect_core(stack, cfg)
%
% Pipeline per frame
%   1. Background  : temporal median over all frames (or spatial fallback)
%   2. Noise       : MAD (1.4826*median|x-med|) in bins of background level -> sigma(x,y)
%   3. Matched Gaussian smoothing, normalised to an SNR image Z
%   4. Threshold   : T = min(max(kSigma, Otsu), tMax)
%   5. Connected components (8-conn), min-area filter, dash grouping, regionprops
%   5b. Stationary-object rejection (same position in >= N frames)
%   6. Rule-based class: compact / streak-like / artifact-like / unknown
%
% Feature vector stored per region: [area, elongation, meanZ (contrast in sigma),
% contrast (mean counts above background), length].
% Needs the Image Processing Toolbox (bwconncomp, regionprops, imclose).

n = size(stack, 3);

bgMode = cfg.bgMode;
if strcmp(bgMode, 'temporal') && n < 3
    warning('detect_core:fewFrames', 'Temporal median needs >= 3 frames; using spatial background.');
    bgMode = 'spatial';
elseif strcmp(bgMode, 'temporal') && n < 5
    warning('detect_core:fewFrames', ...
        'Only %d frames: the temporal median is a weak background estimate.', n);
end
if strcmp(bgMode, 'temporal'), bgAll = median(stack, 3); end

% Gaussian matched-filter kernel
r = ceil(3 * cfg.smoothSigma);
[gx, gy] = meshgrid(-r:r);
g = exp(-(gx.^2 + gy.^2) / (2 * cfg.smoothSigma^2));  g = g / sum(g(:));
noiseGain = sqrt(sum(g(:).^2));        % std of smoothed white noise / std of raw
se = strel('disk', cfg.dashGap);

rows = {};
info = struct('sig0', {}, 'otsuT', {}, 'T', {});
Zstore = cell(1, n);
if cfg.verbose
    fprintf('Frame | sigma0  | sigma range   | Otsu T | final T | regions\n');
end

for k = 1:n
    img = stack(:,:,k);
    if strcmp(bgMode, 'temporal'), bg = bgAll; else, bg = skyBackground(img); end

    D = img - bg;
    D = D - median(D(:));                                  % remove global offset

    %% 2. Noise (MAD)
    sig0 = 1.4826 * median(abs(D(:) - median(D(:))));      % global robust sigma
    sig0 = max(sig0, eps);
    sigMap = noiseMap(D, bg, cfg.noiseBins, sig0);         % sigma(x,y)

    %% 3. Matched smoothing -> SNR image
    Z    = conv2(D, g, 'same') ./ (sigMap * noiseGain);
    Zraw = D ./ sigMap;
    if nargout > 2, Zstore{k} = Z; end

    %% 4. Threshold: adaptive + Otsu
    zc    = min(Z(:), cfg.otsuClip);
    tail  = zc(zc > cfg.otsuFloor);
    otsuT = otsuThreshold(tail, cfg.otsuFloor, cfg.otsuClip, 128);
    T     = min(max(cfg.kSigma, otsuT), cfg.tMax);
    mask  = Z > T;                                         % == (smoothed D) > T*sigma(x,y)

    %% 5. Connected components + min-area filter + grouping
    ccRaw = bwconncomp(mask, 8);
    keepCC = cellfun(@numel, ccRaw.PixelIdxList) >= cfg.minArea;
    ccRaw.PixelIdxList = ccRaw.PixelIdxList(keepCC);
    ccRaw.NumObjects   = numel(ccRaw.PixelIdxList);
    Lraw  = labelmatrix(ccRaw);
    maskC = Lraw > 0;                                      % min-area filtered mask
    info(k) = struct('sig0', sig0, 'otsuT', otsuT, 'T', T);
    if cfg.verbose
        fprintf('%5d | %7.3f | %5.2f - %5.2f | %6.2f | %7.2f | %d\n', k, sig0, ...
                min(sigMap(:)), max(sigMap(:)), otsuT, T, ccRaw.NumObjects);
    end
    if ccRaw.NumObjects == 0, continue; end

    closedMask = imclose(maskC, se);
    ccG = bwconncomp(closedMask, 8);
    Lg  = double(labelmatrix(ccG)) .* maskC;               % mask pixels labelled by group
    ng  = ccG.NumObjects;

    props = regionprops(Lg, Z, 'Area', 'WeightedCentroid', ...
        'MajorAxisLength', 'MinorAxisLength', 'Orientation', 'BoundingBox', ...
        'MaxIntensity', 'MeanIntensity', 'PixelIdxList');
    propsD = regionprops(Lg, D, 'MeanIntensity');          % contrast in raw counts
    lab = Lg(maskC);
    peakRaw = accumarray(lab, Zraw(maskC), [ng 1], @max);

    %% 6. Features + rule-based classification
    for i = 1:ng
        if isempty(props(i).PixelIdxList), continue; end
        area  = props(i).Area;
        major = props(i).MajorAxisLength;  minor = props(i).MinorAxisLength;
        len   = 0.866 * major;                             % ellipse axis -> line length
        elong = major / max(minor, 1);
        meanZ = props(i).MeanIntensity;
        dashes = numel(unique(Lraw(props(i).PixelIdxList)));

        if peakRaw(i) > cfg.artifactZ && area <= cfg.artifactMaxArea
            cls = 'artifact-like';  sub = 'sharp (cosmic ray / hot pixel)';
        elseif dashes >= cfg.minDashes && len >= cfg.dashMinLen
            cls = 'streak-like';    sub = 'dashed (aircraft-like)';
        elseif len >= cfg.minStreakLen && elong >= cfg.elongMin
            if meanZ < cfg.minContrastZ
                cls = 'unknown';    sub = '';              % too faint to trust as a streak
            else
                cls = 'streak-like';
                if len >= cfg.longStreak, sub = 'long (satellite-like)'; else, sub = 'short'; end
            end
        elseif len < cfg.minStreakLen && elong < cfg.elongMin
            cls = 'compact';        sub = '';
        else
            cls = 'unknown';        sub = '';
        end

        row = struct();
        row.frame = k;  row.id = i;
        row.cx = props(i).WeightedCentroid(1);             % SNR-weighted centroid
        row.cy = props(i).WeightedCentroid(2);
        row.area = area;  row.major = major;  row.minor = minor;
        row.length = len;  row.elongation = elong;
        row.orientation = props(i).Orientation;
        row.meanZ = meanZ;  row.peakZ = props(i).MaxIntensity;
        row.contrast = propsD(i).MeanIntensity;
        row.peakZraw = peakRaw(i);  row.dashCount = dashes;
        row.class = cls;  row.subtype = sub;
        row.isCandidate = strcmp(cls, 'streak-like') && strcmp(sub, 'short');
        row.bboxX = props(i).BoundingBox(1);  row.bboxY = props(i).BoundingBox(2);
        row.bboxW = props(i).BoundingBox(3);  row.bboxH = props(i).BoundingBox(4);
        rows{end+1} = row; %#ok<AGROW>
    end
end

if isempty(rows)
    Tdet = emptyTable();
    return;
end
Tdet = struct2table(vertcat(rows{:}));

%% 5b. Stationary-object rejection
% Debris moves tens of px/frame; a candidate at the same pixel in several
% frames is a fixed object (hot cluster / defect), not debris.
minF = min(cfg.stationaryMinFrames, n);
isStat = false(height(Tdet), 1);
for i = 1:height(Tdet)
    d = hypot(Tdet.cx - Tdet.cx(i), Tdet.cy - Tdet.cy(i));
    isStat(i) = numel(unique(Tdet.frame(d < cfg.stationaryRadius))) >= minF;
end
sel = isStat & ismember(Tdet.class, {'streak-like', 'unknown'});
Tdet.class(sel)       = {'artifact-like'};
Tdet.subtype(sel)     = {'stationary (fixed object)'};
Tdet.isCandidate(sel) = false;
if cfg.verbose, fprintf('Stationary objects rejected: %d\n', nnz(sel)); end
end

%% ---------------- Local functions ----------------
function Tz = emptyTable()
row = struct('frame', 0, 'id', 0, 'cx', 0, 'cy', 0, 'area', 0, 'major', 0, 'minor', 0, ...
    'length', 0, 'elongation', 0, 'orientation', 0, 'meanZ', 0, 'peakZ', 0, 'contrast', 0, ...
    'peakZraw', 0, 'dashCount', 0, 'class', 'x', 'subtype', 'x', 'isCandidate', false, ...
    'bboxX', 0, 'bboxY', 0, 'bboxW', 0, 'bboxH', 0);
Tz = struct2table(row);
Tz(1, :) = [];
end

function sigMap = noiseMap(D, bg, nb, sig0)
% Robust (MAD) noise sigma as a function of background brightness.
    N = numel(bg);
    s = sort(bg(:));
    edges = unique(s(round(linspace(1, N, nb + 1))));
    if numel(edges) < 3
        sigMap = sig0 * ones(size(bg));  return;
    end
    [~, ~, bin] = histcounts(bg(:), edges);
    centers = nan(1, numel(edges) - 1);  sigs = centers;
    for i = 1:numel(centers)
        sel = bin == i;
        if nnz(sel) < 50, continue; end
        v = D(sel);
        centers(i) = mean(bg(sel));
        sigs(i) = 1.4826 * median(abs(v - median(v)));
    end
    ok = ~isnan(centers) & sigs > 0;
    if nnz(ok) < 2
        sigMap = sig0 * ones(size(bg));  return;
    end
    cs = centers(ok);  ss = sigs(ok);
    [cu, ia] = unique(cs);  su = ss(ia);
    if numel(cu) < 2
        sigMap = sig0 * ones(size(bg));  return;
    end
    sigMap = interp1(cu, su, bg, 'linear', 'extrap');
    sigMap = max(sigMap, 0.5 * sig0);
end

function t = otsuThreshold(vals, lo, hi, nb)
% Otsu's method: threshold maximising between-class variance of a histogram.
    if isempty(vals), t = lo; return; end
    edges = linspace(lo, hi, nb + 1);
    h = histcounts(vals, edges);
    if sum(h) == 0, t = lo; return; end
    p = h / sum(h);
    centers = (edges(1:end-1) + edges(2:end)) / 2;
    w0 = cumsum(p);  mu = cumsum(p .* centers);  muT = mu(end);
    sb = (muT * w0 - mu).^2 ./ (w0 .* (1 - w0));
    sb(~isfinite(sb)) = 0;
    [~, i] = max(sb);
    t = centers(i);
end

function bg = skyBackground(img)
% Spatial fallback: heavy median filter on a down-sampled copy (removes stars).
    small = imresize(img, 1/8, 'bilinear');
    small = medfilt2(small, [15 15], 'symmetric');
    bg = imresize(small, size(img), 'bilinear');
end