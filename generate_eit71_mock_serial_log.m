% Generate mock RS-232 ASCII data for the 71-electrode seafloor-core EIT app.
%
% Scene:
%   - Cuboid: 0.16 x 0.16 x 0.60 m
%   - z = 0..400 mm: South China Sea deep-water sediment
%   - z = 400..600 mm: seawater
%   - sediment contains low-conductivity gas-hydrate inclusions
%
% The script uses saved simulation vectors vh.meas and vi.meas from
% compare_seafloor_core_hydrate_recon_algorithms.m, then converts each
% stimulation's differential measurements into one compatible 71-channel
% single-ended voltage vector for upper-computer protocol testing.

clear; clc;

out_dir = fileparts(mfilename('fullpath'));
result_mat = fullfile(out_dir, 'seafloor_core_hydrate_internal_probe_eit_result.mat');
mock_file = fullfile(out_dir, 'eit71_mock_serial_log.txt');

cfg_mock.num_electrodes = 71;
cfg_mock.boundary_electrodes = 64;
cfg_mock.probe_electrodes = 65:71;
cfg_mock.current_rms_A = 10e-3;
cfg_mock.frequency_Hz = 1000;
cfg_mock.reference_cycles = 3;
cfg_mock.target_cycles = 20;
cfg_mock.voltage_noise_rms_V = 1e-6;
cfg_mock.random_seed = 20260611;
cfg_mock.include_probe_adjacent_drives = true;
cfg_mock.include_probe_to_boundary_drives = true;
cfg_mock.include_probe_voltage_measurements = true;

if ~exist(result_mat, 'file')
    error('Simulation result not found: %s', result_mat);
end

S = load(result_mat, 'cfg', 'fmdl', 'vh', 'vi', 'probe');
sim_cfg = S.cfg;
fmdl = S.fmdl;
vh = S.vh.meas(:);
vi = S.vi.meas(:);

elec_pos = boundary_electrode_positions_from_cfg(sim_cfg);
if isfield(S, 'probe') && isfield(S.probe, 'electrode_model_m')
    probe_pos = S.probe.electrode_model_m;
    cfg_mock.probe_electrodes = S.probe.electrode_index(:)';
else
    probe_pos = user_mm_to_model_m(sim_cfg.probe_electrode_user_mm, sim_cfg.size_m);
end

boundary_pairs = boundary_adjacent_pairs(16, 4);
probe_pairs = [cfg_mock.probe_electrodes(1:end-1)', cfg_mock.probe_electrodes(2:end)'];
mixed_pairs = nearest_probe_boundary_pairs(elec_pos(1:cfg_mock.boundary_electrodes,:), ...
    probe_pos, cfg_mock.probe_electrodes(:));

drive_pairs = boundary_pairs;
if cfg_mock.include_probe_adjacent_drives
    drive_pairs = [drive_pairs; probe_pairs];
end
if cfg_mock.include_probe_to_boundary_drives
    drive_pairs = [drive_pairs; mixed_pairs];
end

meas_pairs = boundary_pairs;
if cfg_mock.include_probe_voltage_measurements
    meas_pairs = unique_pair_rows([meas_pairs; probe_pairs; mixed_pairs]);
end
stim_table = build_stim_table(drive_pairs, meas_pairs);

expected_meas = sum([stim_table.n_meas]);
if numel(vh) ~= expected_meas || numel(vi) ~= expected_meas
    error('Measurement vector length mismatch. Expected %d, got vh=%d, vi=%d.', ...
          expected_meas, numel(vh), numel(vi));
end

fprintf('Generating mock serial log for seafloor-core EIT test.\n');
fprintf('  Result MAT       : %s\n', result_mat);
fprintf('  Output log       : %s\n', mock_file);
fprintf('  Stimulations     : %d\n', numel(stim_table));
fprintf('  Measurements/cyc : %d\n', expected_meas);
fprintf('  Reference cycles : %d\n', cfg_mock.reference_cycles);
fprintf('  Target cycles    : %d\n', cfg_mock.target_cycles);
fprintf('  Voltage noise RMS: %.3g V per single-ended channel\n', cfg_mock.voltage_noise_rms_V);

