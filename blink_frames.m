
function blink_frames(userOpts)
% BLINK_FRAMES
% Continuously blink through frames and optionally save an animated GIF.
% Original BMP files are read only and never modified.
%
% Usage:
%   blink_frames()
%   blink_frames(struct('mode','diff'))
%   blink_frames(struct('mode','both'))
%   blink_frames(struct('overlay','detections'))
%   blink_frames(struct('overlay','tracks'))
%   blink_frames(struct('overlay','both'))
%   blink_frames(struct('frameList',[1 4]))
%
% Keys:
%   Space       Pause/resume
%   Left/Right  Step one frame
%   Up/Down     Change blink speed
%   O           Toggle overlays
%   Q or Esc    Quit

if nargin < 1 || isempty(userOpts)
    userOpts = struct();
end

here = fileparts(mfilename('fullpath'));
if isempty(here)
    here = pwd;
end

% Configuration. Montage is disabled so no static All frames window opens.
bl = struct( ...
    'mode', 'raw', ...
    'overlay', 'tracks', ...
    'fps', 2, ...
    'nLoops', 0, ...
    'frameList', [], ...
    'montage', false, ...
    'saveMontage', false, ...
    'saveGif', true, ...
    'gifName', 'blink.gif', ...
    'gifOnly', false, ...
    'diffMaxSigma', 8, ...
    'rawRange', [0 255], ...
    'dataDir', fullfile(here, 'data'));

fn = fieldnames(userOpts);
for i = 1:numel(fn)
    bl.(fn{i}) = userOpts.(fn{i});
end

bl.mode = lower(bl.mode);
bl.overlay = lower(bl.overlay);

inDir = fullfile(bl.dataDir, 'frames_bmp_debris');
resDir = fullfile(bl.dataDir, 'results');

if ~exist(resDir, 'dir')
    mkdir(resDir);
end

stack = load_frames(inDir);
[~, C, n] = size(stack);

if isempty(bl.frameList)
    bl.frameList = 1:n;
end

bl.frameList = bl.frameList( ...
    bl.frameList >= 1 & bl.frameList <= n);

if numel(bl.frameList) < 2
    error('blink_frames:frames', ...
        'Need at least 2 frames to blink.');
end

needDiff = any(strcmp(bl.mode, {'diff', 'both'}));

if needDiff && n < 3
    warning('blink_frames:diff', ...
        'Median difference needs >= 3 frames; showing raw frames.');
    bl.mode = 'raw';
    needDiff = false;
end

if needDiff
    D = stack - median(stack, 3);
    sig0 = max(1.4826 * ...
        median(abs(D(:) - median(D(:)))), eps);
end

%% Pre-render frames for fast blinking

imgs = cell(1, n);

for k = bl.frameList
    rawN = clip01((stack(:,:,k) - bl.rawRange(1)) / ...
        (bl.rawRange(2) - bl.rawRange(1)));

    if needDiff
        difN = clip01((D(:,:,k) + 3*sig0) / ...
            ((bl.diffMaxSigma + 3) * sig0));
    end

    switch bl.mode
        case 'raw'
            imgs{k} = rawN;
        case 'diff'
            imgs{k} = difN;
        case 'both'
            imgs{k} = [rawN, difN];
        otherwise
            error('blink_frames:mode', ...
                'mode must be raw, diff or both.');
    end
end

offsets = 0;
if strcmp(bl.mode, 'both')
    offsets = [0 C];
end

%% Create ONLY the blinking window
% The static All frames montage window has intentionally been removed.

fig = figure( ...
    'Color', 'k', ...
    'Name', 'Blink comparator', ...
    'NumberTitle', 'off', ...
    'Position', [60 60 1100 800]);

ax = axes('Parent', fig, ...
    'Position', [0.01 0.01 0.98 0.90]);

hImg = imshow(imgs{bl.frameList(1)}, [0 1], ...
    'Parent', ax);
