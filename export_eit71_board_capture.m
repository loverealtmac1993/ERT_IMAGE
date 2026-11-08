function result = export_eit71_board_capture(filename, output_dir)
% Export a final CAINI7 raw872 sample with byte/float/channel traceability.
if nargin < 2, output_dir = fullfile(fileparts(mfilename('fullpath')),'caini7_capture_decoded'); end
[telemetry, report] = read_eit71_board_capture(filename);
if ~isfolder(output_dir), mkdir(output_dir); end
result.mat = fullfile(output_dir,'capture_decoded.mat');
save(result.mat,'telemetry','report');
result.bin = fullfile(output_dir,'capture_raw872.bin');
fid=fopen(result.bin,'wb'); c=onCleanup(@() fclose(fid));
fwrite(fid,telemetry.raw_frame,'uint8'); clear c;

map=Eit71MeasurementLayout.rows('firmware_ascending');
n=832; wire=(1:n)';
eit=table(wire,(wire-1)*4+1,wire*4,map(1:n,2),map(1:n,3),map(1:n,4), ...
    map(1:n,5),map(1:n,6),map(1:n,7),map(1:n,8),telemetry.eit, ...
    'VariableNames',{'FloatIndex','ByteStart1','ByteEnd1','LayerBottomToTop','StimIndex', ...
    'MeasureIndex','IplusGlobal','IminusGlobal','VplusGlobal','VminusGlobal','RawDifferential'});
result.eit_csv=fullfile(output_dir,'eit_832.csv'); writetable(eit,result.eit_csv,'Encoding','UTF-8');

