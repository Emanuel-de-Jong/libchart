local byte = require("byte")
local bit = require("bit")

local NanoChart = {}

NanoChart.new = function(self)
	local nanoChart = {}

	setmetatable(nanoChart, self)
	self.__index = self

	return nanoChart
end

--[[
	header {
		uint8		version
		uint8[16]	hash
		uint8		inputCount -- need to convert to keys only
	}

	startObject {
		0001 .... .... .... / input = [1, 12], 0 is no object, 14 is delay object, 15 is extended object
		     0... .... .... / 1 - press, 0 - release
		      0.. .... .... / at same time
		       00 0000 0000 / time fraction denominator, 1024 values, 0x000 -> 0 seconds, 0x3ff -> 1023/1024 seconds
	}

	nextObject {
		0001 .... / input = [1, 14]
		     0... / 1 - press, 0 - release
		      0.. / at same time
		       00 / unused bits
	}

	nextObjectExtended { -- always at same time
		1111 .... .... .... / object type, always 1111
		     0... .... .... / 1 - press, 0 - release
		      000 .... .... / unused bits
		          0000 0001 / input = [1, 255]
	}

	nextDelayObject {
		1110 .... / object type, always 1110
		     0000 / delay = [0, 15] seconds
	}
]]

--[[
	version = 1
	hash = 0x00000000000000000000000000000000
	inputs = 4
	notes:	time	type	input
			0		p		1
			0		p		2
			2.25	r		2
			36		r		3

	0000 0001

	0000 0000 0000 0000 0000 0000 0000 0000
	0000 0000 0000 0000 0000 0000 0000 0000
	0000 0000 0000 0000 0000 0000 0000 0000
	0000 0000 0000 0000 0000 0000 0000 0000

	0000 0100

	0001 1000 0000 0000
	0011 1100
	0000 0010
	0011 0001 0000 0000
	0000 1111
	0000 1111
	0000 0010
	0011 0000 0000 0000
]]

local tobits = function(n)
	local t = {}
	while n > 0 do
		local rest = math.fmod(n, 2)
		t[#t + 1] = rest
		n = (n - rest) / 2
	end
	return t
end

NanoChart.encodeNote = function(self, input, type, sameTime, noteTime)
	local prefix = ""
	local postfix = ""
	local noteType

	if not sameTime then
		if input > 12 then
			prefix = self:encodeNote(0, 0, false, noteTime)
			postfix = byte.int8_to_string(input)
			input = 0xff

			noteType = "next"
		else
			noteType = "start"
		end 
	else
		if input > 12 then
			postfix = byte.int8_to_string(input)
			input = 0xff
		end 
		noteType = "next"
	end

	local bits = {}
	local data

	local inputBits = tobits(input)
	for i = 1, #inputBits do
		bits[5 - i] = inputBits[i]
	end

	bits[5] = type
	bits[6] = sameTime and 1 or 0
	
	if noteType == "start" then
		local timeBits = tobits(math.floor(noteTime * 1024))
		for i = 1, #timeBits do
			bits[17 - i] = timeBits[i]
		end

		for i = 1, 16 do
			bits[i] = bits[i] or 0
		end
		data = byte.int16_to_string_be(tonumber(table.concat(bits), 2))
	elseif noteType == "next" then
		for i = 1, 8 do
			bits[i] = bits[i] or 0
		end
		data = byte.int8_to_string(tonumber(table.concat(bits), 2))
	end

	return prefix .. data .. postfix
end

local tohex = function(s)
    return (s:gsub('.', function(c) return ("%02x"):format(c:byte()) end))
end

-- print(tohex(NanoChart:encodeNote(1, 0, false, 0.125)))
-- print(tohex(NanoChart:encodeNote(12, 1, true)))
-- print(tohex(NanoChart:encodeNote(128, 0, false, 1/128)))
-- print(tohex(NanoChart:encodeNote(128, 0, true, 1/128)))
assert(tohex(NanoChart:encodeNote(1, 0, false, 0.125)) == "1080")		-- 0001000010000000
assert(tohex(NanoChart:encodeNote(12, 1, true)) == "cc")				-- 11001100
assert(tohex(NanoChart:encodeNote(128, 0, false, 1/128)) == "0008f080")	-- 0000000000001000 1111000010000000
assert(tohex(NanoChart:encodeNote(128, 0, true, 1/128)) == "f480")		-- 1111010010000000


NanoChart.encode = function(self, hash, inputs, notes)
	table.sort(notes, function(a, b) return a.time < b.time or a.time == b.time and a.input < b.input end)

	local objects = {
		byte.int8_to_string(1),
		hash,
		byte.int8_to_string(inputs)
	}

	local offset = 0
	local noteTime = 0
	local prevNoteTime
	for i = 1, #notes do
		local note = notes[i]

		local noteOffset = math.floor(note.time)
		while offset < noteOffset do
			local delta = math.min(noteOffset - offset, 15)
			offset = offset + delta
			objects[#objects + 1] = byte.int8_to_string(0xe0 + delta)
		end

		noteTime = note.time - math.floor(note.time)

		local prevNote = notes[i - 1]
		prevNoteTime = prevNote and prevNote.time - math.floor(prevNote.time)

		objects[#objects + 1] = self:encodeNote(
			note.input,
			note.type,
			prevNoteTime == noteTime,
			noteTime
		)
	end

	return table.concat(objects)
end

NanoChart.decode = function(self, content)
	local buffer = byte.buffer(content, 0, #content, true)

	local version = byte.read_uint8(buffer)
	local hash = byte.read_string(buffer, 16)
	local inputs = byte.read_uint8(buffer)

	local notes = {}

	local offset = 0
	local noteTime = 0
	while buffer.length > 0 do
		local cbyte = byte.read_uint8(buffer)

		local tempBits = tobits(cbyte)
		local bits = {}
		for i = 1, 8 do
			bits[i] = tempBits[9 - i] or 0
		end

		local input = bit.rshift(bit.band(cbyte, 0xf0), 4)
		if input == 14 then
			offset = offset + bit.band(cbyte, 0xf)
		elseif input == 15 then
			notes[#notes + 1] = {
				time = offset + noteTime / 1024,
				type = bits[5],
				input = byte.read_uint8(buffer)
			}
		else
			local type = bits[5]
			
			if bits[6] == 0 then
				noteTime = bit.lshift(bits[7], 9) + bit.lshift(bits[8], 8) + byte.read_uint8(buffer)
			end

			notes[#notes + 1] = {
				time = offset + noteTime / 1024,
				type = type,
				input = input
			}
		end
	end

	return version, hash, inputs, notes
end

return NanoChart
