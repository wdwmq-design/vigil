%% make_debris_dataset.m
% Stage 2: takes YOUR star BMPs and produces a test sequence with
%   - realistic detector noise (shot, read, column pattern, sky gradient)
%   - hot pixels, dead pixels, stuck-bright pixels, a dead column, a hot column
%   - cosmic rays (random each frame)
%   - ONE small debris object moving in a straight line across ALL frames
%     (short streak per frame, slight brightness flicker = tumbling)
%   - distractor streaks: satellite (frame 2), aircraft w/ dashes (frame 3),
%     meteor (frame 4)
%
% Base MATLAB only. Put the script in the same folder as your BMPs.
% Outputs: <folder>\data\frames_bmp_debris\debris_01.bmp ...
%          <folder>\data\debris_truth.mat / debris_truth.csv
%          <folder>\data\debris_preview.png

clear; clc; close all;

%% ---------------- Configuration ----------------
cfg.nFrames   = 5;
cfg.seed      = 11;

% --- noise (same meaning as before) ---
cfg.ePerLevel = 4;     cfg.skyBase = 60;     cfg.skyGrad = 0.35;
cfg.vignette  = 0.20;  cfg.skyDrift = 0.04;  cfg.darkLevel = 8;
cfg.readNoise = 6;     cfg.colFPN = 0.6;     cfg.bias = 3;
cfg.hotFrac   = 5e-4;  cfg.hotRange = [150 900];
cfg.crMean    = 3;     cfg.crRange = [300 1000];

% --- detector defects ---
cfg.deadFrac    = 4e-4;      % dead pixels (read 0 always)
cfg.stuckFrac   = 1e-4;      % stuck-bright pixels (read 255 always)
cfg.nDeadCols   = 1;         % dead column segments
cfg.nHotCols    = 1;         % hot (elevated) column segments
cfg.colSegLen   = [150 400]; % rows

% --- the debris object (moves in a straight line, start -> stop) ---
deb.startFrac = [0.12 0.70];  % [x y] as fraction of width/height, frame 1
deb.stopFrac  = [0.88 0.30];  % [x y] in last frame
deb.len       = 14;           % streak length in px (motion during exposure)
deb.flux      = 3500;         % total e- per frame (lower = fainter)
deb.flicker   = 0.25;         % fractional brightness modulation (tumble)
deb.period    = 3.2;          % tumble period in frames
deb.sigma     = [1.2 1.6];    % PSF sigma range (px), random per frame

%% ---------------- Paths / read ----------------
here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd; end
inDir  = here;                                   % BMPs live next to this script
outDir = fullfile(here, 'data', 'frames_bmp_debris');
if ~exist(outDir,'dir'), mkdir(outDir); end

files = dir(fullfile(inDir, '*.bmp'));
[~, order] = sort({files.name});  files = files(order);
if isempty(files), error('No .bmp files found in %s', inDir); end
n = min(cfg.nFrames, numel(files));
first = readGray(fullfile(inDir, files(1).name));
[R, C] = size(first);
rng(cfg.seed);

P = @(fx, fy) [fx*C, fy*R];                      % fraction -> pixels

%% ---------------- Fixed detector pattern ----------------
[X, Y] = meshgrid(1:C, 1:R);
Xn = (X - C/2)/C;  Yn = (Y - R/2)/R;
vig = 1 - cfg.vignette * (Xn.^2 + Yn.^2) / 0.5;
th = 2*pi*rand;
gradMap = 1 + cfg.skyGrad*2*(cos(th)*Xn + sin(th)*Yn);

nHot = round(cfg.hotFrac*R*C);
hotIdx = randperm(R*C, nHot);
hotMask = false(R, C);  hotMask(hotIdx) = true;
hotAmp = zeros(R, C);
lr = log(cfg.hotRange);
hotAmp(hotIdx) = exp(lr(1) + (lr(2)-lr(1))*rand(1, nHot));

deadMask  = false(R, C);  deadMask(randperm(R*C, round(cfg.deadFrac*R*C)))  = true;
stuckMask = false(R, C);  stuckMask(randperm(R*C, round(cfg.stuckFrac*R*C))) = true;
deadMask(stuckMask) = false;

deadColMask = false(R, C);  hotColAmp = zeros(R, C);
for i = 1:cfg.nDeadCols
    c = randi(C);  L = randi(cfg.colSegLen);  r0 = randi(max(1, R-L));
    deadColMask(r0:min(R, r0+L), c) = true;
