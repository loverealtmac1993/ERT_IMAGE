classdef Eit71BoardProtocol
    % Binary protocol from 采泥电导率通讯协议.docx (not the legacy EIT1 log).
    % No inference of EIT voltages, engineering units, or fault-bit names.
    methods (Static)
        function yes = isRaw(cfg)
            yes = ismember(string(cfg.length_mode), ["raw904", "raw872"]);
        end
        function yes = sendsTrigger(cfg)
            yes = strcmp(cfg.length_mode, 'raw872') && ...
                isfield(cfg, 'trigger_raw872') && cfg.trigger_raw872;
        end
        function cfg = defaults()
            cfg.address = uint8(hex2dec('10'));
            cfg.byte_order = 'little-endian'; % STM32H743 + memcpy of float.
            cfg.length_mode = 'raw872'; % Final CAINI_Project_7_RS232_2 AllData_t.
            cfg.trigger_raw872 = true; % UART7: first received byte FF starts a sweep.
            cfg.response_timeout_s = 60; % Firmware already waits >21 s per sweep.
        end

        function info = layout(cfg)
            if nargin < 1, cfg = Eit71BoardProtocol.defaults(); end
            info.boundary_count = 16 * 13 * 4;
            info.probe_count = 4;
            info.temperature_count = 8 * 4;
            info.pressure_count = 4;
            if strcmp(cfg.length_mode, 'raw904'), info.temperature_count = 16 * 4; end
            info.float_count = 832 + 4 + info.temperature_count + 4;
            info.payload_bytes = 4 * info.float_count;
        end

        function [width, overhead] = lengthFormat(cfg)
            switch cfg.length_mode
                case {'uint8', 'low8'}, width = 1;
                case {'uint16le', 'uint16be'}, width = 2;
                otherwise, error('EIT:LengthMode', 'Unsupported length mode.');
            end
            overhead = 5 + width; % ADDRESS TYPE LENGTH STATUS PP TAIL.
        end

        function bytes = command(type, cfg)
            if nargin < 2, cfg = Eit71BoardProtocol.defaults(); end
            validateattributes(type, {'numeric'}, {'scalar', 'integer', '>=', 0, '<=', 1});
            if Eit71BoardProtocol.isRaw(cfg)
                if type == 0
                    error('EIT:RawSelfCheck', '原始结构体没有自检应答；新版固件仅由FF触发一轮采集。');
                end
                bytes = uint8([]);
                if Eit71BoardProtocol.sendsTrigger(cfg), bytes = uint8(255); end
                return;
            end
            validateattributes(cfg.address, {'numeric'}, {'scalar', 'integer', '>=', 0, '<=', 255});
            % LENGTH includes ADDRESS, TYPE, LENGTH, STATUS, PP and tail.
            [width, overhead] = Eit71BoardProtocol.lengthFormat(cfg);
            length_bytes = uint8(overhead);
            if width == 2
                length_bytes = uint8([overhead 0]);
                if strcmp(cfg.length_mode, 'uint16be'), length_bytes = fliplr(length_bytes); end
            end
            body = [uint8([cfg.address, type]), length_bytes, uint8(0)];
            bytes = [uint8([255 255 165]), body, ...
                uint8(mod(sum(double(body)), 256)), uint8(38)];
        end

        function [frames, buffer, rejected] = consume(buffer, incoming, cfg)
            % Incremental decoder: handles split headers, fragmented frames,
            % multiple packets, noise, bad sums, wrong addresses/types/tails.
            if nargin < 3, cfg = Eit71BoardProtocol.defaults(); end
            info = Eit71BoardProtocol.layout(cfg);
            if Eit71BoardProtocol.isRaw(cfg)
                buffer = [uint8(buffer(:)'), uint8(incoming(:)')];
                frames = {}; rejected = 0;
                while numel(buffer) >= info.payload_bytes
                    frame.address = uint8(0);
                    frame.type = uint8(129);
                    frame.length = info.payload_bytes;
                    frame.status = uint8(0); % Placeholder, NOT a firmware status.
                    frame.status_available = false;
                    frame.integrity_verified = false;
                    frame.fault_bits = false(1,8);
                    frame.data = buffer(1:info.payload_bytes);
                    frame.raw = frame.data;
                    frames{end+1} = frame; %#ok<AGROW>
                    buffer(1:info.payload_bytes) = [];
                end
                return;
            end
            [width, overhead] = Eit71BoardProtocol.lengthFormat(cfg);
            buffer = [uint8(buffer(:)'), uint8(incoming(:)')];
            frames = {};
            rejected = 0;
            while numel(buffer) >= 3
                starts = strfind(buffer, uint8([255 255 165]));
                if isempty(starts)
                    % Keep only a possible partial header, not arbitrary noise.
                    if isequal(buffer(end-1:end), uint8([255 255]))
                        keep = 2;
                    elseif buffer(end) == 255
                        keep = 1;
                    else
                        keep = 0;
                    end
                    rejected = rejected + numel(buffer) - keep;
                    buffer = buffer(end-keep+1:end);
                    return;
                end
                rejected = rejected + starts(1) - 1;
                buffer = buffer(starts(1):end);
                if numel(buffer) < 6 + width, return; end
                declared = double(buffer(6));
                if width == 2
                    if strcmp(cfg.length_mode, 'uint16le')
                        declared = double(buffer(6)) + 256 * double(buffer(7));
                    else
                        declared = 256 * double(buffer(6)) + double(buffer(7));
                    end
                end
                if buffer(4) ~= cfg.address || ~ismember(buffer(5), uint8([128 129])) || ...
                        declared < overhead || declared > info.payload_bytes + overhead
                    buffer(1) = [];
                    rejected = rejected + 1;
                    continue;
                end
                count = declared + 3;
                % This is an explicit, opt-in workaround, NOT in the Word spec.
                if strcmp(cfg.length_mode, 'low8') && buffer(5) == 129 && ...
                        declared == mod(info.payload_bytes + overhead, 256)
                    count = info.payload_bytes + overhead + 3;
                end
                if numel(buffer) < count, return; end
                candidate = buffer(1:count);
                valid = candidate(end) == 38 && candidate(end-1) == ...
                    uint8(mod(sum(double(candidate(4:end-2))), 256));
                if ~valid
                    buffer(1) = [];
                    rejected = rejected + 1;
                    continue;
                end
                frame.address = candidate(4);
                frame.type = candidate(5);
                frame.length = declared;
                frame.status = candidate(6 + width);
                frame.status_available = true;
                frame.integrity_verified = true;
                frame.fault_bits = logical(bitget(frame.status, 1:8));
                frame.data = candidate(7 + width:end-2);
                frame.raw = candidate;
                frames{end+1} = frame; %#ok<AGROW>
                buffer(1:count) = [];
            end
        end

        function data = telemetry(frame, cfg)
            if nargin < 2, cfg = Eit71BoardProtocol.defaults(); end
            info = Eit71BoardProtocol.layout(cfg);
            if frame.type ~= 129 || numel(frame.data) ~= info.payload_bytes
                error('EIT:TelemetryLayout', ...
                    'Full telemetry requires TYPE=0x81 and %d DATA bytes; received TYPE=0x%02X, %d bytes. Confirm packet layout.', ...
                    info.payload_bytes, frame.type, numel(frame.data));
            end
            if ~ismember(string(cfg.byte_order), ["little-endian", "big-endian"])
                error('EIT:ByteOrder', 'Unsupported float byte order.');
            end
            values = typecast(uint8(frame.data(:)'), 'single');
            [~, ~, host_order] = computer;
            if (host_order == 'L' && strcmp(cfg.byte_order, 'big-endian')) || ...
                    (host_order == 'B' && strcmp(cfg.byte_order, 'little-endian'))
                values = swapbytes(values);
            end
            data.values = double(values(:));
            data.eit = data.values(1:832);
            data.eit_by_stimulation = reshape(data.eit, 13, 16, 4);
            if Eit71BoardProtocol.isRaw(cfg)
                last_temp = 832 + info.temperature_count;
                data.temperature = data.values(833:last_temp);
                data.pressure = data.values(last_temp+(1:4));
                data.seven_electrode = data.values(last_temp+(5:8));
                data.wire_order = 'eit,temp,pressure,probe';
            else
                data.seven_electrode = data.values(833:836);
                data.temperature = data.values(837:868);
                data.pressure = data.values(869:872);
                data.wire_order = 'eit,probe,temp,pressure';
            end
            data.electrical = [data.eit; data.seven_electrode];
            data.temperature_by_layer = reshape(data.temperature, [], 4);
            data.finite = all(isfinite(data.values));
            data.electrical_finite = all(isfinite(data.electrical));
            data.status = frame.status;
            data.fault_bits = frame.fault_bits;
            data.integrity_verified = frame.integrity_verified;
            data.status_available = frame.status_available;
            data.usable = data.finite && frame.status == 0 && frame.integrity_verified;
            data.electrical_usable = data.electrical_finite && frame.status == 0 && frame.integrity_verified;
            data.raw_frame = frame.raw;
            data.byte_order = cfg.byte_order;
            data.length_mode = cfg.length_mode;
            data.layer_order = 'bottom_to_top';
            data.channel_order = 'left_to_right';
            data.eit_by_layer = permute(data.eit_by_stimulation, [3 2 1]); % C [4][16][13].
            data.temperature_layers = data.temperature_by_layer'; % C [4][8].
            data.pressure_unit = 'unknown';
            if strcmp(cfg.length_mode,'raw872')
                data.pressure_unit = 'MPa (CAINI7 firmware print label; calibration unverified)';
            end
            data.probe_unit = 'Vpp at ADC, as calculated by firmware';
        end
    end
end
