function files = build_eit71_noser_upper_pc_app(runtime_delivery, model_file)
% Build a Windows GUI executable and a MATLAB Runtime aware installer.
%   build_eit71_noser_upper_pc_app                 % web Runtime installer
%   build_eit71_noser_upper_pc_app('installer')    % offline Runtime installer
%   build_eit71_noser_upper_pc_app('web', model_file)
% Serial reception works without the optional legacy simulation model.

if nargin < 1 || isempty(runtime_delivery), runtime_delivery = 'web'; end
runtime_delivery = validatestring(runtime_delivery, {'web','installer'});
out_dir = fileparts(mfilename('fullpath'));
if nargin < 2 || isempty(model_file)
    model_file = fullfile(out_dir, 'seafloor_core_hydrate_internal_probe_eit_result.mat');
end
if ~ispc
    error('EIT:WindowsBuildRequired','Build the Windows EXE on Windows.');
end
if isempty(ver('compiler')) || isempty(which('compiler.build.standaloneWindowsApplication'))
    error('EIT:CompilerNotInstalled', ...
        'Install MATLAB Compiler matching this MATLAB release and update first.');
end
if license('test','Compiler') ~= 1
    error('EIT:CompilerNotLicensed','MATLAB Compiler license is not available.');
end

main_file = fullfile(out_dir,'eit71_noser_upper_pc_app.m');
required = {'eit71_noser_upper_pc_app.m','Eit71BoardProtocol.m', ...
    'Eit71BoardSession.m','Eit71MeasurementLayout.m','read_eit71_board_capture.m'};
for i = 1:numel(required)
    assert(isfile(fullfile(out_dir,required{i})), 'EIT:MissingBuildInput', ...
        'Required build input not found: %s',required{i});
end
extra = {model_file, ...
    fullfile(out_dir,'eit71_mock_serial_log.txt'), ...
    fullfile(out_dir,'eit71_mock_hydrate_progress_log.txt'), ...
    fullfile(out_dir,'eit71_mock_hydrate_progress_metadata.csv'), ...
    fullfile(out_dir,'71电极EIT_NOSER上位机使用说明.md'), ...
    fullfile(out_dir,'CAINI7最终协议核验.md')};
has_model = isfile(model_file);
if ~has_model
    warning('EIT:LegacyModelNotBundled', ...
        'Legacy simulation model not found. Serial acquisition and capture import remain available.');
end
extra = extra(cellfun(@isfile,extra));
old_path = path;
restore = onCleanup(@() path(old_path));
addpath(out_dir);

build_root = fullfile(out_dir,'build_eit71_noser_app');
exe_dir = fullfile(build_root,'application');
installer_dir = fullfile(build_root,['installer_' runtime_delivery]);
if ~isfolder(build_root), mkdir(build_root); end
fprintf('Building Windows GUI with %s (%s). Legacy model bundled: %d\n', ...
    version,version('-release'),has_model);
results = compiler.build.standaloneWindowsApplication(main_file, ...
    'ExecutableName','eit71_noser_upper_pc_app', ...
    'ExecutableVersion','1.1.0.0', ...
    'AdditionalFiles',extra, 'OutputDir',exe_dir, 'Verbose','on');
save(fullfile(build_root,'build_results.mat'),'results');

sample = fullfile(out_dir,'tests','fixtures','caini7_sample_3488.hex');
package_extra = {};
if isfile(sample), package_extra{end+1} = sample; end
instructions = fullfile(out_dir,'docs','Windows_EXE使用说明.md');
if isfile(instructions), package_extra{end+1} = instructions; end
for name = {'71电极EIT_NOSER上位机使用说明.md','CAINI7最终协议核验.md'}
    document = fullfile(out_dir,name{1});
    if isfile(document), package_extra{end+1} = document; end
end
if strcmp(runtime_delivery,'installer')
    compiler.runtime.download;
end
compiler.package.installer(results, ...
    'ApplicationName','CAINI7 EIT Upper Computer', ...
    'InstallerName','CAINI7_EIT_Setup', ...
    'Version','1.1.0', ...
    'Summary','CAINI7 3488-byte serial telemetry, temperature, pressure and EIT simulation', ...
    'Shortcut',fullfile(exe_dir,'eit71_noser_upper_pc_app.exe'), ...
    'InstallationNotes',['Requires free MATLAB Runtime ' version('-release') ...
        '. MATLAB installation is not required.'], ...
    'RuntimeDelivery',runtime_delivery, ...
    'AdditionalFiles',package_extra, 'OutputDir',installer_dir);

files = struct('executable',fullfile(exe_dir,'eit71_noser_upper_pc_app.exe'), ...
    'installer_dir',installer_dir,'runtime_delivery',runtime_delivery, ...
    'legacy_model_bundled',has_model,'matlab_version',version, ...
    'matlab_release',version('-release'));
assert(isfile(files.executable),'EIT:ExecutableMissing','The compiler produced no EXE.');
fid = fopen(fullfile(build_root,'build_manifest.json'),'w','n','UTF-8');
assert(fid >= 0,'EIT:BuildManifest','Cannot create build manifest.');
close_manifest = onCleanup(@() fclose(fid));
fprintf(fid,'%s\n',jsonencode(files,'PrettyPrint',true));
fprintf('\nEXE: %s\nInstaller folder: %s\n',files.executable,installer_dir);
fprintf('Target computers need the matching free MATLAB Runtime, not MATLAB.\n');
end
