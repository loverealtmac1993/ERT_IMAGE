function eit71_noser_upper_pc_app(capture_file)
% 71-electrode EIT upper-computer GUI using NOSER weighted reconstruction.
%
% The app supports two input sources:
%   1) CAINI raw structures or explicitly selected framed board telemetry
%   2) file replay from generated mock logs
%
% Legacy FILE protocol (not sent by the new hardware):
%   $EIT1,frame_id,stim_id,i_plus,i_minus,irms_A,freq_Hz,V1,...,V71*XX
% Source-backed raw904 and target raw/framed872 have different field offsets.
% Their 836 electrical values do not match the saved 6700-row EIT Jacobian.

app = struct();
app.ctx = [];
app.source = [];
app.vh = [];
app.timer = [];
app.cycle_count = 0;
app.last_rho = [];
app.last_delta_sigma = [];
app.board_continuous = false;
app.board_last_request = [];
app.sensor_clock = tic;
app.sensor_history = struct('time_s', [], 'temperature', [], 'pressure', []);
app.latest_telemetry = [];
app.latest_frame = [];
app.latest_protocol_config = [];
app.latest_capture_report = [];

app.fig = uifigure('Name', '71电极EIT-NOSER三维电阻率上位机', ...
    'Position', [40, 40, 1640, 880], 'CloseRequestFcn', @on_close);

root = uigridlayout(app.fig, [1, 2]);
root.ColumnWidth = {410, '1x'};
root.RowHeight = {'1x'};

left = uipanel(root, 'Title', '控制面板');
left.Layout.Row = 1;
left.Layout.Column = 1;
controlGrid = uigridlayout(left, [30, 3]);
controlGrid.ColumnWidth = {105, '1x', 74};
controlGrid.RowHeight = [repmat({28}, 1, 29), {120}];
controlGrid.RowSpacing = 4;
controlGrid.Scrollable = 'on';
controlGrid.Padding = [8 8 8 8];

row = 1;
add_form_label(controlGrid, row, '输入模式');
app.inputMode = uidropdown(controlGrid, 'Items', {'模拟文件（EIT成像）', '串口（新板卡协议）'}, ...
    'ItemsData', {'file', 'serial'}, 'Value', 'serial', 'ValueChangedFcn', @mode_changed);
app.inputMode.Layout.Row = row; app.inputMode.Layout.Column = 2;

row = row + 1;
add_form_label(controlGrid, row, '串口号');
app.serialPort = uieditfield(controlGrid, 'text', 'Value', 'COM3');
app.serialPort.Layout.Row = row; app.serialPort.Layout.Column = 2;

row = row + 1;
add_form_label(controlGrid, row, '波特率');
app.baudRate = uidropdown(controlGrid, ...
    'Items', {'9600', '19200', '38400', '57600', '115200', '230400', '460800', '921600'}, ...
    'Value', '115200');
app.baudRate.Layout.Row = row; app.baudRate.Layout.Column = 2;

row = row + 1;
add_form_label(controlGrid, row, '板卡地址(hex)');
app.boardAddress = uieditfield(controlGrid, 'text', 'Value', '10');
app.boardAddress.Layout.Row = row; app.boardAddress.Layout.Column = 2;

row = row + 1;
add_form_label(controlGrid, row, 'float字节序');
app.byteOrder = uidropdown(controlGrid, 'Items', {'小端（STM32源码）', '大端'}, ...
    'ItemsData', {'little-endian', 'big-endian'}, 'Value', 'little-endian');
app.byteOrder.Layout.Row = row; app.byteOrder.Layout.Column = [2 3];

row = row + 1;
add_form_label(controlGrid, row, '串口格式');
app.lengthMode = uidropdown(controlGrid, ...
    'Items', {'旧CAINI9原始904（兼容）', '已确认CAINI7原始872（3488字节）', '其他固件 单字节严格长度', ...
    '新872 LENGTH低8位（待固件实现）', '新872 双字节小端长度（待实现）', ...
    '新872 双字节大端长度（待实现）'}, ...
    'ItemsData', {'raw904', 'raw872', 'uint8', 'low8', 'uint16le', 'uint16be'}, ...
    'Value', 'raw872', 'ValueChangedFcn', @wire_changed);
app.lengthMode.Layout.Row = row; app.lengthMode.Layout.Column = [2 3];

row = row + 1;
add_form_label(controlGrid, row, '采集触发');
app.triggerRaw = uicheckbox(controlGrid, 'Text', '872模式发送FF启动一周期', ...
    'Value', true, 'ValueChangedFcn', @wire_changed);
app.triggerRaw.Layout.Row = row; app.triggerRaw.Layout.Column = [2 3];

row = row + 1;
add_form_label(controlGrid, row, '测量值排序');
app.measurementOrder = uidropdown(controlGrid, ...
    'Items', {'固定编号与反向差分（源码）', '随激励循环、正向差分'}, ...
    'ItemsData', {'firmware_ascending', 'cyclic'}, 'Value', 'firmware_ascending', ...
    'ValueChangedFcn', @measurement_order_changed);
app.measurementOrder.Layout.Row = row; app.measurementOrder.Layout.Column = [2 3];

row = row + 1;
add_form_label(controlGrid, row, '模拟日志');
app.mockFile = uieditfield(controlGrid, 'text', 'Value', locate_runtime_file('eit71_mock_hydrate_progress_log.txt'));
app.mockFile.Layout.Row = row; app.mockFile.Layout.Column = 2;
app.browseMock = uibutton(controlGrid, 'Text', '浏览', 'ButtonPushedFcn', @browse_mock);
app.browseMock.Layout.Row = row; app.browseMock.Layout.Column = 3;

row = row + 1;
add_form_label(controlGrid, row, '模型MAT');
app.modelMat = uieditfield(controlGrid, 'text', 'Value', locate_runtime_file('seafloor_core_hydrate_internal_probe_eit_result.mat'));
app.modelMat.Layout.Row = row; app.modelMat.Layout.Column = 2;
app.browseModel = uibutton(controlGrid, 'Text', '浏览', 'ButtonPushedFcn', @browse_model);
app.browseModel.Layout.Row = row; app.browseModel.Layout.Column = 3;

row = row + 1;
add_form_label(controlGrid, row, 'NOSER参数');
app.lambda = uieditfield(controlGrid, 'numeric', 'Value', 0.120, 'Limits', [eps Inf]);
app.lambda.Layout.Row = row; app.lambda.Layout.Column = 2;

row = row + 1;
add_form_label(controlGrid, row, '参考周期');
app.refCycles = uieditfield(controlGrid, 'numeric', 'Value', 3, 'Limits', [1 100], ...
    'RoundFractionalValues', 'on');
app.refCycles.Layout.Row = row; app.refCycles.Layout.Column = 2;

row = row + 1;
add_form_label(controlGrid, row, '刷新(s)');
app.updateSeconds = uieditfield(controlGrid, 'numeric', 'Value', 0.5, 'Limits', [0.05 10]);
app.updateSeconds.Layout.Row = row; app.updateSeconds.Layout.Column = 2;

row = row + 1;
add_form_label(controlGrid, row, '校验');
app.checksum = uicheckbox(controlGrid, 'Text', '模拟文件XOR校验', 'Value', true);
app.checksum.Layout.Row = row; app.checksum.Layout.Column = [2 3];

row = row + 1;
app.loadModel = uibutton(controlGrid, 'Text', '加载模型', 'ButtonPushedFcn', @load_model);
app.loadModel.Layout.Row = row; app.loadModel.Layout.Column = [1 3];

row = row + 1;
app.openSource = uibutton(controlGrid, 'Text', '打开数据源', 'ButtonPushedFcn', @open_source_cb);
app.openSource.Layout.Row = row; app.openSource.Layout.Column = [1 3];

