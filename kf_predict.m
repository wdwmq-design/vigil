function [xy, cov2] = kf_predict(tObs, zObs, tQuery, sigmaMeas, sigmaAcc)
% KF_PREDICT  Constant-velocity Kalman filter over time-stamped measurements,
% then extrapolation to later times. Used for held-out prediction tests.
%
%   tObs   m x 1 times (frames), increasing, m >= 2
%   zObs   m x 2 measured [x y]
%   tQuery q x 1 times strictly AFTER tObs(end)
%   xy     q x 2 predicted position,  cov2  2 x 2 x q position covariance
tObs = tObs(:);  tQuery = tQuery(:);
m = numel(tObs);
if m < 2, error('kf_predict:tooFew', 'Need at least 2 measurements.'); end
if any(tQuery <= tObs(end)), error('kf_predict:past', 'Query times must be after the last observation.'); end

s2 = sigmaMeas^2;
H  = [1 0 0 0; 0 1 0 0];
Rm = s2 * eye(2);

% Initialise at the 2nd measurement from the 1st/2nd pair (exact cov of that estimate)
dt0 = tObs(2) - tObs(1);
x = [zObs(2,:)'; (zObs(2,:) - zObs(1,:))' / dt0];
P = zeros(4);
P(1,1) = s2;  P(2,2) = s2;
P(3,3) = 2*s2/dt0^2;  P(4,4) = 2*s2/dt0^2;
P(1,3) = s2/dt0;  P(3,1) = s2/dt0;
P(2,4) = s2/dt0;  P(4,2) = s2/dt0;
tLast = tObs(2);

for k = 3:m
    [F, Q] = cvModel(tObs(k) - tLast, sigmaAcc);
    x = F * x;  P = F * P * F' + Q;
    S = H * P * H' + Rm;
    K = P * H' / S;
    x = x + K * (zObs(k,:)' - H * x);
    P = (eye(4) - K * H) * P;
    tLast = tObs(k);
end

q = numel(tQuery);
xy = zeros(q, 2);  cov2 = zeros(2, 2, q);
for i = 1:q
    [F, Q] = cvModel(tQuery(i) - tLast, sigmaAcc);
    xq = F * x;  Pq = F * P * F' + Q;
    xy(i,:) = xq(1:2)';
    cov2(:,:,i) = Pq(1:2, 1:2);
end
end

function [F, Q] = cvModel(dt, sa)
F = [1 0 dt 0; 0 1 0 dt; 0 0 1 0; 0 0 0 1];
G = [dt^2/2 0; 0 dt^2/2; dt 0; 0 dt];
Q = sa^2 * (G * G');
end