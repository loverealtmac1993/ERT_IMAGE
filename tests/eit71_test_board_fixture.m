function [bytes, expected] = eit71_test_board_fixture(mode)
% Independent field markers make channel/group/offset mistakes visible.
expected.eit = (1:832)';
expected.probe = [0.1; 0.2; 0.3; 0.4];
if strcmp(mode, 'raw904'), n = 16; else, n = 8; end
expected.temp = reshape(20 + (1:n*4)/10, n, 4);
expected.pressure = [10; 20; 30; 40];
if startsWith(mode, 'raw')
    values = [expected.eit; expected.temp(:); expected.pressure; expected.probe];
else
    values = [expected.eit; expected.probe; expected.temp(:); expected.pressure];
end
payload = typecast(single(values), 'uint8'); payload = payload(:)';
[~,~,order] = computer;
if order == 'B', payload = reshape(flipud(reshape(payload,4,[])),1,[]); end
assert(isequal(payload(1:4), uint8([0 0 128 63])));
if startsWith(mode, 'raw'), bytes = payload; return; end
if strcmp(mode, 'uint16le')
    length_bytes = uint8([167 13]); % 3495 = 0x0DA7.
elseif strcmp(mode, 'uint16be')
    length_bytes = uint8([13 167]);
else
    length_bytes = uint8(166); % 3494 low byte = 0xA6.
end
body = [uint8([16 129]), length_bytes, uint8(0), payload];
bytes = [uint8([255 255 165]), body, uint8(mod(sum(double(body)),256)), uint8(38)];
end
