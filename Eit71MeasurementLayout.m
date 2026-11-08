classdef Eit71MeasurementLayout
    % Frame order: layer -> drive 1..16 -> 13 adjacent measurements.
    % firmware_ascending follows process_conductivity_data(), not the unused
    % GenerateEITTable(). Probe row pairs describe Vpp channels, not signed V.
    methods (Static)
        function rows = rows(order)
            if nargin < 1, order = 'firmware_ascending'; end
            % Columns: data index, layer (0=probe), local drive index,
            % local measurement index, I+, I-, V+, V- (global electrodes).
            rows = zeros(836, 8);
            k = 0;
            for layer = 1:4
                base = 16 * (layer - 1);
                for drive = 1:16
                    if strcmp(order, 'firmware_ascending')
                        starts = setdiff(1:16, [drive, mod(drive,16)+1, mod(drive-2,16)+1]);
                    elseif strcmp(order, 'cyclic')
                        starts = mod(drive+(1:13),16)+1;
                    else
                        error('EIT:MeasurementOrder', 'Unknown measurement order.');
                    end
                    for m = 1:13
                        k = k + 1;
                        wrap = @(i) base + mod(i - 1, 16) + 1;
                        % usarthandle.c: diff[i] = data[i+1] - data[i].
                        if strcmp(order, 'firmware_ascending')
                            vp = wrap(starts(m)+1); vn = wrap(starts(m));
                        else
                            vp = wrap(starts(m)); vn = wrap(starts(m)+1);
                        end
                        rows(k,:) = [k layer drive m wrap(drive) wrap(drive+1) vp vn];
                    end
                end
            end
            for p = 1:4
                k = k + 1;
                rows(k,:) = [k 0 p 1 64+p 67+p 65+p 66+p];
            end
        end

    end
end