row = row + 1;
app.closeSource = uibutton(controlGrid, 'Text', '关闭数据源', 'ButtonPushedFcn', @close_source_cb);
app.closeSource.Layout.Row = row; app.closeSource.Layout.Column = [1 3];

row = row + 1;
app.selfCheck = uibutton(controlGrid, 'Text', '板卡自检（0x00）', ...
    'ButtonPushedFcn', @(~,~) begin_board_monitor(0, false));
app.selfCheck.Layout.Row = row; app.selfCheck.Layout.Column = [1 3];

row = row + 1;
app.readBoard = uibutton(controlGrid, 'Text', '读取板卡数据（0x01）', ...
    'ButtonPushedFcn', @(~,~) begin_board_monitor(1, false));
app.readBoard.Layout.Row = row; app.readBoard.Layout.Column = [1 3];

row = row + 1;
app.saveBoard = uibutton(controlGrid, 'Text', '保存最近板卡报文 MAT', 'ButtonPushedFcn', @save_board_cb);
app.saveBoard.Layout.Row = row; app.saveBoard.Layout.Column = [1 3];

row = row + 1;
app.importBoard = uibutton(controlGrid, 'Text', '导入实测HEX / BIN', 'ButtonPushedFcn', @import_board_cb);
app.importBoard.Layout.Row = row; app.importBoard.Layout.Column = [1 3];

row = row + 1;
app.collectReference = uibutton(controlGrid, 'Text', '采集背景参考', 'ButtonPushedFcn', @collect_reference_cb);
app.collectReference.Layout.Row = row; app.collectReference.Layout.Column = [1 3];

row = row + 1;
app.startStop = uibutton(controlGrid, 'Text', '开始成像', 'ButtonPushedFcn', @start_stop_cb);
app.startStop.Layout.Row = row; app.startStop.Layout.Column = [1 3];

row = row + 1;
app.testProtocol = uibutton(controlGrid, 'Text', '测试协议匹配', 'ButtonPushedFcn', @test_protocol_cb);
app.testProtocol.Layout.Row = row; app.testProtocol.Layout.Column = [1 3];

row = row + 1;
app.testParser = uibutton(controlGrid, 'Text', '测试解析/文件', 'ButtonPushedFcn', @test_parser_cb);
app.testParser.Layout.Row = row; app.testParser.Layout.Column = [1 3];

row = row + 1;
app.testOneCycle = uibutton(controlGrid, 'Text', '测试单周期重建', 'ButtonPushedFcn', @test_one_cycle_cb);
app.testOneCycle.Layout.Row = row; app.testOneCycle.Layout.Column = [1 3];

row = row + 1;
app.status = uilistbox(controlGrid, 'Items', {'就绪。'}, 'Value', '就绪。');
app.status.Layout.Row = [row 30];
app.status.Layout.Column = [1 3];

app.tabs = uitabgroup(root);
app.tabs.Layout.Row = 1; app.tabs.Layout.Column = 2;
app.imageTab = uitab(app.tabs, 'Title', 'EIT模拟成像');
app.boardTab = uitab(app.tabs, 'Title', '成像与探杆原始数据');
app.sensorTab = uitab(app.tabs, 'Title', '温度与压力');
imageGrid = uigridlayout(app.imageTab, [2, 1]);
imageGrid.RowHeight = {'1x', 160};
plotPanel = uipanel(imageGrid, 'BorderType', 'none');
plotPanel.Layout.Row = 1;
right = uigridlayout(plotPanel, [1, 3]);
right.ColumnWidth = {'1x', '1x', '1.15x'};

app.axXZ = uiaxes(right);
app.axXZ.Layout.Row = 1;
app.axXZ.Layout.Column = 1;
title(app.axXZ, '电阻率XZ散点图');
xlabel(app.axXZ, 'x (mm)');
ylabel(app.axXZ, 'z (mm)');
grid(app.axXZ, 'on');

app.ax3D = uiaxes(right);
app.ax3D.Layout.Row = 1;
app.ax3D.Layout.Column = 2;
title(app.ax3D, '低电导/高电阻率候选区域');
xlabel(app.ax3D, 'x (mm)');
ylabel(app.ax3D, 'y (mm)');
zlabel(app.ax3D, 'z (mm)');
grid(app.ax3D, 'on');
view(app.ax3D, 36, 24);

app.axVolume = uiaxes(right);
app.axVolume.Layout.Row = 1;
app.axVolume.Layout.Column = 3;
title(app.axVolume, '三维动态成像');
xlabel(app.axVolume, 'x (mm)');
ylabel(app.axVolume, 'y (mm)');
zlabel(app.axVolume, 'z (mm)');
grid(app.axVolume, 'on');
view(app.axVolume, 36, 24);

metricPanel = uipanel(imageGrid, 'BorderType', 'none');
metricPanel.Layout.Row = 2;
metricGrid = uigridlayout(metricPanel, [1, 1]);
app.metrics = uitable(metricGrid, 'Data', cell(0, 2), 'ColumnName', {'指标', '数值'});

boardGrid = uigridlayout(app.boardTab, [3, 1]);
boardGrid.RowHeight = {90, 60, '1x'};
uilabel(boardGrid, 'Text', sprintf(['成像：4层×16激励×13测量=832值；探杆4值。\n' ...
    '已确认CAINI7：832成像→32温度→4压力→4探杆，3488字节，小端float32。\n' ...
    'FF触发采集；无额外帧头/校验。层1最低、层4最高，层内通道由左至右。']), 'WordWrap', 'on');
app.boardInfo = uilabel(boardGrid, 'Text', '尚未接收板卡应答。', 'WordWrap', 'on');
app.boardTable = uitable(boardGrid, 'Data', board_display_data([], 'firmware_ascending'), ...
    'ColumnName', {'数据组', '层', '激励序号', '激励电极（全局）', '测量电极/极性（全局）', '原始值'}, ...
    'ColumnEditable', false(1,6));

sensorGrid = uigridlayout(app.sensorTab, [3,1]);
sensorGrid.RowHeight = {65, '1x', 260};
app.sensorInfo = uilabel(sensorGrid, 'Text', ...
    '尚无数据。层由下至上、通道由左至右；压力按固件打印标为MPa，保留原始正负号。', 'WordWrap', 'on');
sensorPlotPanel = uipanel(sensorGrid, 'BorderType','none');
sensorPlotPanel.Layout.Row = 2;
sensorPlots = uigridlayout(sensorPlotPanel,[1,2]);
app.axTemperature = uiaxes(sensorPlots);
app.axTemperature.Layout.Row = 1; app.axTemperature.Layout.Column = 1;
title(app.axTemperature, '各层温度通道'); xlabel(app.axTemperature, '层内通道（左→右）');
ylabel(app.axTemperature, '温度原始值（单位待确认）'); grid(app.axTemperature, 'on');
app.axPressure = uiaxes(sensorPlots);
app.axPressure.Layout.Row = 1; app.axPressure.Layout.Column = 2;
title(app.axPressure, '四路压力变化'); xlabel(app.axPressure, '接收时间 (s)');
ylabel(app.axPressure, '压力 (MPa，按固件标注)'); grid(app.axPressure, 'on');
sensorTablePanel = uipanel(sensorGrid, 'BorderType','none');
sensorTablePanel.Layout.Row = 3;
sensorTables = uigridlayout(sensorTablePanel,[1,2]);
app.temperatureTable = uitable(sensorTables, 'Data', cell(16,5), ...
    'ColumnName', {'通道 左→右','第1层 最下','第2层','第3层','第4层 最上'}, 'ColumnEditable', false(1,5));
