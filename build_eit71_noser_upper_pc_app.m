% Build the 71-electrode EIT NOSER upper-computer GUI as a Windows executable.
%
% Requirements:
%   - MATLAB Compiler installed and licensed
%   - Existing simulation result MAT:
%       seafloor_core_hydrate_internal_probe_eit_result.mat
%
% Output:
%   outputs\build_eit71_noser_app\eit71_noser_upper_pc_app.exe

clear; clc;

out_dir = fileparts(mfilename('fullpath'));
build_dir = fullfile(out_dir, 'build_eit71_noser_app');
main_file = fullfile(out_dir, 'eit71_noser_upper_pc_app.m');
protocol_files = {fullfile(out_dir, 'Eit71BoardProtocol.m'), ...
    fullfile(out_dir, 'Eit71BoardSession.m'), ...
    fullfile(out_dir, 'Eit71MeasurementLayout.m'), ...
    fullfile(out_dir, 'read_eit71_board_capture.m')};

extra_files = {
    fullfile(out_dir, 'seafloor_core_hydrate_internal_probe_eit_result.mat')
    fullfile(out_dir, 'eit71_mock_serial_log.txt')
    fullfile(out_dir, 'eit71_mock_hydrate_progress_log.txt')
    fullfile(out_dir, 'eit71_mock_hydrate_progress_metadata.csv')
    fullfile(out_dir, '71电极EIT_NOSER上位机使用说明.md')
    fullfile(out_dir, 'CAINI7最终协议核验.md')
    };

if ~exist(main_file, 'file')
    error('Main app file not found: %s', main_file);
end
for i = 1:numel(protocol_files)
    if ~isfile(protocol_files{i})
        error('Required binary protocol module not found: %s', protocol_files{i});
    end
end

missing = extra_files(~cellfun(@(p) exist(p, 'file') == 2, extra_files));
if ~isempty(missing)
    fprintf('Some optional/runtime data files are missing:\n');
    for i = 1:numel(missing)
        fprintf('  %s\n', missing{i});
    end
    fprintf('Generate mock logs first if you want them bundled.\n');
end

if exist(build_dir, 'dir')
    warning('Build directory already exists and will be reused: %s', build_dir);
else
    mkdir(build_dir);
end

% -I makes the class dependencies discoverable even when invoked elsewhere.
cmd = {'mcc', '-m', main_file, '-I', out_dir, '-d', build_dir, '-o', 'eit71_noser_upper_pc_app'};
for i = 1:numel(extra_files)
    if exist(extra_files{i}, 'file')
        cmd = [cmd, {'-a', extra_files{i}}]; %#ok<AGROW>
    end
end

fprintf('Running MATLAB Compiler command:\n');
fprintf('  %s\n', strjoin(cmd, ' '));

if isempty(ver('compiler'))
    error('EIT:CompilerNotInstalled', ...
        'MATLAB Compiler is not installed. A license entry alone is insufficient. Install the matching Compiler toolbox, then run this script again; the app source can run directly in MATLAB.');
end
if license('test', 'Compiler') ~= 1
    error('EIT:CompilerNotLicensed', ...
        'MATLAB Compiler license is not available. Activate MATLAB Compiler to build an EXE.');
end

mcc(cmd{2:end});

fprintf('\nBuild finished.\n');
fprintf('Executable directory: %s\n', build_dir);
fprintf('Run: %s\n', fullfile(build_dir, 'eit71_noser_upper_pc_app.exe'));
