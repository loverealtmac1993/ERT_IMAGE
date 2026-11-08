function [telemetry, report] = read_eit71_board_capture(filename, cfg)
% Decode exactly one final raw872 (or explicitly chosen raw904) capture.
% TXT/HEX: whitespace-separated two-digit hex bytes; BIN: raw bytes.
% No scaling, offset correction, byte shifting, sign flipping, or clamping.
if nargin < 2, cfg = Eit71BoardProtocol.defaults(); end
if ~Eit71BoardProtocol.isRaw(cfg)
    error('EIT:CaptureProfile', 'Capture import expects raw872 or raw904.');
end
if ~isfile(filename), error('EIT:CaptureFile', 'File not found: %s',filename); end
[~,~,ext] = fileparts(filename);
if strcmpi(ext,'.bin')
    fid = fopen(filename,'rb');
    if fid < 0, error('EIT:CaptureFile','Cannot open capture.'); end
    cleanup = onCleanup(@() fclose(fid));
    bytes = fread(fid,Inf,'*uint8')';
elseif ismember(lower(string(ext)),[".txt",".hex",".log"])
    txt = fileread(filename);
    if ~isempty(txt) && txt(1)==char(65279), txt(1)=[]; end
    tokens = regexp(strtrim(txt),'\s+','split');
    if isempty(strtrim(txt)) || any(cellfun(@(x) isempty(regexp(x,'^[0-9a-fA-F]{2}$','once')),tokens))
        error('EIT:CaptureHex','HEX文件必须只包含由空白分隔的两位十六进制字节。');
    end
    bytes = uint8(hex2dec(char(tokens)))';
else
    error('EIT:CaptureFile','Supported extensions: txt, hex, log, bin.');
end
info = Eit71BoardProtocol.layout(cfg);
if numel(bytes)~=info.payload_bytes
    error('EIT:CaptureLength','本格式需要恰好%d字节，实际%d；不自动截断、补零或拼接。', ...
        info.payload_bytes,numel(bytes));
end
[frames,remainder] = Eit71BoardProtocol.consume([],bytes,cfg);
assert(numel(frames)==1 && isempty(remainder));
telemetry = Eit71BoardProtocol.telemetry(frames{1},cfg);
report.source_file = char(filename);
report.byte_count = numel(bytes);
report.float_count = numel(telemetry.values);
report.finite_count = sum(isfinite(telemetry.values));
report.frame = frames{1};
report.protocol_config = cfg;
report.length_checked = true;
report.checksum_available = false;
report.eit_min = min(telemetry.eit);
report.eit_max = max(telemetry.eit);
report.temperature_min = min(telemetry.temperature);
report.temperature_max = max(telemetry.temperature);
end