wire=(833:864)'; layer=repelem((1:4)',8); channel=repmat((1:8)',4,1);
temp=table(wire,(wire-1)*4+1,wire*4,layer,channel,telemetry.temperature, ...
    'VariableNames',{'FloatIndex','ByteStart1','ByteEnd1','LayerBottomToTop','ChannelLeftToRight','RawTemperature'});
result.temperature_csv=fullfile(output_dir,'temperature_32.csv'); writetable(temp,result.temperature_csv,'Encoding','UTF-8');

wire=(865:868)'; channel=(1:4)'; board=[1;1;2;2]; local=[1;2;1;2];
pressure=table(wire,(wire-1)*4+1,wire*4,channel,board,local,telemetry.pressure, ...
    'VariableNames',{'FloatIndex','ByteStart1','ByteEnd1','Channel','Board','BoardChannel','Pressure_MPa_FirmwareLabel'});
result.pressure_csv=fullfile(output_dir,'pressure_4.csv'); writetable(pressure,result.pressure_csv,'Encoding','UTF-8');

wire=(869:872)'; pairs=[1 4 2 3;2 5 3 4;3 6 4 5;4 7 5 6];
probe=table(wire,(wire-1)*4+1,wire*4,(1:4)',pairs(:,1),pairs(:,2),pairs(:,3),pairs(:,4),telemetry.seven_electrode, ...
    'VariableNames',{'FloatIndex','ByteStart1','ByteEnd1','ChannelBottomToTop', ...
    'IplusLocal','IminusLocal','VplusLocal','VminusLocal','ADC_Vpp'});
result.probe_csv=fullfile(output_dir,'probe_4.csv'); writetable(probe,result.probe_csv,'Encoding','UTF-8');

wire=(1:872)';
% Build four byte tokens explicitly, preserving the transmitted little-endian order.
hex=cell(872,1);
for k=1:872, hex{k}=strtrim(sprintf('%02X ',telemetry.raw_frame((k-1)*4+(1:4)))); end
groups=[repmat({'eit'},832,1);repmat({'temperature'},32,1);repmat({'pressure'},4,1);repmat({'probe'},4,1)];
all_values=table(wire,(wire-1)*4+1,wire*4,groups,hex,telemetry.values, ...
    'VariableNames',{'FloatIndex','ByteStart1','ByteEnd1','Group','WireHex','Float32Value'});
result.all_csv=fullfile(output_dir,'all_872_with_hex.csv'); writetable(all_values,result.all_csv,'Encoding','UTF-8');

result.report=fullfile(output_dir,'3488字节实测报文拆分说明.md');
fid=fopen(result.report,'w','n','UTF-8'); c=onCleanup(@() fclose(fid));
fprintf(fid,'# 3488字节实测报文拆分说明\n\n');
fprintf(fid,'样例文件：`%s`。严格校验得到%d字节、%d个float32，其中%d个有限值。按CAINI7小端packed结构体解析，未补零、截断、取绝对值或修改符号。\n\n',filename,report.byte_count,report.float_count,report.finite_count);
fprintf(fid,'| 字段 | 字节范围 从1开始 | float索引 | 数量 |\n| --- | --- | --- | --- |\n');
fprintf(fid,'| eit[4][16][13] | 1–3328 | 1–832 | 832 |\n| temp[4][8] | 3329–3456 | 833–864 | 32 |\n| pressure[4] | 3457–3472 | 865–868 | 4 |\n| main_voltage[4] | 3473–3488 | 869–872 | 4 |\n\n');
fprintf(fid,'这3488字节本身不含帧头、LENGTH、STATUS或校验。结构长度与小端数值自洽，不等于存在通信校验。\n\n');
fprintf(fid,'## 温度数据\n\n按用户确认，层1最低、层4最高，各层通道1至8从左至右。主控直接复制温度float，工程单位仍以采集板定义为准。\n\n');
fprintf(fid,'| 层 由下至上 | 通道1 | 通道2 | 通道3 | 通道4 | 通道5 | 通道6 | 通道7 | 通道8 |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n');
for layer=1:4, fprintf(fid,'| %d ',layer); fprintf(fid,'| %.9g ',telemetry.temperature_layers(layer,:)); fprintf(fid,'|\n'); end
fprintf(fid,'\n32路温度范围为%.9g至%.9g。\n\n',report.temperature_min,report.temperature_max);
fprintf(fid,'## 压力及探杆\n\n| 通道 | 压力值 按固件打印标注MPa | 探杆ADC峰峰值 Vpp | 探杆激励 | 探杆测量 |\n| --- | --- | --- | --- | --- |\n');
for k=1:4, fprintf(fid,'| %d | %.9g | %.9g | %d–%d | %d–%d |\n',k,telemetry.pressure(k),telemetry.seven_electrode(k),pairs(k,:)); end
fprintf(fid,'\n压力为负值是原始float解码结果，没有取绝对值或清零。固件调试字符串标为MPa，但主控没有压力标定计算；需要核对传感器零点、量程及标定，不能仅凭报文确认物理正确性。\n\n');
fprintf(fid,'探杆由ADC最大码减最小码，再乘5.12/65536得到Vpp；不是电阻率，也不是带符号RMS电压。\n\n');
fprintf(fid,'## 第一层第一次激励的13个值\n\n激励局部电极1→2；固件按固定编号升序，差分为V(i+1)-V(i)。各层16次激励按内存行顺序排列。\n\n');
fprintf(fid,'| 值序号 | 字节位置 | 测量表达式 | 原始差分值 |\n| --- | --- | --- | --- |\n');
for k=1:13, fprintf(fid,'| %d | %d–%d | V%d − V%d | %.9g |\n',k,4*k-3,4*k,map(k,7),map(k,8),telemetry.eit(k)); end
fprintf(fid,'\n首4字节`00 10 D6 3E`按小端float32为%.12g。832个成像值范围为%.12g至%.12g。\n\n',telemetry.eit(1),report.eit_min,report.eit_max);
fprintf(fid,'CSV提供全部872个值的字节位置和原始HEX；MAT中的`eit_by_layer(layer,stim,measurement)`为4×16×13，`temperature_layers(layer,channel)`为4×8，索引均从1开始。\n');
fprintf('Capture decoded: %d bytes, %d floats, %d finite. Exports: %s\n',report.byte_count,report.float_count,report.finite_count,output_dir);
end