hold(ax, 'on');

ov = buildOverlay(ax, bl, resDir, n, offsets);

V = struct( ...
    'fig', fig, ...
    'ax', ax, ...
    'h', hImg, ...
    'imgs', {imgs}, ...
    'ov', {ov}, ...
    'list', bl.frameList, ...
    'mode', bl.mode);

st = struct( ...
    'p', 1, ...
    'paused', false, ...
    'fps', bl.fps, ...
    'step', 0, ...
    'quit', false, ...
    'redraw', false, ...
    'overlayOn', ~strcmp(bl.overlay, 'none'));

setappdata(fig, 'st', st);
set(fig, 'KeyPressFcn', @onKey);

%% Export animated GIF

if bl.saveGif || bl.gifOnly
    gifPath = fullfile(resDir, bl.gifName);

    for p = 1:numel(V.list)
        s2 = st;
        s2.p = p;

        showFrame(V, s2);
        drawnow;

        fr = getframe(fig);
        [A, map] = rgb2ind(fr.cdata, 256);

        if p == 1
            imwrite(A, map, gifPath, 'gif', ...
                'LoopCount', Inf, ...
                'DelayTime', 1 / bl.fps);
        else
            imwrite(A, map, gifPath, 'gif', ...
                'WriteMode', 'append', ...
                'DelayTime', 1 / bl.fps);
        end
    end

    fprintf('Blink GIF written to %s\n', gifPath);

    if bl.gifOnly
        close(fig);
        return;
    end
end

%% Continuous blinking loop

showFrame(V, st);

tLast = tic;
loops = 0;

while ishandle(fig)
    st = getappdata(fig, 'st');

    if st.quit
        break;
    end

    if st.step ~= 0
        st.p = mod(st.p - 1 + st.step, ...
            numel(V.list)) + 1;
        st.step = 0;
        setappdata(fig, 'st', st);
        showFrame(V, st);

    elseif st.redraw
        st.redraw = false;
        setappdata(fig, 'st', st);
        showFrame(V, st);

    elseif ~st.paused && toc(tLast) >= 1 / st.fps
        st.p = mod(st.p, numel(V.list)) + 1;

        if st.p == 1
            loops = loops + 1;
        end

        setappdata(fig, 'st', st);
        showFrame(V, st);
        tLast = tic;

        if bl.nLoops > 0 && loops >= bl.nLoops
            break;
        end
    end

    pause(0.01);
end

if ishandle(fig) && st.quit
    close(fig);
end

end

%% Keyboard controls

function onKey(fig, ev)

st = getappdata(fig, 'st');

switch ev.Key
    case 'space'
        st.paused = ~st.paused;
        st.redraw = true;

    case 'rightarrow'
        st.step = 1;
        st.paused = true;

    case 'leftarrow'
        st.step = -1;
        st.paused = true;

    case 'uparrow'
        st.fps = min(st.fps * 1.5, 30);
        st.redraw = true;

    case 'downarrow'
        st.fps = max(st.fps / 1.5, 0.25);
        st.redraw = true;

    case 'o'
        st.overlayOn = ~st.overlayOn;
        st.redraw = true;

    case {'q', 'escape'}
        st.quit = true;
end

setappdata(fig, 'st', st);

end

%% Display the current frame and its overlays

function showFrame(V, st)

k = V.list(st.p);

set(V.h, 'CData', V.imgs{k});

for kk = V.list
    if ~isempty(V.ov{kk})
        set(V.ov{kk}, 'Visible', 'off');
    end
end

if st.overlayOn && ~isempty(V.ov{k})
    set(V.ov{k}, 'Visible', 'on');
end

if st.paused
    ptxt = ' [PAUSED]';
else
    ptxt = '';
end

