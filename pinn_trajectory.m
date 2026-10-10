function out = pinn_trajectory(tObs, zObs, tQuery, opts)
% PINN_TRAJECTORY  Physics-informed neural-network trajectory estimate.
% No toolboxes needed: a one-hidden-layer tanh network is trained with
% hand-derived back-propagation and Adam.
%
%   out = pinn_trajectory(tObs, zObs, tQuery [, opts])
%
%   tObs   m x 1 frames with a measured centroid (m >= 3)
%   zObs   m x 2 measured [x y]
%   tQuery q x 1 frames to evaluate (inside or beyond the observations)
%
% Model:   z(t) = line(t) + sigma * NN((t - t0)/Ts)
%   line(t) : least-squares constant-velocity fit (the "physics" baseline;
%             zero acceleration by construction)
%   NN      : small tanh network allowed to bend the path
%
% Loss = DATA + PHYSICS + weight decay
%   DATA    = mean over points of ((NN - residual)/sigma)^2         (motion-data loss)
%   PHYSICS = lambdaAcc * mean over collocation points of
%             (a(t)/accScale)^2,  a = d2z/dt2 from the analytic 2nd derivative of the
%             network                                                (acceleration penalty)
% Collocation points span the observations AND the query horizon, so the
% network is regularised towards low acceleration where it extrapolates.
%
% An ensemble of nEnsemble networks (different random inits) is trained; the
% spread of their predictions is returned as predStd (an empirical uncertainty,
% not a calibrated confidence interval).
%
% out.fit      m x 2   smoothed positions at tObs
% out.pred     q x 2   mean prediction at tQuery
% out.predStd  q x 2   ensemble std at tQuery
% out.linear   q x 2   line-only prediction at tQuery (baseline)
% out.velEnd   1 x 2   velocity at the last observation (px/frame)
% out.accRms   scalar  rms acceleration over collocation points (px/frame^2)
% out.dataRmse scalar  rms of (fit - measurement) in px
if nargin < 4 || isempty(opts), opts = struct(); end
o = fillDefaults(opts);

tObs = tObs(:);  tQuery = tQuery(:);
m = numel(tObs);
if m < 3, error('pinn_trajectory:tooFew', 'Need at least 3 measurements.'); end
if size(zObs, 1) ~= m, error('pinn_trajectory:size', 'zObs must be m x 2.'); end

t0 = tObs(1);
Ts = max(tObs(end) - t0, 1);                       % time scale = observation span
sg = o.sigmaMeas;

% Constant-velocity baseline per axis
pl = zeros(2, 2);                                  % [slope intercept] per axis
for d = 1:2, pl(d,:) = polyfit(tObs - t0, zObs(:,d), 1); end
baseObs = [polyval(pl(1,:), tObs - t0), polyval(pl(2,:), tObs - t0)];
Rn = ((zObs - baseObs) / sg)';                     % 2 x m, residuals in sigma units

tnObs = ((tObs - t0) / Ts)';                       % 1 x m
tMax  = max([tObs; tQuery]);
tnC   = linspace(0, (tMax - t0) / Ts, o.nColloc);  % 1 x M collocation points
tnQ   = ((tQuery - t0) / Ts)';
kk    = sg / (Ts^2 * o.accScale);                  % maps NN 2nd derivative -> a / accScale

s0 = rng;  cleanupObj = onCleanup(@() rng(s0));    % don't disturb the caller's RNG
K = o.nEnsemble;
fitAll = zeros(m, 2, K);  predAll = zeros(numel(tQuery), 2, K);
velAll = zeros(K, 2);  accAll = zeros(K, 1);
for e = 1:K
    rng(o.seed + e);
    net = trainOne(tnObs, Rn, tnC, kk, o);
    [Yo, ~]  = netEval(net, tnObs);
    [Yq, ~]  = netEval(net, tnQ);
    [~, dYe] = netEval(net, tnObs(end));
    [~, d2]  = netD2(net, tnC);
    fitAll(:,:,e)  = baseObs + sg * Yo';
    predAll(:,:,e) = [polyval(pl(1,:), tQuery - t0), polyval(pl(2,:), tQuery - t0)] + sg * Yq';
    velAll(e,:)    = [pl(1,1), pl(2,1)] + sg * dYe' / Ts;
    accAll(e)      = sqrt(mean((sg * d2(:) / Ts^2).^2));              % rms a in px/frame^2
end

