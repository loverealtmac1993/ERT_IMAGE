function test_eit71_board_protocol
% Firmware raw904 and proposed framed872 regression, no physical board.
base = fileparts(mfilename('fullpath')); old_path = path;
restore = onCleanup(@() path(old_path));
addpath(base, fullfile(base,'tests'));
cfg = Eit71BoardProtocol.defaults(); cfg.length_mode = 'low8';
cfg.response_timeout_s = 0.15;
assert(isequal(Eit71BoardProtocol.command(0,cfg), uint8([255 255 165 16 0 6 0 22 38])));
assert(isequal(Eit71BoardProtocol.command(1,cfg), uint8([255 255 165 16 1 6 0 23 38])));
[packet, expected] = eit71_test_board_fixture('low8');
assert(numel(packet) == 3497 && packet(6) == 166);
self = uint8([255 255 165 16 128 6 0 150 38]);
for split_at = 0:numel(packet)
    [a,buffer] = Eit71BoardProtocol.consume([],packet(1:split_at),cfg);
    [b,buffer] = Eit71BoardProtocol.consume(buffer,packet(split_at+1:end),cfg);
    frames = [a b];
    assert(numel(frames)==1 && isempty(buffer));
end
data = Eit71BoardProtocol.telemetry(frames{1},cfg);
check_groups(data,expected); assert(data.usable && numel(data.values)==872);
strict=cfg; strict.length_mode='uint8';
assert(isempty(Eit71BoardProtocol.consume([],packet,strict)));
buffer=uint8([]); frames={};
for byte = [uint8([1 255 7 255]) packet packet self]
    [part,buffer] = Eit71BoardProtocol.consume(buffer,byte,cfg);
    frames=[frames part]; %#ok<AGROW>
end
assert(numel(frames)==3 && isempty(buffer));
bad=packet; bad(end-1)=bitxor(bad(end-1),uint8(1));
tail=packet; tail(end)=0;
len=packet; len(6)=5;
addr=packet; addr(4)=17;
type=packet; type(5)=1;
[frames,buffer,dropped]=Eit71BoardProtocol.consume([], [bad tail len addr type packet],cfg);
assert(numel(frames)==1 && isempty(buffer) && dropped>0);
% DATA may contain complete header bytes and 0x26 without ending a packet.
embedded=packet; embedded(70:72)=uint8([255 255 165]);
embedded(end-1)=uint8(mod(sum(double(embedded(4:end-2))),256));
assert(numel(Eit71BoardProtocol.consume([],embedded,cfg))==1);

% Big-endian float payload; STATUS bit meanings are not invented.
big=packet;
big(8:end-2)=reshape(flipud(reshape(big(8:end-2),4,[])),1,[]);
big(7)=165; big(end-1)=uint8(mod(sum(double(big(4:end-2))),256));
be=cfg; be.byte_order='big-endian';
frames=Eit71BoardProtocol.consume([],big,be);
data=Eit71BoardProtocol.telemetry(frames{1},be); check_groups(data,expected);
assert(~data.usable && isequal(find(data.fault_bits)-1,[0 2 5 7]));
nonfinite=packet; nonfinite(8:11)=uint8([0 0 192 127]);
nonfinite(end-1)=uint8(mod(sum(double(nonfinite(4:end-2))),256));
frames=Eit71BoardProtocol.consume([],nonfinite,cfg);
data=Eit71BoardProtocol.telemetry(frames{1},cfg);
assert(isnan(data.eit(1)) && ~data.electrical_usable);
frames=Eit71BoardProtocol.consume([],self,cfg);
must_error(@() Eit71BoardProtocol.telemetry(frames{1},cfg),'EIT:TelemetryLayout');

% Both two-byte LENGTH choices: header/body offsets, checksum and fragmentation.
for mode = {'uint16le','uint16be'}
    c=cfg; c.length_mode=mode{1};
    cmd=Eit71BoardProtocol.command(1,c);
    if strcmp(mode{1},'uint16le')
        assert(isequal(cmd,uint8([255 255 165 16 1 7 0 0 24 38])));
    else
        assert(isequal(cmd,uint8([255 255 165 16 1 0 7 0 24 38])));
    end
    [bytes,e]=eit71_test_board_fixture(mode{1}); assert(numel(bytes)==3498);
    for k=0:numel(bytes)
        [a,buf]=Eit71BoardProtocol.consume([],bytes(1:k),c);
        [b,buf]=Eit71BoardProtocol.consume(buf,bytes(k+1:end),c);
        assert(numel([a b])==1 && isempty(buf));
    end
    f=Eit71BoardProtocol.consume([],bytes,c);
    d=Eit71BoardProtocol.telemetry(f{1},c); check_groups(d,e);
end