title(V.ax, { ...
    sprintf('Frame %d (%d/%d)  %s  %.1f fps%s', ...
        k, st.p, numel(V.list), upper(V.mode), ...
        st.fps, ptxt), ...
    'SPACE pause | arrows step | UP/DOWN speed | O overlay | Q quit'}, ...
    'Color', 'w', 'FontSize', 9);

drawnow;

end

%% Build detection and tracking overlays

function ov = buildOverlay(ax, bl, resDir, n, offsets)

ov = cell(1, n);

wantDet = any(strcmp(bl.overlay, {'detections', 'both'}));
wantTrk = any(strcmp(bl.overlay, {'tracks', 'both'}));

Tdet = [];
Ttr = [];

if wantDet
    f = fullfile(resDir, 'detections.csv');

    if exist(f, 'file')
        Tdet = readtable(f);
    else
        warning('blink_frames:noDet', ...
            'No detections.csv - run detect_debris first.');
    end
end

if wantTrk
    f = fullfile(resDir, 'tracks.csv');

    if exist(f, 'file')
        Ttr = readtable(f);
    else
        warning('blink_frames:noTrk', ...
            'No tracks.csv - run track_debris first.');
    end
end

colMap = containers.Map( ...
    {'streak-like', 'artifact-like', 'compact', 'unknown'}, ...
    {[0.2 1 0.2], [1 0.3 1], [0.2 0.9 1], [1 0.8 0.2]});

for k = 1:n
    h = gobjects(0);

    for off = offsets

        %% Detection boxes
        if ~isempty(Tdet)
            for q = find(Tdet.frame == k)'
                cls = char(string(Tdet.class(q)));

                if isKey(colMap, cls)
                    col = colMap(cls);
                else
                    col = [1 1 1];
                end

                lw = 1;

                if Tdet.isCandidate(q) == 1
                    col = [1 0.2 0.2];
                    lw = 2;
                end

                h(end+1) = rectangle( ...
                    'Position', [Tdet.bboxX(q)+off, ...
                    Tdet.bboxY(q), Tdet.bboxW(q), ...
                    Tdet.bboxH(q)], ...
                    'EdgeColor', col, ...
                    'LineWidth', lw, ...
                    'Visible', 'off'); %#ok<AGROW>

                h(end+1) = plot( ...
                    Tdet.cx(q)+off, Tdet.cy(q), '+', ...
                    'Color', col, ...
                    'MarkerSize', 6, ...
                    'Visible', 'off'); %#ok<AGROW>
            end
        end

        %% Track paths and moving debris label
        if ~isempty(Ttr)
            for id = unique(Ttr.track)'
                s = Ttr(Ttr.track == id & Ttr.frame <= k, :);

                if isempty(s)
                    continue;
                end

                % Red track path makes the moving debris easy to follow.
                h(end+1) = plot(s.x+off, s.y, 'r-', ...
                    'LineWidth', 2, ...
                    'Visible', 'off'); %#ok<AGROW>

                if s.frame(end) == k
                    if s.measured(end) == 1
                        mk = 'o';
                        labelText = 'DEBRIS';
                    else
                        mk = 's';
                        labelText = 'DEBRIS (predicted)';
                    end

                    h(end+1) = plot(s.x(end)+off, s.y(end), ...
                        mk, 'MarkerSize', 11, ...
                        'MarkerEdgeColor', 'r', ...
                        'MarkerFaceColor', 'none', ...
                        'LineWidth', 2, ...
                        'Visible', 'off'); %#ok<AGROW>

                    % Red label beside the current debris position.
                    h(end+1) = text(s.x(end)+off+8, s.y(end)-8, ...
                        labelText, ...
                        'Color', 'r', ...
                        'FontWeight', 'bold', ...
                        'FontSize', 10, ...
                        'Interpreter', 'none', ...
                        'Clipping', 'on', ...
                        'Visible', 'off'); %#ok<AGROW>
                end
            end
        end
    end

    ov{k} = h;
end

end

%% Clamp image intensities

function A = clip01(A)

A = min(max(A, 0), 1);

end