out.fit      = mean(fitAll, 3);
out.pred     = mean(predAll, 3);
if K > 1, out.predStd = std(predAll, 0, 3); else, out.predStd = zeros(size(out.pred)); end
out.linear   = [polyval(pl(1,:), tQuery - t0), polyval(pl(2,:), tQuery - t0)];
out.velEnd   = mean(velAll, 1);
out.accRms   = mean(accAll);
out.dataRmse = sqrt(mean(sum((out.fit - zObs).^2, 2)));
end

%% ---------------- Local functions ----------------
function o = fillDefaults(u)
o = struct('hidden', 8, 'epochs', 3000, 'lr', 0.01, 'lambdaAcc', 1, 'accScale', 0.5, ...
           'sigmaMeas', 2, 'nColloc', 40, 'weightDecay', 1e-4, 'nEnsemble', 5, 'seed', 1);
f = fieldnames(u);
for i = 1:numel(f), o.(f{i}) = u.(f{i}); end
end

function net = trainOne(tnObs, Rn, tnC, kk, o)
% Adam on  L = mean((Y - Rn)^2) + lambda*kk^2*mean(Y''^2) + wd*(|W1|^2+|W2|^2)
H = o.hidden;
W1 = randn(H, 1);  b1 = 0.5 * randn(H, 1);
W2 = 0.1 * randn(2, H);  b2 = zeros(2, 1);
p  = {W1, b1, W2, b2};
mA = cellfun(@(a) zeros(size(a)), p, 'UniformOutput', false);
vA = mA;
beta1 = 0.9;  beta2 = 0.999;  epsA = 1e-8;
for it = 1:o.epochs
    W1 = p{1}; b1 = p{2}; W2 = p{3}; b2 = p{4};

    % ---- data loss ----
    Hh = tanh(W1 * tnObs + b1);                    % H x m
    Y  = W2 * Hh + b2;                             % 2 x m
    E  = Y - Rn;
    dY = 2 * E / numel(E);
    gW2 = dY * Hh';  gb2 = sum(dY, 2);
    dA  = (W2' * dY) .* (1 - Hh.^2);
    gW1 = dA * tnObs';  gb1 = sum(dA, 2);

    % ---- physics loss: acceleration penalty at collocation points ----
    S  = tanh(W1 * tnC + b1);                      % H x M
    s1 = 1 - S.^2;
    g  = -2 * S .* s1;                             % d/dA of (1-tanh^2)  = -2 tanh (1-tanh^2)
    gp = -2 * s1 .* (1 - 3 * S.^2);                % derivative of g
    w1sq = W1.^2;
    Mm = w1sq .* g;                                % H x M
    d2 = W2 * Mm;                                  % 2 x M  (NN 2nd derivative, normalised time)
    dd2 = o.lambdaAcc * kk^2 * 2 * d2 / numel(d2);
    gW2 = gW2 + dd2 * Mm';
    dMm = W2' * dd2;                               % H x M
    gW1 = gW1 + sum(dMm .* (2 * W1 .* g + w1sq .* gp .* tnC), 2);
    gb1 = gb1 + sum(dMm .* (w1sq .* gp), 2);

    % ---- weight decay ----
    gW1 = gW1 + 2 * o.weightDecay * W1;
    gW2 = gW2 + 2 * o.weightDecay * W2;

    G = {gW1, gb1, gW2, gb2};
    for j = 1:4
        mA{j} = beta1 * mA{j} + (1 - beta1) * G{j};
        vA{j} = beta2 * vA{j} + (1 - beta2) * G{j}.^2;
        mh = mA{j} / (1 - beta1^it);
        vh = vA{j} / (1 - beta2^it);
        p{j} = p{j} - o.lr * mh ./ (sqrt(vh) + epsA);
    end
end
net = struct('W1', p{1}, 'b1', p{2}, 'W2', p{3}, 'b2', p{4});
end

function [Y, dY] = netEval(net, tn)
% Output and first derivative (w.r.t. normalised time) of the network.
Hh = tanh(net.W1 * tn + net.b1);
Y  = net.W2 * Hh + net.b2;
dY = net.W2 * (net.W1 .* (1 - Hh.^2));
end

function [Y, d2] = netD2(net, tn)
% Output and analytic second derivative.
S = tanh(net.W1 * tn + net.b1);
Y = net.W2 * S + net.b2;
d2 = net.W2 * ((net.W1.^2) .* (-2 * S .* (1 - S.^2)));
end