% Match actual packed C structure: 832 EIT, 64 temperature, 4 pressure, 4 Vpp.
raw=Eit71BoardProtocol.defaults(); raw.length_mode='raw904'; raw.response_timeout_s=0.15;
[bytes,e]=eit71_test_board_fixture('raw904'); assert(numel(bytes)==3616);
assert(isempty(Eit71BoardProtocol.command(1,raw)));
must_error(@() Eit71BoardProtocol.command(0,raw),'EIT:RawSelfCheck');
for k=0:numel(bytes)
    [a,buf]=Eit71BoardProtocol.consume([],bytes(1:k),raw);
    [b,buf]=Eit71BoardProtocol.consume(buf,bytes(k+1:end),raw);
    assert(numel([a b])==1 && isempty(buf));
end
frames=Eit71BoardProtocol.consume([],[bytes bytes],raw); assert(numel(frames)==2);
data=Eit71BoardProtocol.telemetry(frames{1},raw); check_groups(data,e);
assert(~data.integrity_verified && ~data.status_available && ~data.usable);
target_raw=raw; target_raw.length_mode='raw872';
[target_bytes,target_expected]=eit71_test_board_fixture('raw872');
assert(numel(target_bytes)==3488);
for k=0:numel(target_bytes)
    [a,buf]=Eit71BoardProtocol.consume([],target_bytes(1:k),target_raw);
    [b,buf]=Eit71BoardProtocol.consume(buf,target_bytes(k+1:end),target_raw);
    assert(numel([a b])==1 && isempty(buf));
end
f=Eit71BoardProtocol.consume([],target_bytes,target_raw);
check_groups(Eit71BoardProtocol.telemetry(f{1},target_raw),target_expected);

% Match process_conductivity_data(), including its fixed order and reversed sign.
map=Eit71MeasurementLayout.rows(); assert(isequal(size(map),[836 8]));
assert(isequal(map(1,5:8),[1 2 4 3]));
assert(isequal(map(40,5:8),[4 5 2 1])); % Fourth drive begins at fixed pair 1-2.
assert(isequal(map(196,5:8),[16 1 3 2]));
assert(isequal(map(833:836,5:8),[65 68 66 67;66 69 67 68;67 70 68 69;68 71 69 70]));
cyclic=Eit71MeasurementLayout.rows('cyclic');
assert(isequal(cyclic(40,5:8),[4 5 6 7]));
for k=1:832
    assert(~any(ismember(map(k,7:8),map(k,5:6))));
    assert(all(map(k,5:8)>16*(map(k,2)-1) & map(k,5:8)<=16*map(k,2)));
end

% Framed transport: correlation, cancellation, timeout and no request flooding.
port=Eit71FakePort; board=Eit71BoardSession(port,cfg);
cleanup=onCleanup(@() delete(board));
port.Input=packet; board.request(1);
assert(port.NumBytesAvailable==0 && numel(port.Writes)==1);
must_error(@() board.request(1),'EIT:RequestPending');
port.Input=self; assert(isempty(board.tick()) && board.PendingType==129);
port.Input=packet(1:100); assert(isempty(board.tick()));
port.Input=packet(101:end); assert(numel(board.tick())==1 && board.RxCount==1);
board.request(0); port.Input=self; board.tick(); assert(board.RxCount==2);
board.request(1); board.cancel(); assert(isempty(board.PendingType));
board.request(1); pause(0.2); must_error(@() board.tick(),'EIT:BoardTimeout');

% Raw transport drops an in-flight tail, waits for idle, and never writes.
raw.response_timeout_s=2; p=Eit71FakePort; b=Eit71BoardSession(p,raw);
raw_cleanup=onCleanup(@() delete(b));
b.request(1); p.Input=bytes(1:20); assert(isempty(b.tick()));
pause(0.25); b.tick(); p.Input=bytes;
assert(numel(b.tick())==1 && isempty(p.Writes) && b.RejectedBytes==20);
check_groups(b.LastTelemetry,e);
b.request(1); p.Input=uint8(sprintf('0.1234\r\n')); b.tick();
pause(0.25); assert(isempty(b.tick()));
assert(b.RejectedBytes==28); % An idle-separated debug line is dropped, not accumulated.
p.Input=bytes; assert(numel(b.tick())==1);
fprintf('PASS: raw904/raw872 + framed872, all split positions in 5 formats, endian, group offsets, stream recovery, measurement map, request/cancel/timeout, passive raw sync.\n');
end

function check_groups(d,e)
assert(isequal(d.eit,e.eit));
assert(max(abs(d.seven_electrode-e.probe))<1e-6);
assert(max(abs(d.temperature_by_layer(:)-e.temp(:)))<1e-5);
assert(isequal(d.pressure,e.pressure));
assert(isequal(size(d.eit_by_stimulation),[13 16 4]));
end

function must_error(action,id)
try, action(); catch ME, assert(strcmp(ME.identifier,id),'Expected %s, got %s',id,ME.identifier); return; end
error('Expected %s was not raised.',id);
end