app.temperatureTable.Layout.Row = 1; app.temperatureTable.Layout.Column = 1;
app.pressureTable = uitable(sensorTables, 'Data', cell(4,2), ...
    'ColumnName', {'通道','压力 MPa（固件标注）'}, 'ColumnEditable', [false false]);
app.pressureTable.Layout.Row = 1; app.pressureTable.Layout.Column = 2;

app.fig.UserData = app;
log_msg('CAINI7默认3488字节小端：打开串口后发送FF采集；也可导入实测HEX/BIN离线查看。');
update_mode_controls(true);
if nargin > 0 && ~isempty(capture_file)
    try
        load_capture_into_app(capture_file);
    catch ME
        log_error(ME);
    end
end

    function import_board_cb(~, ~)
        [file,path] = uigetfile({'*.txt;*.hex;*.log;*.bin','3488字节HEX或BIN'},'导入一组CAINI7实测数据');
        if isequal(file,0), return; end
        try
            load_capture_into_app(fullfile(path,file));
        catch ME
            log_error(ME);
        end
    end

    function load_capture_into_app(filename)
        close_source_if_needed();
        app = app.fig.UserData;
        app.inputMode.Value = 'serial';
        app.lengthMode.Value = 'raw872';
        app.byteOrder.Value = 'little-endian';
        app.measurementOrder.Value = 'firmware_ascending';
        reset_sensor_display();
        app = app.fig.UserData;
        cfg = read_ui_cfg(app);
        [data,report] = read_eit71_board_capture(filename,cfg.board);
        update_sensor_display(data);
        app = app.fig.UserData;
        app.latest_frame = report.frame;
        app.latest_protocol_config = cfg.board;
        app.latest_capture_report = report;
        app.boardInfo.Text = sprintf('离线实测：%d字节，%d个float，%d个有限值；原始结构体无校验。', ...
            report.byte_count,report.float_count,report.finite_count);
        app.fig.UserData = app;
        update_mode_controls();
        app.tabs.SelectedTab = app.sensorTab;
        log_msg(sprintf('已导入实测文件：%s；字段顺序成像→温度→压力→探杆。',filename));
    end

    function mode_changed(~, ~)
        close_source_if_needed();
        app = app.fig.UserData;
        app.vh = [];
        app.fig.UserData = app;
        reset_sensor_display();
        update_mode_controls(true);
    end

    function wire_changed(~, ~)
        close_source_if_needed();
        reset_sensor_display();
        update_mode_controls();
    end

    function measurement_order_changed(~, ~)
        app = app.fig.UserData;
        values = [];
        if ~isempty(app.latest_telemetry), values = app.latest_telemetry.electrical; end
        app.boardTable.Data = board_display_data(values, app.measurementOrder.Value);
    end

    function reset_sensor_display()
        app = app.fig.UserData;
        app.sensor_clock = tic;
        app.sensor_history = struct('time_s', [], 'temperature', [], 'pressure', []);
        app.latest_telemetry = [];
        app.latest_frame = [];
        app.latest_protocol_config = [];
        app.latest_capture_report = [];
        app.boardTable.Data = board_display_data([], app.measurementOrder.Value);
        app.temperatureTable.Data = cell(0,5);
        app.pressureTable.Data = cell(0,2);
        cla(app.axTemperature); cla(app.axPressure);
        app.sensorInfo.Text = '尚无本次数据源的温度/压力数据。';
        app.fig.UserData = app;
    end

    function update_sensor_display(data)
        app = app.fig.UserData;
        if ~isempty(app.sensor_history.temperature) && ...
                size(app.sensor_history.temperature,2) ~= numel(data.temperature)
            reset_sensor_display();
            app = app.fig.UserData;
        end
        h = app.sensor_history;
        h.time_s(end+1,1) = toc(app.sensor_clock);
        h.temperature(end+1,:) = data.temperature(:)';
        h.pressure(end+1,:) = data.pressure(:)';
        keep = max(1,numel(h.time_s)-999):numel(h.time_s);
        h.time_s = h.time_s(keep); h.temperature = h.temperature(keep,:); h.pressure = h.pressure(keep,:);
        app.sensor_history = h;
        app.latest_telemetry = data;
        app.boardTable.Data = board_display_data(data.electrical, app.measurementOrder.Value);
        n = size(data.temperature_by_layer,1);
        app.temperatureTable.Data = num2cell([(1:n)', data.temperature_by_layer]);
        app.pressureTable.Data = [ ...
            {'P1 板1/左侧 下';'P2 板1/左侧 上';'P3 板2/右侧 下';'P4 板2/右侧 上'}, num2cell(data.pressure)];
        plot(app.axTemperature, 1:n, data.temperature_by_layer, '-o');
        xlabel(app.axTemperature, '层内通道（左→右）'); ylabel(app.axTemperature, '温度原始值（单位待确认）');
        title(app.axTemperature, sprintf('四层温度，每层%d通道', n));
        grid(app.axTemperature,'on'); legend(app.axTemperature, {'第1层 最下','第2层','第3层','第4层 最上'}, 'Location','best');
        plot(app.axPressure, h.time_s, h.pressure, '-o');
        pressure_label = '压力原始值（单位待确认）';
        if strcmp(data.length_mode,'raw872'), pressure_label = '压力 (MPa，按CAINI7固件标注)'; end
        xlabel(app.axPressure, '接收时间 (s)'); ylabel(app.axPressure, pressure_label);
        title(app.axPressure, '四路压力（最近1000帧）'); grid(app.axPressure,'on');
        legend(app.axPressure, {'板1压力1','板1压力2','板2压力1','板2压力2'}, 'Location','best');
        integrity = '帧校验通过';
        if ~data.integrity_verified, integrity = '原始结构体，无校验且不能证明字节对齐'; end
        app.sensorInfo.Text = sprintf('当前保留%d组，温度%d路，压力4路。%s。\n层由下至上、通道由左至右；压力保留原始负值，标定请核对传感板。', ...
            size(h.temperature,1), numel(data.temperature), integrity);
        app.fig.UserData = app;
    end

    function update_mode_controls(select_tab)
        if nargin < 1, select_tab = false; end
        app = app.fig.UserData;
        serial = strcmp(app.inputMode.Value, 'serial');
        app.collectReference.Enable = matlab.lang.OnOffSwitchState(~serial);
        app.selfCheck.Enable = matlab.lang.OnOffSwitchState(serial && ~startsWith(app.lengthMode.Value,'raw'));
        app.readBoard.Enable = matlab.lang.OnOffSwitchState(serial);
        app.boardAddress.Enable = matlab.lang.OnOffSwitchState(serial && ~startsWith(app.lengthMode.Value,'raw'));
        app.collectReference.Tooltip = '背景采集当前用于旧EIT1模拟日志；新836值需要匹配的测量模型与标定。';
        app.loadModel.Enable = matlab.lang.OnOffSwitchState(~serial);
        app.testOneCycle.Enable = matlab.lang.OnOffSwitchState(~serial);
        app.checksum.Enable = matlab.lang.OnOffSwitchState(~serial);
        app.triggerRaw.Enable = matlab.lang.OnOffSwitchState(strcmp(app.lengthMode.Value,'raw872'));
        if strcmp(app.lengthMode.Value,'raw872') && app.triggerRaw.Value
            app.readBoard.Text = '发送FF并采集一周期';
        elseif startsWith(app.lengthMode.Value,'raw')
            app.readBoard.Text = '接收一组板卡数据（被动）';
        else
            app.readBoard.Text = '读取板卡数据（0x01）';
        end
        if serial
            app.startStop.Text = '开始板卡采集';
            if select_tab, app.tabs.SelectedTab = app.boardTab; end
        else
            app.startStop.Text = '开始成像';
            if select_tab, app.tabs.SelectedTab = app.imageTab; end
        end
    end

    function close_source_cb(~, ~)
        close_source_if_needed();
        update_mode_controls();
        log_msg('数据源已关闭。');
    end

    function stop_acquisition()
        app = app.fig.UserData;
        if ~isempty(app.timer) && isvalid(app.timer)
            stop(app.timer);
            delete(app.timer);
        end
        app.timer = [];
        app.board_continuous = false;
        if ~isempty(app.source) && app.source.type == "serial"
            app.source.board.cancel();
        end
        app.fig.UserData = app;
        update_mode_controls();
    end

    function begin_board_monitor(type, continuous)
        try
            stop_acquisition();
            app = app.fig.UserData;
            if isempty(app.source) || app.source.type ~= "serial"
                error('请先选择串口模式并打开数据源；板卡采集不需要加载EIT模型。');
            end
            app.source.board.request(type);
            app.board_continuous = continuous;
            app.board_last_request = tic;
            app.timer = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.05, ...
                'BusyMode', 'drop', 'TimerFcn', @(~,~) process_board_tick());
            app.startStop.Text = '停止板卡采集';
            app.fig.UserData = app;
            start(app.timer);
            if Eit71BoardProtocol.isRaw(app.source.board.Config)
                info = Eit71BoardProtocol.layout(app.source.board.Config);
                if Eit71BoardProtocol.sendsTrigger(app.source.board.Config)
                    log_msg('已发送FF启动采集，等待3488字节。固件每周期固定延时约21秒以上，超时60秒。');
                else
                    log_msg(sprintf('被动原始模式：先等200ms空闲，再接收下一组%d字节，无校验。', info.payload_bytes));
                end
            else
                log_msg(sprintf('已发送指令0x%02X，等待板卡应答。', type));
            end
        catch ME
            log_error(ME);
        end
    end

    function process_board_tick()
        app = app.fig.UserData;
        try
            board = app.source.board;
            frames = board.tick();
            for k = 1:numel(frames)
                frame = frames{k};
                fault_nodes = find(frame.fault_bits) - 1;
                if isempty(fault_nodes)
                    bits = '无';
                else
                    bits = strjoin(string(fault_nodes), ',');
                end
                app.boardInfo.Text = sprintf('有效应答%d；TYPE=0x%02X；STATUS=0x%02X；置位故障bit：%s；丢弃字节%d', ...
                    board.RxCount, frame.type, frame.status, bits, board.RejectedBytes);
                if ~frame.status_available
                    app.boardInfo.Text = sprintf('原始数据组%d；无状态字段/校验；诊断模式；丢弃字节%d', board.RxCount, board.RejectedBytes);
                end
                if frame.type == 129
                    info = Eit71BoardProtocol.layout(board.Config);
                    if numel(frame.data) == info.payload_bytes
                        data = Eit71BoardProtocol.telemetry(frame, board.Config);
                        app.latest_frame = frame;
                        app.latest_protocol_config = board.Config;
                        app.latest_capture_report = [];
                        app.fig.UserData = app;
                        update_sensor_display(data);
                        if ~data.finite || (frame.status_available && frame.status ~= 0)
                            log_msg('板卡状态异常或数据含NaN/Inf；仅展示原始数据，请检查板卡及字节序。');
                        end
                    else
                        reset_sensor_display();
                        log_msg(sprintf('收到%d字节DATA，本格式需要%d字节；原始报文可保存。', numel(frame.data), info.payload_bytes));
                    end
                else
                    log_msg(sprintf('自检应答已收到，STATUS=0x%02X。', frame.status));
                end
            end
            if isempty(board.PendingType)
                if ~app.board_continuous
                    stop_acquisition();
                    return;
                end
                if toc(app.board_last_request) >= app.updateSeconds.Value
                    board.request(1);
                    app.board_last_request = tic;
                    app.fig.UserData = app;
                end
            end
        catch ME
            stop_acquisition();
            log_error(ME);
        end
    end

    function save_board_cb(~, ~)
        app = app.fig.UserData;
        try
            if isempty(app.latest_frame)
                error('尚无可保存的板卡报文。');
            end
            [file, path] = uiputfile('*.mat', '保存最近板卡报文', 'eit71_board_snapshot.mat');
            if isequal(file, 0), return; end
            frame = app.latest_frame;
            protocol_config = app.latest_protocol_config;
            received_frame_count = size(app.sensor_history.temperature,1);
            saved_at = datestr(now, 30);
            telemetry = [];
            info = Eit71BoardProtocol.layout(protocol_config);
            if frame.type == 129 && numel(frame.data) == info.payload_bytes
                telemetry = Eit71BoardProtocol.telemetry(frame, protocol_config);
            end
            sensor_history = app.sensor_history;
            measurement_map = Eit71MeasurementLayout.rows(app.measurementOrder.Value);
            save(fullfile(path, file), 'frame', 'telemetry', 'protocol_config', 'received_frame_count', ...
                'saved_at', 'sensor_history', 'measurement_map');
            log_msg('最近报文已保存，包含原始字节、状态及解析配置。');
        catch ME
            log_error(ME);
        end
    end

    function browse_mock(~, ~)
        [file, path] = uigetfile({'*.txt;*.csv;*.log', '日志文件'}, '选择模拟串口日志', app_dir());
        if isequal(file, 0), return; end
        app = app.fig.UserData;
        app.mockFile.Value = fullfile(path, file);
        app.fig.UserData = app;
    end

    function browse_model(~, ~)
        [file, path] = uigetfile({'*.mat', 'MAT文件'}, '选择重建模型MAT文件', app_dir());
        if isequal(file, 0), return; end
        app = app.fig.UserData;
        app.modelMat.Value = fullfile(path, file);
        app.fig.UserData = app;
    end

    function load_model(~, ~)
        app = app.fig.UserData;
        try
            stop_acquisition();
            app = app.fig.UserData;
            cfg = read_ui_cfg(app);
            app.ctx = load_reconstruction_context(cfg);
            app.vh = [];
            app.fig.UserData = app;
            log_msg(sprintf('模型加载完成：每周期%d个测量值，%d个体素，%d个激励。', ...
                size(app.ctx.J, 1), size(app.ctx.J, 2), numel(app.ctx.stim_table)));
            update_metrics({'模型状态', '已加载'; '每周期测量数', size(app.ctx.J, 1); ...
                '重建体素数', size(app.ctx.J, 2); '激励数', numel(app.ctx.stim_table)});
        catch ME
            log_error(ME);
        end
    end

    function open_source_cb(~, ~)
        app = app.fig.UserData;
        try
            close_source_if_needed();
            reset_sensor_display();
            app = app.fig.UserData;
            cfg = read_ui_cfg(app);
            app.source = open_data_source(cfg);
            app.vh = [];
            app.fig.UserData = app;
            if app.source.type == "file"
                log_msg(sprintf('模拟文件已打开：%s', cfg.mock_log_file));
            else
                app.boardTable.Data = board_display_data([], app.measurementOrder.Value);
                app.boardInfo.Text = '尚未接收板卡应答。';
                log_msg(sprintf('串口已打开：%s @ %d，8N1；地址0x%02X；%s；长度%s。', ...
                    cfg.serial_port, cfg.baud_rate, cfg.board.address, cfg.board.byte_order, cfg.board.length_mode));
                log_msg('串口按打开时的配置运行；更改地址、字节序或LENGTH后请重新打开数据源。');
                if strcmp(cfg.board.length_mode, 'uint8')
                    log_msg('872个float需要3488字节DATA，单字节长度不足；请按固件实际帧格式设置。');
                elseif Eit71BoardProtocol.isRaw(cfg.board)
                    log_msg('原始结构体无额外帧头/校验。CAINI7需COND_SEND_RAW=1；FF触发，等待60秒，不能并行用串口助手触发。');
                end
            end
        catch ME
            log_error(ME);
        end
    end

    function collect_reference_cb(~, ~)
        app = app.fig.UserData;
        try
            ensure_model_and_source();
            if app.source.type ~= "file"
                error('新扫描每周期836值与原6700行模型不匹配；探杆为Vpp，需建立匹配的新Jacobian并确认电流和增益标定。');
            end
            stop_acquisition();
            app = app.fig.UserData;
            cfg = read_ui_cfg(app);
            log_msg(sprintf('正在采集%d个背景参考周期...', cfg.reference_average_count));
            app.vh = collect_reference(app.source, app.ctx, cfg, @log_msg);
            app.fig.UserData = app;
            log_msg('背景参考采集完成。');
        catch ME
            log_error(ME);
        end
    end

    function start_stop_cb(~, ~)
        app = app.fig.UserData;
        if ~isempty(app.timer) && isvalid(app.timer) && strcmp(app.timer.Running, 'on')
            stop_acquisition();
            log_msg('采集已停止。');
            return;
        end

        if strcmp(app.inputMode.Value, 'serial')
            begin_board_monitor(1, true);
            return;
        end

        try
            ensure_model_and_source();
            if isempty(app.vh)
                error('请先采集背景参考。');
            end
            cfg = read_ui_cfg(app);
            stop_acquisition();
            app = app.fig.UserData;
            app.cycle_count = 0;
            app.timer = timer('ExecutionMode', 'fixedSpacing', ...
                'Period', max(0.05, cfg.display_update_seconds), ...
                'BusyMode', 'drop', ...
                'TimerFcn', @(~,~) process_one_cycle());
            app.startStop.Text = '停止成像';
            app.fig.UserData = app;
            start(app.timer);
            log_msg('实时成像已开始。');
        catch ME
            log_error(ME);
        end
    end

    function process_one_cycle()
        app = app.fig.UserData;
        try
            cfg = read_ui_cfg(app);
            vi = collect_full_measurement_set(app.source, app.ctx, cfg);
            [rho, delta_sigma, stats] = reconstruct_cycle(app.ctx, app.vh, vi, cfg);
            app.cycle_count = app.cycle_count + 1;
            app.last_rho = rho;
            app.last_delta_sigma = delta_sigma;
            app.fig.UserData = app;
            plot_realtime_resistivity(app, rho, delta_sigma);
            update_metrics({'周期编号', app.cycle_count; '差分电压RMS(V)', stats.dv_rms; ...
                '最大|电导率变化|(S/m)', stats.max_abs_delta_sigma; ...
                '最小电阻率(Ohm m)', stats.min_rho; '最大电阻率(Ohm m)', stats.max_rho});
        catch ME
            app = app.fig.UserData;
            stop_acquisition();
            if strcmp(ME.identifier, 'EIT:EndOfMockLog')
                log_msg('模拟串口日志已读完，文件回放结束。');
            else
                log_error(ME);
            end
        end
    end

    function test_protocol_cb(~, ~)
        app = app.fig.UserData;
        try
            if strcmp(app.inputMode.Value, 'serial')
                cfg = read_ui_cfg(app);
                data_command = Eit71BoardProtocol.command(1, cfg.board);
                info = Eit71BoardProtocol.layout(cfg.board);
                if isempty(data_command)
                    log_msg('本配置为被动接收，不发送采集触发。');
                else
                    log_msg(sprintf('数据请求：%s', strtrim(sprintf('%02X ', data_command))));
                end
                log_msg(sprintf('本格式%d个float、%d字节；电测量832+4，温度%d，压力4。', ...
                    info.float_count, info.payload_bytes, info.temperature_count));
                return;
            end
            cfg = read_ui_cfg(app);
            ctx = load_reconstruction_context(cfg);
            expected = sum([ctx.stim_table.n_meas]);
            update_metrics({'协议测试', '通过'; 'J矩阵行数', size(ctx.J, 1); ...
                '协议测量数', expected; '激励数', numel(ctx.stim_table)});
            log_msg('协议匹配测试通过。');
        catch ME
            log_error(ME);
        end
    end

    function test_parser_cb(~, ~)
        app = app.fig.UserData;
        try
            if strcmp(app.inputMode.Value, 'serial')
                log_msg('串口协议验证请使用“板卡自检”及“读取板卡数据”；离线回归测试：test_eit71_board_protocol。');
                return;
            end
            cfg = read_ui_cfg(app);
            fid = fopen(cfg.mock_log_file, 'r');
            if fid < 0
                error('无法打开模拟文件：%s', cfg.mock_log_file);
            end
            c = onCleanup(@() fclose(fid));
            line = "";
            while strlength(line) == 0 || startsWith(line, "#")
                raw = fgetl(fid);
                if ~ischar(raw)
                    error('模拟文件中没有找到数据帧。');
                end
                line = strtrim(string(raw));
            end
            frame = parse_eit_ascii_frame(line, cfg);
            clear c;
            update_metrics({'解析测试', '通过'; '帧编号', frame.frame_id; ...
                '激励编号', frame.stim_id; '正激励电极', frame.i_plus; ...
                '负激励电极', frame.i_minus; '电压通道数', numel(frame.voltage)});
            log_msg('解析/文件测试通过。');
        catch ME
            log_error(ME);
        end
    end

    function test_one_cycle_cb(~, ~)
        app = app.fig.UserData;
        try
            if strcmp(app.inputMode.Value, 'serial')
                error('单周期重建测试使用旧EIT1模拟日志，请先切换到模拟文件模式。');
            end
            close_source_if_needed();
            app = app.fig.UserData;
            if isempty(app.ctx)
                cfg = read_ui_cfg(app);
                app.ctx = load_reconstruction_context(cfg);
            end
            cfg = read_ui_cfg(app);
            cfg.input_mode = "file";
            app.source = open_data_source(cfg);
            % The logger reads UserData; publish the new source/context first.
            app.fig.UserData = app;
            app.vh = collect_reference(app.source, app.ctx, cfg, @log_msg);
            vi = collect_full_measurement_set(app.source, app.ctx, cfg);
            [rho, delta_sigma, stats] = reconstruct_cycle(app.ctx, app.vh, vi, cfg);
            app.cycle_count = 1;
            app.last_rho = rho;
            app.last_delta_sigma = delta_sigma;
            app.fig.UserData = app;
            plot_realtime_resistivity(app, rho, delta_sigma);
            update_metrics({'单周期测试', '通过'; '差分电压RMS(V)', stats.dv_rms; ...
                '最大|电导率变化|(S/m)', stats.max_abs_delta_sigma; ...
                '最小电阻率(Ohm m)', stats.min_rho; '最大电阻率(Ohm m)', stats.max_rho});
            log_msg('单周期重建测试通过。');
        catch ME
            log_error(ME);
        end
    end

    function cfg = read_ui_cfg(app)
        cfg = struct();
        cfg.input_mode = string(app.inputMode.Value);
        cfg.serial_port = string(app.serialPort.Value);
        cfg.baud_rate = str2double(app.baudRate.Value);
        cfg.terminator = "LF";
        cfg.mock_log_file = string(app.mockFile.Value);
        cfg.result_mat = string(app.modelMat.Value);
        cfg.num_electrodes = 71;
        cfg.boundary_electrodes = 64;
        cfg.probe_electrodes = 65:71;
        cfg.current_rms_A = 10e-3;
        cfg.frequency_Hz = 1000;
        cfg.require_checksum = app.checksum.Value;
        address = strtrim(app.boardAddress.Value);
        address = regexprep(address, '^0[xX]', '');
        if isempty(regexp(address, '^[0-9A-Fa-f]{1,2}$', 'once'))
            error('板卡地址应为00到FF的十六进制数。');
        end
        cfg.board = Eit71BoardProtocol.defaults();
        cfg.board.address = uint8(hex2dec(address));
        cfg.board.byte_order = app.byteOrder.Value;
        cfg.board.length_mode = app.lengthMode.Value;
        cfg.board.trigger_raw872 = app.triggerRaw.Value;
        cfg.reference_average_count = app.refCycles.Value;
        cfg.noser_lambda = app.lambda.Value;
        cfg.display_update_seconds = app.updateSeconds.Value;
        cfg.include_probe_adjacent_drives = true;
        cfg.include_probe_to_boundary_drives = true;
        cfg.include_probe_voltage_measurements = true;
    end

    function ensure_model_and_source()
        app = app.fig.UserData;
        if isempty(app.ctx)
            error('请先加载模型。');
        end
        if isempty(app.source)
            error('请先打开数据源。');
        end
    end

    function close_source_if_needed()
        stop_acquisition();
        app = app.fig.UserData;
        if ~isempty(app.source)
            close_data_source(app.source);
            app.source = [];
            app.fig.UserData = app;
        end
    end

    function log_msg(msg)
        app = app.fig.UserData;
        stamp = datestr(now, 'HH:MM:SS');
        lines = app.status.Items;
        if ischar(lines), lines = cellstr(lines); end
        lines = [{sprintf('[%s] %s', stamp, msg)}; lines(:)];
        lines = lines(1:min(numel(lines), 120));
        app.status.Items = lines;
        app.status.Value = lines{1};
        drawnow limitrate;
    end

    function log_error(ME)
        log_msg(sprintf('错误：%s', ME.message));
    end

    function update_metrics(data)
        app = app.fig.UserData;
        app.metrics.Data = data;
    end

    function on_close(src, ~)
        state = [];
        src_ok = is_valid_graphics_object(src);
        if nargin >= 1 && src_ok && isprop(src, 'UserData') && isstruct(src.UserData)
            state = src.UserData;
        elseif isstruct(app)
            state = app;
        end

        try
            if isstruct(state) && isfield(state, 'timer') && ...
                    ~isempty(state.timer) && isvalid(state.timer)
                stop(state.timer);
                delete(state.timer);
            end
        catch
        end

        try
            if isstruct(state) && isfield(state, 'source') && ~isempty(state.source)
                close_data_source(state.source);
            end
        catch
        end

        try
            if nargin >= 1 && src_ok
                delete(src);
            elseif isstruct(state) && isfield(state, 'fig') && isvalid(state.fig)
                delete(state.fig);
            end
        catch
            delete(gcf);
        end
    end
end

function tf = is_valid_graphics_object(h)
tf = false;
try
    tf = isgraphics(h) || (isobject(h) && isvalid(h));
catch
    tf = false;
end
end

function rows = board_display_data(values, order)
map = Eit71MeasurementLayout.rows(order);
rows = cell(836,6);
rows(:,1) = [repmat({'成像差分'},832,1); repmat({'探杆Vpp'},4,1)];
rows(:,2) = num2cell(map(:,2));
rows(:,3) = num2cell(map(:,3));
for k = 1:836
    rows{k,4} = sprintf('%d → %d', map(k,5), map(k,6));
    if k <= 832
        rows{k,5} = sprintf('V%d - V%d', map(k,7), map(k,8));
    else
        rows{k,5} = sprintf('Vpp(%d,%d)', map(k,7), map(k,8));
    end
end
if ~isempty(values)
    rows(:,6) = num2cell(values(:));
end
end

function [rho, delta_sigma, stats] = reconstruct_cycle(ctx, vh, vi, cfg)
dv = vi(:) - vh(:);
delta_sigma = solve_noser_weighted(ctx.J, dv, cfg.noser_lambda);
sigma = max(ctx.min_sigma_S_per_m, ctx.coarse_bkgnd_sigma + delta_sigma);
rho = 1 ./ sigma;
stats.dv_rms = sqrt(mean(dv.^2));
stats.max_abs_delta_sigma = max(abs(delta_sigma));
stats.min_rho = min(rho);
stats.max_rho = max(rho);
end

function ctx = load_reconstruction_context(cfg)
if ~exist(cfg.result_mat, 'file')
    error('未找到模型MAT文件：%s', cfg.result_mat);
end

S = load(cfg.result_mat, 'cfg', 'fmdl', 'imdl', 'elem_center', 'probe', ...
    'rec_centers_m', 'coarse_bkgnd_sigma', 'J');
sim_cfg = S.cfg;

ctx.size_m = sim_cfg.size_m;
ctx.sediment_top_z_m = sim_cfg.sediment_top_z_m;
ctx.min_sigma_S_per_m = 1e-6;
ctx.elem_center = S.elem_center;
ctx.imdl = S.imdl;

if isfield(S, 'rec_centers_m') && ~isempty(S.rec_centers_m)
    ctx.rec_centers_m = S.rec_centers_m;
else
    ctx.rec_centers_m = coarse_centers_from_c2f(ctx.imdl.fwd_model.coarse2fine, ctx.elem_center);
end

if isfield(S, 'coarse_bkgnd_sigma') && ~isempty(S.coarse_bkgnd_sigma)
    ctx.coarse_bkgnd_sigma = S.coarse_bkgnd_sigma;
else
    ctx.coarse_bkgnd_sigma = sim_cfg.seawater_conductivity * ...
        ones(size(ctx.rec_centers_m, 1), 1);
    ctx.coarse_bkgnd_sigma(ctx.rec_centers_m(:,3) <= sim_cfg.sediment_top_z_m) = ...
        sim_cfg.sediment_conductivity;
end

if isfield(S, 'J') && ~isempty(S.J)
    ctx.J = S.J;
else
    error('可执行GUI模式需要模型MAT中包含Jacobian矩阵J。请重新运行仿真脚本并保存J。');
end

elec_pos = boundary_electrode_positions_from_cfg(sim_cfg);
if isfield(S, 'probe') && isfield(S.probe, 'electrode_model_m')
    probe_pos = S.probe.electrode_model_m;
    cfg.probe_electrodes = S.probe.electrode_index(:)';
else
    probe_pos = user_mm_to_model_m(sim_cfg.probe_electrode_user_mm, sim_cfg.size_m);
end
ctx.boundary_elec_mm = model_to_user_mm(elec_pos(:,1:3), ctx.size_m);
ctx.probe_elec_mm = model_to_user_mm(probe_pos(:,1:3), ctx.size_m);

ctx.boundary_pairs = boundary_adjacent_pairs(16, 4);
ctx.probe_pairs = [cfg.probe_electrodes(1:end-1)', cfg.probe_electrodes(2:end)'];
ctx.mixed_pairs = nearest_probe_boundary_pairs(elec_pos(1:cfg.boundary_electrodes,:), ...
    probe_pos, cfg.probe_electrodes(:));
ctx.drive_pairs = ctx.boundary_pairs;
if cfg.include_probe_adjacent_drives
    ctx.drive_pairs = [ctx.drive_pairs; ctx.probe_pairs];
end
if cfg.include_probe_to_boundary_drives
    ctx.drive_pairs = [ctx.drive_pairs; ctx.mixed_pairs];
end

ctx.meas_pairs = ctx.boundary_pairs;
if cfg.include_probe_voltage_measurements
    ctx.meas_pairs = unique_pair_rows([ctx.meas_pairs; ctx.probe_pairs; ctx.mixed_pairs]);
end

ctx.stim_table = build_stim_table(ctx.drive_pairs, ctx.meas_pairs);
expected_meas = sum([ctx.stim_table.n_meas]);
if size(ctx.J, 1) ~= expected_meas
    error('测量数量不匹配：J矩阵有%d行，但当前协议生成%d个测量值。', ...
        size(ctx.J, 1), expected_meas);
end
end

function source = open_data_source(cfg)
if cfg.input_mode == "file"
    fid = fopen(cfg.mock_log_file, 'r');
    if fid < 0
        error('无法打开模拟日志文件：%s', cfg.mock_log_file);
    end
    source = struct('type', "file", 'fid', fid, 'sp', []);
else
    sp = serialport(cfg.serial_port, cfg.baud_rate, 'Timeout', 1, ...
        'DataBits', 8, 'Parity', 'none', 'StopBits', 1, 'FlowControl', 'none');
    flush(sp);
    source = struct('type', "serial", 'fid', [], 'board', Eit71BoardSession(sp, cfg.board));
end
end

function close_data_source(source)
try
    if source.type == "file"
        fclose(source.fid);
    else
        delete(source.board);
    end
catch
end
end

function line = read_source_line(source)
while true
    if source.type == "file"
        raw = fgetl(source.fid);
        if ~ischar(raw)
            error('EIT:EndOfMockLog', '模拟串口日志已读完。');
        end
        line = string(raw);
    else
        error('EIT:BoardNotVoltage', '新板卡二进制数据不能作为EIT1电压帧读取。');
    end

    line = strtrim(line);
    if strlength(line) == 0 || startsWith(line, "#")
        continue;
    end
    return;
end
end

function vh = collect_reference(source, ctx, cfg, logger)
if nargin < 4
    logger = [];
end
all_meas = zeros(size(ctx.J, 1), cfg.reference_average_count);
for k = 1:cfg.reference_average_count
    if ~isempty(logger)
        logger(sprintf('正在采集背景参考周期 %d/%d...', k, cfg.reference_average_count));
    end
    all_meas(:, k) = collect_full_measurement_set(source, ctx, cfg);
end
vh = mean(all_meas, 2);
end

function meas = collect_full_measurement_set(source, ctx, cfg)
meas = NaN(size(ctx.J, 1), 1);
got = false(numel(ctx.stim_table), 1);
while ~all(got)
    line = read_source_line(source);
    frame = parse_eit_ascii_frame(line, cfg);
    if frame.stim_id < 1 || frame.stim_id > numel(ctx.stim_table)
        warning('忽略超出范围的激励编号 stim_id=%d', frame.stim_id);
        continue;
    end

    stim = ctx.stim_table(frame.stim_id);
    if frame.i_plus ~= stim.drive_pair(1) || frame.i_minus ~= stim.drive_pair(2)
        warning('激励编号%d的激励电极不匹配：收到%d-%d，应为%d-%d。', ...
            frame.stim_id, frame.i_plus, frame.i_minus, ...
            stim.drive_pair(1), stim.drive_pair(2));
        continue;
    end

    meas(stim.row_start:stim.row_end) = electrode_to_meas(frame.voltage(:), stim.meas_pairs);
    got(frame.stim_id) = true;
end
end

function frame = parse_eit_ascii_frame(line, cfg)
if strlength(line) == 0 || extractBefore(line, 2) ~= "$"
    error('串口帧前缀无效：%s', line);
end

star = strfind(char(line), '*');
if isempty(star)
    if cfg.require_checksum
        error('缺少校验码：%s', line);
    end
    payload = extractAfter(line, 1);
else
    payload = extractBetween(line, 2, star(1) - 1);
    payload = payload{1};
    checksum_text = extractAfter(line, star(1));
    if cfg.require_checksum
        expected = upper(string(checksum_text));
        actual = upper(string(dec2hex(xor_checksum(char(payload)), 2)));
        if expected ~= actual
            error('校验码不匹配：收到%s，应为%s。', expected, actual);
        end
    end
end

parts = split(string(payload), ',');
if parts(1) ~= "EIT1"
    error('不支持的帧类型：%s', parts(1));
end
expected_count = 7 + cfg.num_electrodes;
if numel(parts) ~= expected_count
    error('数据字段数量错误：应有%d个字段，实际%d个。', expected_count, numel(parts));
end

frame.frame_id = str2double(parts(2));
frame.stim_id = str2double(parts(3));
frame.i_plus = str2double(parts(4));
frame.i_minus = str2double(parts(5));
frame.irms_A = str2double(parts(6));
frame.freq_Hz = str2double(parts(7));
frame.voltage = str2double(parts(8:end));
if any(~isfinite(frame.voltage))
    error('数据帧中包含非有限电压值。');
end
end

function c = xor_checksum(payload)
bytes = uint8(payload);
c = uint8(0);
for i = 1:numel(bytes)
    c = bitxor(c, bytes(i));
end
end

function meas = electrode_to_meas(v_elec, meas_pairs)
meas = v_elec(meas_pairs(:,1)) - v_elec(meas_pairs(:,2));
end

function stim_table = build_stim_table(drive_pairs, meas_pairs)
stim_table = repmat(struct('drive_pair', [], 'meas_pairs', [], ...
    'row_start', NaN, 'row_end', NaN, 'n_meas', NaN), size(drive_pairs, 1), 1);
row = 1;
for k = 1:size(drive_pairs, 1)
    pair = drive_pairs(k, :);
    use = meas_pairs(:,1) ~= pair(1) & meas_pairs(:,2) ~= pair(1) & ...
          meas_pairs(:,1) ~= pair(2) & meas_pairs(:,2) ~= pair(2);
    mp = meas_pairs(use, :);
    n = size(mp, 1);
    stim_table(k).drive_pair = pair;
    stim_table(k).meas_pairs = mp;
    stim_table(k).row_start = row;
    stim_table(k).row_end = row + n - 1;
    stim_table(k).n_meas = n;
    row = row + n;
end
end

function x = solve_noser_weighted(J, dv, lambda)
[Jn, bn] = normalize_system(J, dv);
rhs = Jn' * bn;
diag_w = full(sum(Jn.^2, 1))';
diag_w = sqrt(max(diag_w, max(diag_w) * 1e-6));
Afun = @(z) Jn' * (Jn * z) + lambda^2 * (diag_w .* z);
x = pcg(Afun, rhs, 1e-4, 120, [], [], zeros(size(J,2), 1));
end

function [Jn, bn] = normalize_system(J, dv)
dv = dv(:);
scale = max(eps, norm(dv) / sqrt(numel(dv)));
Jn = J / scale;
bn = dv / scale;
end

function plot_realtime_resistivity(app, rho, delta_sigma)
ctx = app.ctx;
xyz = model_to_user_mm(ctx.rec_centers_m, ctx.size_m);

cla(app.axXZ);
y_mid = ctx.size_m(2) * 500;
[~, order_y] = sort(abs(xyz(:,2) - y_mid), 'ascend');
idx_xz = order_y(1:min(1200, numel(order_y)));
scatter(app.axXZ, xyz(idx_xz,1), xyz(idx_xz,3), 18, rho(idx_xz), 'filled');
xlim(app.axXZ, [0, ctx.size_m(1)*1000]);
ylim(app.axXZ, [0, ctx.size_m(3)*1000]);
title(app.axXZ, sprintf('电阻率XZ散点图，周期%d', app.cycle_count));
xlabel(app.axXZ, 'x (mm)');
ylabel(app.axXZ, 'z (mm)');
grid(app.axXZ, 'on');
colorbar(app.axXZ);

cla(app.ax3D);
[~, ord] = sort(delta_sigma, 'ascend');
idx = ord(1:min(900, numel(ord)));
scatter3(app.ax3D, xyz(idx,1), xyz(idx,2), xyz(idx,3), 16, rho(idx), 'filled');
xlim(app.ax3D, [0, ctx.size_m(1)*1000]);
ylim(app.ax3D, [0, ctx.size_m(2)*1000]);
zlim(app.ax3D, [0, ctx.size_m(3)*1000]);
title(app.ax3D, '低电导/高电阻率候选区域');
xlabel(app.ax3D, 'x (mm)');
ylabel(app.ax3D, 'y (mm)');
zlabel(app.ax3D, 'z (mm)');
grid(app.ax3D, 'on');
view(app.ax3D, 36, 24);
colorbar(app.ax3D);

cla(app.axVolume);
hold(app.axVolume, 'on');
draw_cuboid_edges(app.axVolume, ctx.size_m);
draw_layer_interface(app.axVolume, ctx.size_m, ctx.sediment_top_z_m);
if isfield(ctx, 'boundary_elec_mm')
    scatter3(app.axVolume, ctx.boundary_elec_mm(:,1), ctx.boundary_elec_mm(:,2), ...
        ctx.boundary_elec_mm(:,3), 22, 's', 'filled', ...
        'MarkerFaceColor', [0.0 0.25 0.95], 'MarkerEdgeColor', [0 0 0.35]);
end
if isfield(ctx, 'probe_elec_mm')
    scatter3(app.axVolume, ctx.probe_elec_mm(:,1), ctx.probe_elec_mm(:,2), ...
        ctx.probe_elec_mm(:,3), 38, 'o', 'filled', ...
        'MarkerFaceColor', [0.85 0.0 0.85], 'MarkerEdgeColor', [0.25 0 0.25]);
    plot3(app.axVolume, ctx.probe_elec_mm(:,1), ctx.probe_elec_mm(:,2), ...
        ctx.probe_elec_mm(:,3), '-', 'Color', [0.65 0 0.65], 'LineWidth', 1.4);
end

n_show = min(4500, size(xyz, 1));
idx_all = unique(round(linspace(1, size(xyz, 1), n_show)));
scatter3(app.axVolume, xyz(idx_all,1), xyz(idx_all,2), xyz(idx_all,3), ...
    9, delta_sigma(idx_all), 'filled');
idx_hot = ord(1:min(450, numel(ord)));
scatter3(app.axVolume, xyz(idx_hot,1), xyz(idx_hot,2), xyz(idx_hot,3), ...
    24, rho(idx_hot), 'filled', 'MarkerEdgeColor', [0.15 0.15 0.15]);
xlim(app.axVolume, [0, ctx.size_m(1)*1000]);
ylim(app.axVolume, [0, ctx.size_m(2)*1000]);
zlim(app.axVolume, [0, ctx.size_m(3)*1000]);
title(app.axVolume, sprintf('长方体三维动态成像，周期%d', app.cycle_count));
xlabel(app.axVolume, 'x (mm)');
ylabel(app.axVolume, 'y (mm)');
zlabel(app.axVolume, 'z (mm)');
grid(app.axVolume, 'on');
axis(app.axVolume, 'vis3d');
view(app.axVolume, 36, 24);
colorbar(app.axVolume);
hold(app.axVolume, 'off');
end

function draw_cuboid_edges(ax, size_m)
sx = size_m(1) * 1000;
sy = size_m(2) * 1000;
sz = size_m(3) * 1000;
v = [0 0 0; sx 0 0; sx sy 0; 0 sy 0; ...
     0 0 sz; sx 0 sz; sx sy sz; 0 sy sz];
e = [1 2; 2 3; 3 4; 4 1; 5 6; 6 7; 7 8; 8 5; 1 5; 2 6; 3 7; 4 8];
for i = 1:size(e, 1)
    plot3(ax, v(e(i,:),1), v(e(i,:),2), v(e(i,:),3), ...
        '-', 'Color', [0.05 0.05 0.05], 'LineWidth', 1.0);
end
end

function draw_layer_interface(ax, size_m, z_m)
sx = size_m(1) * 1000;
sy = size_m(2) * 1000;
z = z_m * 1000;
plot3(ax, [0 sx sx 0 0], [0 0 sy sy 0], z * ones(1,5), ...
    '--', 'Color', [0.0 0.45 0.85], 'LineWidth', 1.2);
end

function pairs = boundary_adjacent_pairs(n_per_layer, n_layers)
pairs = zeros(n_per_layer * n_layers, 2);
k = 0;
for layer = 1:n_layers
    base = (layer - 1) * n_per_layer;
    for i = 1:n_per_layer
        k = k + 1;
        pairs(k,:) = [base + i, base + mod(i, n_per_layer) + 1];
    end
end
end

function pairs = nearest_probe_boundary_pairs(elec_pos, probe_pos, probe_elec_idx)
left_idx = find(elec_pos(:,1) < 0);
right_idx = find(elec_pos(:,1) > 0);
pairs = zeros(2 * numel(probe_elec_idx), 2);
k = 0;
for i = 1:numel(probe_elec_idx)
    p = probe_pos(i,:);
    [~, il] = min(sum((elec_pos(left_idx,1:3) - p).^2, 2));
    k = k + 1;
    pairs(k,:) = [probe_elec_idx(i), left_idx(il)];
    [~, ir] = min(sum((elec_pos(right_idx,1:3) - p).^2, 2));
    k = k + 1;
    pairs(k,:) = [probe_elec_idx(i), right_idx(ir)];
end
end

function elec_pos = boundary_electrode_positions_from_cfg(cfg)
hx = cfg.size_m(1) / 2;
side_pos = linspace(-0.060, 0.060, 8);
elec_pos = zeros(cfg.n_elec_per_ring * cfg.n_rings, 6);
k = 0;
for iz = 1:cfg.n_rings
    z = cfg.ring_z_m(iz);
    for y = side_pos
        k = k + 1;
        elec_pos(k,:) = [-hx, y, z, -1, 0, 0];
    end
    for y = fliplr(side_pos)
        k = k + 1;
        elec_pos(k,:) = [ hx, y, z,  1, 0, 0];
    end
end
end

function pairs = unique_pair_rows(pairs)
pairs = sort(pairs, 2);
[~, ia] = unique(pairs, 'rows');
pairs = pairs(sort(ia), :);
end

function rec_centers_m = coarse_centers_from_c2f(c2f, fine_centers_m)
col_weight = full(sum(c2f, 1))';
col_weight(col_weight == 0) = 1;
rec_centers_m = (c2f' * fine_centers_m) ./ col_weight;
end

function xyz_mm = model_to_user_mm(xyz_m, size_m)
xyz_mm = xyz_m * 1000;
xyz_mm(:,1) = xyz_mm(:,1) + size_m(1) * 500;
xyz_mm(:,2) = xyz_mm(:,2) + size_m(2) * 500;
end

function centers_m = user_mm_to_model_m(centers_mm, size_m)
centers_m = centers_mm / 1000;
centers_m(:,1) = centers_m(:,1) - size_m(1)/2;
centers_m(:,2) = centers_m(:,2) - size_m(2)/2;
end

function h = add_form_label(parent, row, text)
h = uilabel(parent, 'Text', text, 'HorizontalAlignment', 'right');
h.Layout.Row = row;
h.Layout.Column = 1;
end

function p = locate_runtime_file(filename)
candidate = fullfile(app_dir(), filename);
if exist(candidate, 'file')
    p = candidate;
    return;
end

resolved = which(filename);
if ~isempty(resolved)
    p = resolved;
    return;
end

p = candidate;
end

function d = app_dir()
if isdeployed
    d = ctfroot;
else
    this_file = mfilename('fullpath');
    d = fileparts(this_file);
end
end
