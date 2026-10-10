function [stack, files] = load_frames(inDir)
% LOAD_FRAMES  Read all BMPs in a folder into an R x C x n double stack.
% Files are ordered by the LAST number in the file name, so frame_2 comes
% before frame_10 (plain alphabetical sort would get this wrong).
files = dir(fullfile(inDir, '*.bmp'));
if isempty(files), error('load_frames:none', 'No BMPs in %s (run make_debris_dataset first).', inDir); end
names = {files.name};
key = zeros(1, numel(names));
for i = 1:numel(names)
    tok = regexp(names{i}, '\d+', 'match');
    if isempty(tok), key(i) = i; else, key(i) = str2double(tok{end}); end
end
[~, ord] = sort(key);
files = files(ord);
n = numel(files);
A = imread(fullfile(inDir, files(1).name));
if ndims(A) == 3, A = A(:,:,1); end
stack = zeros([size(A), n]);
for k = 1:n
    A = imread(fullfile(inDir, files(k).name));
    if ndims(A) == 3, A = A(:,:,1); end
    stack(:,:,k) = double(A);
end
end