end
for i = 1:cfg.nHotCols
    c = randi(C);  L = randi(cfg.colSegLen);  r0 = randi(max(1, R-L));
    hotColAmp(r0:min(R, r0+L), c) = 40;           % e- extra
end
colPattern = cfg.colFPN * randn(1, C);

%% ---------------- Debris trajectory (ground truth) ----------------
p0 = P(deb.startFrac(1), deb.startFrac(2));
p1 = P(deb.stopFrac(1),  deb.stopFrac(2));
vel = (p1 - p0) / max(n-1, 1);                    % px per frame
u = vel / norm(vel);
phi = 2*pi*rand;
truth = zeros(n, 8);   % frame, cx, cy, x1, y1, x2, y2, flux

%% ---------------- Frame loop ----------------
stack = zeros(R, C, n, 'uint8');
crMasks = false(R, C, n);
debrisMasks = false(R, C, n);
extraNote = cell(n, 1);

for k = 1:n
    img = readGray(fullfile(inDir, files(k).name));
    if ~isequal(size(img), [R C])
        error('%s has a different size than the first image.', files(k).name);
    end

    e   = double(img) * cfg.ePerLevel .* vig;
    sky = cfg.skyBase*(1 + cfg.skyDrift*randn) * gradMap .* vig;

    % ---- inject objects (electrons) ----
    inj = zeros(R, C);

    % debris: short streak centred on its position for this frame
    c  = p0 + vel*(k-1);
    ha = deb.len/2;
    a  = c - u*ha;   b = c + u*ha;
    fk = deb.flux * (1 + deb.flicker*sin(2*pi*(k-1)/deb.period + phi));
    sg = deb.sigma(1) + diff(deb.sigma)*rand;
    dEl = addSegment(zeros(R, C), a(1), a(2), b(1), b(2), fk/deb.len, sg, 0, 1);
    inj = inj + dEl;
    debrisMasks(:,:,k) = dEl > 3;
    truth(k,:) = [k, c(1), c(2), a(1), a(2), b(1), b(2), fk];

    % distractors
    if k == 2          % satellite: long, faint, continuous
        s1 = P(0.00, 0.20);  s2 = P(1.00, 0.48);
        inj = addSegment(inj, s1(1), s1(2), s2(1), s2(2), 45, 1.5, 0, 1);
        extraNote{k} = 'satellite streak';
    elseif k == 3      % aircraft: bright, dashed (strobe)
        s1 = P(0.05, 0.88);  s2 = P(0.62, 0.97);
        inj = addSegment(inj, s1(1), s1(2), s2(1), s2(2), 200, 1.6, 40, 0.5);
        extraNote{k} = 'aircraft (dashed)';
    elseif k == 4      % meteor: short, very bright, one frame only
        s1 = P(0.30, 0.12);  s2 = s1 + 38*[cosd(25) sind(25)];
        inj = addSegment(inj, s1(1), s1(2), s2(1), s2(2), 450, 1.4, 0, 1);
        extraNote{k} = 'meteor';
    end

    signal = max(e + sky + cfg.darkLevel + hotAmp + hotColAmp + inj, 0);
    noisy  = signal + sqrt(signal) .* randn(R, C);

    % cosmic rays
    crMask = false(R, C);
    nCR = sum(rand(1, 50) < cfg.crMean/50);
    for q = 1:nCR
        len = 1 + floor(6*rand);  ang = 2*pi*rand;
        px = 1 + (C-1)*rand;      py = 1 + (R-1)*rand;
        amp = cfg.crRange(1) + diff(cfg.crRange)*rand;
        for t = 0:len-1
            ix = round(px + t*cos(ang));  iy = round(py + t*sin(ang));
            if ix>=1 && ix<=C && iy>=1 && iy<=R
                noisy(iy, ix) = noisy(iy, ix) + amp*(0.6 + 0.8*rand);
                crMask(iy, ix) = true;
            end
        end
    end

    noisy = noisy + cfg.readNoise*randn(R, C);
    out = noisy/cfg.ePerLevel + cfg.bias + repmat(colPattern, R, 1);
    out = min(max(out, 0), 255);
    out(deadMask | deadColMask) = 0;       % dead pixels / dead column
    out(stuckMask) = 255;                  % stuck-bright pixels
    out = uint8(round(out));

    stack(:,:,k) = out;
    crMasks(:,:,k) = crMask;
    imwrite(out, fullfile(outDir, sprintf('debris_%02d.bmp', k)));
    fprintf('Frame %d: debris at (%.0f, %.0f)  flux %.0f e-  CR hits %d  %s\n', ...
            k, c(1), c(2), fk, nCR, extraNote{k});
