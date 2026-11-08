classdef Eit71BoardSession < handle
    % Nonblocking one-request-at-a-time transport. tick() never calls readline.
    properties (SetAccess = private)
        Config
        LastFrame = []
        LastTelemetry = []
        RxCount = 0
        RejectedBytes = 0
        PendingType = []
    end
    properties (Access = private)
        Port
        Buffer = uint8([])
        SentAt = []
        ResponseTimeout = 5
        RawSynchronizing = false
        RawAligned = false
        LastByteAt = []
    end
    methods
        function obj = Eit71BoardSession(port, cfg)
            obj.Port = port;
            obj.Config = cfg;
            if isfield(cfg, 'response_timeout_s'), obj.ResponseTimeout = cfg.response_timeout_s; end
        end

        function request(obj, type)
            if ~isempty(obj.PendingType)
                error('EIT:RequestPending', '上一条指令尚未返回，请等待应答或超时。');
            end
            bytes = Eit71BoardProtocol.command(type, obj.Config);
            if Eit71BoardProtocol.isRaw(obj.Config)
                if Eit71BoardProtocol.sendsTrigger(obj.Config)
                    % A fresh triggered response starts at byte zero. Do NOT
                    % discard the beginning while waiting for an idle boundary.
                    flush(obj.Port, 'input');
                    obj.Buffer = uint8([]);
                    obj.RawSynchronizing = false;
                    obj.RawAligned = true;
                    obj.LastByteAt = tic;
                    write(obj.Port, bytes, 'uint8');
                elseif ~obj.RawAligned
                    obj.Buffer = uint8([]);
                    obj.RawSynchronizing = true;
                    obj.LastByteAt = tic;
                end
            else
                % Ignore incomplete/unread data from an earlier transaction.
                flush(obj.Port, 'input');
                obj.Buffer = uint8([]);
                write(obj.Port, bytes, 'uint8');
            end
            obj.PendingType = double(type) + 128;
            obj.SentAt = tic;
        end

        function frames = tick(obj)
            frames = {};
            if isempty(obj.PendingType), return; end
            n = obj.Port.NumBytesAvailable;
            incoming = uint8([]);
            if n > 0
                incoming = read(obj.Port, n, 'uint8');
            end
            if obj.RawSynchronizing
                % Drop an in-flight tail; arm only after a quiet interval.
                % Raw packets have no way to prove/recover byte alignment.
                if n > 0
                    obj.RejectedBytes = obj.RejectedBytes + n;
                    obj.LastByteAt = tic;
                elseif toc(obj.LastByteAt) >= 0.2
                    obj.RawSynchronizing = false;
                    obj.RawAligned = true;
                end
                incoming = uint8([]);
            elseif Eit71BoardProtocol.isRaw(obj.Config) && ~Eit71BoardProtocol.sendsTrigger(obj.Config)
                if n > 0
                    obj.LastByteAt = tic;
                elseif ~isempty(obj.Buffer) && toc(obj.LastByteAt) >= 0.2
                    % Short idle-separated debug text/partial packets must not
                    % accumulate into a synthetic complete measurement group.
                    obj.RejectedBytes = obj.RejectedBytes + numel(obj.Buffer);
                    obj.Buffer = uint8([]);
                end
            end
            [decoded, obj.Buffer, rejected] = Eit71BoardProtocol.consume(obj.Buffer, incoming, obj.Config);
            obj.RejectedBytes = obj.RejectedBytes + rejected;
            for k = 1:numel(decoded)
                frame = decoded{k};
                raw = Eit71BoardProtocol.isRaw(obj.Config);
                if ~raw && (isempty(obj.PendingType) || frame.type ~= obj.PendingType)
                    continue;
                end
                frame.received_at = datestr(now, 30); % Host receive time.
                obj.LastFrame = frame;
                obj.RxCount = obj.RxCount + 1;
                obj.PendingType = [];
                if frame.type == 129
                    obj.LastTelemetry = [];
                    info = Eit71BoardProtocol.layout(obj.Config);
                    if numel(frame.data) == info.payload_bytes
                        obj.LastTelemetry = Eit71BoardProtocol.telemetry(frame, obj.Config);
                    end
                end
                frames{end+1} = frame; %#ok<AGROW>
            end
            if ~isempty(obj.PendingType) && toc(obj.SentAt) >= obj.ResponseTimeout
                obj.PendingType = [];
                obj.Buffer = uint8([]);
                error('EIT:BoardTimeout', ...
                    '等待数据超时（%g秒）。CAINI7需COND_SEND_RAW=1发送3488字节；核对采集板应答和串口格式。', obj.ResponseTimeout);
            end
        end

        function cancel(obj)
            obj.PendingType = [];
            obj.Buffer = uint8([]);
            obj.RawAligned = false;
            obj.RawSynchronizing = false;
            flush(obj.Port, 'input');
        end

        function delete(obj)
            if ~isempty(obj.Port)
                try
                    delete(obj.Port);
                catch
                end
                obj.Port = [];
            end
        end
    end
end