rng(cfg_mock.random_seed);
fid = fopen(mock_file, 'w');
if fid < 0
    error('Unable to write mock file: %s', mock_file);
end
cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

fprintf(fid, '# Mock 71-electrode EIT serial log for MATLAB upper-computer testing\n');
fprintf(fid, '# Scene: 0-400 mm South China Sea deep-water sediment, 400-600 mm seawater, gas hydrate in sediment\n');
fprintf(fid, '# Format: $EIT1,frame_id,stim_id,i_plus,i_minus,irms_A,freq_Hz,V1,...,V71*XX\n');
fprintf(fid, '# First %d full cycles are background/reference vh; following cycles are hydrate-state vi\n', ...
        cfg_mock.reference_cycles);

frame_id = 0;
for cycle = 1:(cfg_mock.reference_cycles + cfg_mock.target_cycles)
    if cycle <= cfg_mock.reference_cycles
        meas_vector = vh;
        state_name = 'reference';
    else
        meas_vector = vi;
        state_name = 'hydrate';
    end

    for stim_id = 1:numel(stim_table)
        frame_id = frame_id + 1;
        stim = stim_table(stim_id);
        y = meas_vector(stim.row_start:stim.row_end);
        v_elec = differential_to_single_ended(y, stim.meas_pairs, cfg_mock.num_electrodes);
        v_elec = v_elec + cfg_mock.voltage_noise_rms_V * randn(size(v_elec));

        line = make_ascii_frame(frame_id, stim_id, stim.drive_pair, ...
            cfg_mock.current_rms_A, cfg_mock.frequency_Hz, v_elec);
        fprintf(fid, '%s\n', line);
    end
    fprintf('  Wrote cycle %02d/%02d (%s)\n', cycle, ...
            cfg_mock.reference_cycles + cfg_mock.target_cycles, state_name);
end

fprintf('\nDone. Mock serial log: %s\n', mock_file);
fprintf('To test without hardware, set cfg.input_mode = "file" in eit71_serial_noser_upper_pc.m.\n');

function line = make_ascii_frame(frame_id, stim_id, drive_pair, irms_A, freq_Hz, v_elec)
    fields = ["EIT1", string(frame_id), string(stim_id), ...
              string(drive_pair(1)), string(drive_pair(2)), ...
              compose('%.9g', irms_A), compose('%.9g', freq_Hz), ...
              compose('%.9g', v_elec(:)')];
    payload = char(strjoin(fields, ','));
    checksum = dec2hex(xor_checksum(payload), 2);
    line = ['$' payload '*' checksum];
end

function v_elec = differential_to_single_ended(y, meas_pairs, n_elec)
    active = unique(meas_pairs(:));
    map = zeros(n_elec, 1);
    map(active) = 1:numel(active);

    n_meas = size(meas_pairs, 1);
    A = sparse([(1:n_meas)'; (1:n_meas)'], ...
               [map(meas_pairs(:,1)); map(meas_pairs(:,2))], ...
               [ones(n_meas, 1); -ones(n_meas, 1)], ...
               n_meas, numel(active));
    A = [A; ones(1, numel(active))];
    b = [y(:); 0];

    v_active = A \ b;
    v_elec = zeros(n_elec, 1);
    v_elec(active) = v_active;
end

function c = xor_checksum(payload)
    bytes = uint8(payload);
    c = uint8(0);
    for i = 1:numel(bytes)
        c = bitxor(c, bytes(i));
    end
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

function centers_m = user_mm_to_model_m(centers_mm, size_m)
    centers_m = centers_mm / 1000;
    centers_m(:,1) = centers_m(:,1) - size_m(1)/2;
    centers_m(:,2) = centers_m(:,2) - size_m(2)/2;
end

function pairs = unique_pair_rows(pairs)
    pairs = sort(pairs, 2);
    [~, ia] = unique(pairs, 'rows');
    pairs = pairs(sort(ia), :);
end
