function test_eit71_caini7_capture
% Regression against the user's 3488-byte capture, not generated sensor data.
base=fileparts(mfilename('fullpath')); old_path=path;
restore=onCleanup(@() path(old_path));
addpath(base,fullfile(base,'tests'));
file=fullfile(base,'tests','fixtures','caini7_sample_3488.hex');
[d,r]=read_eit71_board_capture(file);
assert(r.byte_count==3488 && r.float_count==872 && r.finite_count==872);
assert(isequal(size(d.eit_by_layer),[4 16 13]));
assert(isequal(size(d.temperature_layers),[4 8]));
assert(d.eit(1)==0.4180908203125 && d.temperature(1)==21.80078125);
assert(d.temperature_layers(2,1)==21.57421875 && d.temperature_layers(4,8)==22.0390625);
assert(min(d.temperature)==21.5 && max(d.temperature)==22.25);
expected_p=[-1.8620491027832031;-1.8755905628204346;-1.3095699548721313;-2.005305051803589];
expected_v=[0.5382031202316284;0.8243749737739563;0.6240624785423279;1.1106250286102295];
assert(isequal(d.pressure,expected_p) && isequal(d.seven_electrode,expected_v));
assert(~d.integrity_verified && r.length_checked);

% Strict imports reject extra/missing bytes and malformed hex.
dir=tempname; mkdir(dir); cleanup=onCleanup(@() remove_test_files(dir));
f=fullfile(dir,'sample.bin'); write_bin(f,d.raw_frame);
db=read_eit71_board_capture(f); assert(isequal(db.values,d.values));
write_bin(f,d.raw_frame(1:end-1)); must_error(@() read_eit71_board_capture(f),'EIT:CaptureLength');
write_bin(f,[d.raw_frame uint8(0)]); must_error(@() read_eit71_board_capture(f),'EIT:CaptureLength');
f=fullfile(dir,'bad.hex'); fid=fopen(f,'w'); fprintf(fid,'00 10 GG 3E'); fclose(fid);
must_error(@() read_eit71_board_capture(f),'EIT:CaptureHex');

% Final firmware protocol: exactly one FF per new cycle, never discard the
% first fragment, and allow USB scheduling gaps until the response timeout.
cfg=Eit71BoardProtocol.defaults(); cfg.response_timeout_s=2;
assert(strcmp(cfg.length_mode,'raw872') && isequal(Eit71BoardProtocol.command(1,cfg),uint8(255)));
port=Eit71FakePort; board=Eit71BoardSession(port,cfg); bcleanup=onCleanup(@() delete(board));
port.Input=uint8([1 2 3]); board.request(1);
assert(isempty(port.Input) && numel(port.Writes)==1 && isequal(port.Writes{1},uint8(255)));
must_error(@() board.request(1),'EIT:RequestPending');
port.Input=d.raw_frame(1:100); assert(isempty(board.tick()));
pause(0.25); assert(isempty(board.tick()));
port.Input=d.raw_frame(101:end); assert(numel(board.tick())==1);
assert(isequal(board.LastTelemetry.values,d.values) && board.RejectedBytes==0);
board.request(1); assert(numel(port.Writes)==2); board.cancel();

% Actual GUI import path, including orientation labels and negative pressures.
eit71_noser_upper_pc_app(file);
fig=findall(groot,'Type','figure','Name','71电极EIT-NOSER三维电阻率上位机');
assert(isscalar(fig)); fcleanup=onCleanup(@() close_if_valid(fig));
a=fig.UserData;
assert(strcmp(a.lengthMode.Value,'raw872') && a.triggerRaw.Value);
assert(a.latest_capture_report.byte_count==3488 && isempty(a.source));
assert(isequal(cell2mat(a.temperatureTable.Data(:,2:end)),d.temperature_layers'));
assert(isequal(cell2mat(a.pressureTable.Data(:,2)),expected_p));
assert(isequal(cell2mat(a.boardTable.Data(833:836,6)),expected_v));
assert(contains(a.temperatureTable.ColumnName{2},'最下'));
assert(contains(a.readBoard.Text,'FF'));
drawnow;
exportapp(fig,fullfile(base,'caini7_capture_decoded','实测数据温度压力界面.png'));
fprintf('CAINI7_CAPTURE_PASS: real 3488-byte sample, all 872 values, offsets/units/signs/orientation, strict file validation, FF trigger/fragments, GUI import.\n');
end

function write_bin(file,bytes)
fid=fopen(file,'wb'); c=onCleanup(@() fclose(fid)); fwrite(fid,bytes,'uint8');
end
function must_error(fn,id)
try
    fn();
catch ME
    assert(strcmp(ME.identifier,id),'Expected %s, got %s',id,ME.identifier); return;
end
error('Expected error %s.',id);
end
function close_if_valid(fig)
if isvalid(fig), close(fig); end
end
function remove_test_files(dir)
% Delete only the three explicitly created test files, never recurse.
for name={'sample.bin','bad.hex'}
    f=fullfile(dir,name{1}); if isfile(f), delete(f); end
end
if isfolder(dir), rmdir(dir); end
end