end

%% ---------------- Save ground truth ----------------
dataDir = fullfile(here, 'data');
save(fullfile(dataDir, 'debris_truth.mat'), 'cfg', 'deb', 'truth', 'vel', ...
     'hotMask', 'deadMask', 'stuckMask', 'deadColMask', 'crMasks', ...
     'debrisMasks', 'extraNote');
fid = fopen(fullfile(dataDir, 'debris_truth.csv'), 'w');
fprintf(fid, 'frame,cx,cy,x1,y1,x2,y2,flux_e\n');
fprintf(fid, '%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f\n', truth');
fclose(fid);

%% ---------------- Preview ----------------
fig = figure('Color','k','Position',[30 30 1450 700]);
for k = 1:n
    subplot(2, 3, k); imshow(stack(:,:,k)); hold on;
    plot(truth(k,2), truth(k,3), 'o', 'Color', [1 0.2 0.2], 'MarkerSize', 22, 'LineWidth', 1.2);
    ttl = sprintf('Frame %d  (red circle = debris)', k);
    if ~isempty(extraNote{k}), ttl = [ttl ' + ' extraNote{k}]; end
    title(ttl, 'Color', 'w', 'FontSize', 9);
end
subplot(2, 3, 6); imshow(stack(:,:,1)); hold on;
plot(truth(:,2), truth(:,3), 'r-o', 'LineWidth', 1.5, 'MarkerSize', 6);
for k = 1:n, text(truth(k,2)+8, truth(k,3)-8, num2str(k), 'Color', 'y'); end
title('Debris path across all frames (ground truth)', 'Color', 'w', 'FontSize', 9);
saveas(fig, fullfile(dataDir, 'debris_preview.png'));
fprintf('\nDone. Frames in %s\n', outDir);

%% ---------------- Local functions ----------------
function g = readGray(path)
    im = imread(path);
    if ndims(im) == 3, im = im(:,:,1); end
    if ~isa(im, 'uint8')
        im = uint8(double(im) / double(intmax(class(im))) * 255);
    end
    g = im;
end

function E = addSegment(E, x1, y1, x2, y2, fluxPerLen, sigma, period, duty)
% Line segment convolved with a Gaussian PSF (erf profile along the streak).
% fluxPerLen = electrons per pixel of streak length. period>0 -> dashed.
    L = hypot(x2-x1, y2-y1);
    if L < 1e-6, return; end
    ux = (x2-x1)/L;  uy = (y2-y1)/L;
    if period <= 0
        E = drawOne(E, x1, y1, x2, y2, fluxPerLen, sigma);
    else
        s0 = 0;
        while s0 < L
            s1 = min(s0 + period*duty, L);
            E = drawOne(E, x1+ux*s0, y1+uy*s0, x1+ux*s1, y1+uy*s1, fluxPerLen, sigma);
            s0 = s0 + period;
        end
    end
end

function E = drawOne(E, x1, y1, x2, y2, fpl, sigma)
    [R, C] = size(E);
    L  = hypot(x2-x1, y2-y1);
    cx = (x1+x2)/2;  cy = (y1+y2)/2;
    ux = (x2-x1)/L;  uy = (y2-y1)/L;
    m  = ceil(5*sigma);
    xa = max(1, floor(min(x1,x2))-m);  xb = min(C, ceil(max(x1,x2))+m);
    ya = max(1, floor(min(y1,y2))-m);  yb = min(R, ceil(max(y1,y2))+m);
    if xa > xb || ya > yb, return; end
    [xx, yy] = meshgrid(xa:xb, ya:yb);
    s = (xx-cx)*ux + (yy-cy)*uy;            % along-track coordinate
    d = -(xx-cx)*uy + (yy-cy)*ux;           % perpendicular distance
    a = sqrt(2)*sigma;
    along = 0.5*(erf((s+L/2)/a) - erf((s-L/2)/a));
    perp  = exp(-d.^2/(2*sigma^2)) / (sqrt(2*pi)*sigma);
    E(ya:yb, xa:xb) = E(ya:yb, xa:xb) + fpl*along.*perp;
end