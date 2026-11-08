function test_eit71_app_smoke
% Exercise the actual GUI callbacks with an in-memory board, then EIT replay.
base = fileparts(mfilename('fullpath'));
old_path = path;
restore = onCleanup(@() path(old_path));
addpath(base, fullfile(base, 'tests'));
eit71_noser_upper_pc_app;
fig = findall(groot, 'Type', 'figure', 'Name', '71电极EIT-NOSER三维电阻率上位机');
assert(isscalar(fig));
cleanup = onCleanup(@() close_if_valid(fig));
fig.Visible = 'off';
a = fig.UserData;
a.inputMode.Value = 'serial';
a.inputMode.ValueChangedFcn(a.inputMode, []);
a = fig.UserData;
assert(strcmp(a.collectReference.Enable, 'off'));
assert(strcmp(a.startStop.Text, '开始板卡采集'));
a.lengthMode.Value = 'low8';
a.lengthMode.ValueChangedFcn(a.lengthMode, []);
a = fig.UserData;
port = Eit71FakePort;
cfg = Eit71BoardProtocol.defaults(); cfg.length_mode = 'low8';
board = Eit71BoardSession(port, cfg);
a.source = struct('type', "serial", 'fid', [], 'board', board);
fig.UserData = a;
a.selfCheck.ButtonPushedFcn(a.selfCheck, []);
port.Input = uint8([255 255 165 16 128 6 0 150 38]);
wait_idle(fig);
a = fig.UserData;
assert(contains(a.boardInfo.Text, 'TYPE=0x80'));

[packet, expected] = eit71_test_board_fixture('low8');
a.readBoard.ButtonPushedFcn(a.readBoard, []);
port.Input = packet;
wait_idle(fig);
a = fig.UserData;
assert(isequal(cell2mat(a.boardTable.Data(1:832,6)), expected.eit));
assert(max(abs(cell2mat(a.temperatureTable.Data(:,2:end))-expected.temp),[],'all') < 1e-5);
assert(isequal(cell2mat(a.pressureTable.Data(:,2)),expected.pressure));
assert(contains(a.boardInfo.Text, 'TYPE=0x81'));
assert(isempty(a.timer));
a.updateSeconds.Value = 0.05;
a.startStop.ButtonPushedFcn(a.startStop, []);
port.Input = packet;
started = tic;
while board.RxCount < 3 && toc(started) < 5
    pause(0.05);
end
a = fig.UserData;
assert(~isempty(a.timer) && strcmp(a.timer.Running, 'on'));
a.startStop.ButtonPushedFcn(a.startStop, []);
a = fig.UserData;
assert(isempty(a.timer) && isempty(board.PendingType));
assert(board.RxCount >= 3);
fig.Visible = 'on'; drawnow;
exportapp(fig, fullfile(base, 'eit71_rs232_board_smoke.png'));
a.tabs.SelectedTab = a.sensorTab; drawnow;
exportapp(fig, fullfile(base, 'eit71_temperature_pressure_872.png'));

% Actual source format: 64 temperatures, pressure precedes the four Vpp values.
a.lengthMode.Value = 'raw904';
a.lengthMode.ValueChangedFcn(a.lengthMode, []);
a = fig.UserData;
assert(~isvalid(board) && isempty(a.sensor_history.time_s));
port = Eit71FakePort; cfg = Eit71BoardProtocol.defaults(); cfg.length_mode='raw904';
board = Eit71BoardSession(port,cfg);
a.source = struct('type',"serial",'fid',[],'board',board); fig.UserData=a;
a.readBoard.ButtonPushedFcn(a.readBoard,[]);
pause(0.4);
[port.Input, expected] = eit71_test_board_fixture('raw904');
wait_idle(fig); a=fig.UserData;
assert(isempty(port.Writes) && contains(a.boardInfo.Text,'无状态字段/校验'));
assert(max(abs(cell2mat(a.temperatureTable.Data(:,2:end))-expected.temp),[],'all') < 1e-5);
assert(isequal(cell2mat(a.pressureTable.Data(:,2)),expected.pressure));
assert(max(abs(cell2mat(a.boardTable.Data(833:836,6))-expected.probe)) < 1e-6);
a.tabs.SelectedTab = a.sensorTab; drawnow;
exportapp(fig, fullfile(base,'eit71_temperature_pressure_raw904.png'));

% Target raw872 keeps the C-structure order, with eight temperatures per layer.
a.lengthMode.Value='raw872'; a.lengthMode.ValueChangedFcn(a.lengthMode,[]);
a=fig.UserData; assert(~isvalid(board));
cfg.length_mode='raw872'; port=Eit71FakePort; board=Eit71BoardSession(port,cfg);
a.source=struct('type',"serial",'fid',[],'board',board); fig.UserData=a;
a.readBoard.ButtonPushedFcn(a.readBoard,[]); pause(0.4);
[port.Input,expected]=eit71_test_board_fixture('raw872'); wait_idle(fig); a=fig.UserData;
assert(isequal(size(a.temperatureTable.Data),[8 5]));
assert(max(abs(cell2mat(a.temperatureTable.Data(:,2:end))-expected.temp),[],'all') < 1e-5);
assert(isequal(cell2mat(a.pressureTable.Data(:,2)),expected.pressure));

% Switching mode closes the source and invalidates EIT reference data.
a.inputMode.Value = 'file';
a.inputMode.ValueChangedFcn(a.inputMode, []);
a = fig.UserData;
assert(isempty(a.source) && isempty(a.vh) && ~isvalid(board));
a.testParser.ButtonPushedFcn(a.testParser, []);
assert(contains(a.status.Items{1}, '解析/文件测试通过'));
a.testOneCycle.ButtonPushedFcn(a.testOneCycle, []);
a = fig.UserData;
assert(~isempty(a.vh) && a.cycle_count == 1, '%s', strjoin(a.status.Items, newline));
assert(all(isfinite(a.last_rho)) && all(a.last_rho > 0));
assert(contains(a.status.Items{1}, '单周期重建测试通过'));
drawnow;
exportapp(fig, fullfile(base, 'eit71_rs232_recon_smoke.png'));
fprintf('GUI_PASS: selfcheck, framed872/raw904/raw872 sensor groups, temperature/pressure plots/tables, continuous poll, stop, cleanup, legacy NOSER (%d measurements, %d voxels).\n', ...
    numel(a.vh), numel(a.last_rho));
end

function wait_idle(fig)
started = tic;
while toc(started) < 5
    pause(0.05);
    a = fig.UserData;
    if isempty(a.timer), return; end
end
error('GUI response did not complete.');
end

function close_if_valid(fig)
if isvalid(fig), close(fig); end
end
