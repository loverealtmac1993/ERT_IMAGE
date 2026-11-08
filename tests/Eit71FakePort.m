classdef Eit71FakePort < handle
    % Minimal in-memory serial port for transport regression tests only.
    properties
        Input = uint8([])
        Writes = {}
    end
    properties (Dependent)
        NumBytesAvailable
    end
    methods
        function n = get.NumBytesAvailable(obj)
            n = numel(obj.Input);
        end
        function flush(obj, varargin) %#ok<INUSD>
            obj.Input = uint8([]);
        end
        function write(obj, bytes, datatype)
            assert(strcmp(datatype, 'uint8'));
            obj.Writes{end+1} = uint8(bytes);
        end
        function bytes = read(obj, n, datatype)
            assert(strcmp(datatype, 'uint8') && n <= numel(obj.Input));
            bytes = obj.Input(1:n);
            obj.Input(1:n) = [];
        end
    end
end
