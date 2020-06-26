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
		0001 .... .... .... / input = [1, 12], 0 is no object (see usage below), 14 is delay object, 15 is extended object
		     0... .... .... / 1 - press, 0 - release
		      0.. .... .... / 1 - at same time, 0 - at new time
		       00 0000 0000 / time fraction numerator, 1024 values, 0x000 -> 0 seconds, 0x3ff -> 1023/1024 seconds
	}

	nextObject {
		0001 .... / input = [1, 14]
		     0... / 1 - press, 0 - release
		      1.. / 1 - at same time, 0 - at new time
		       00 / unused bits
	}

	nextObjectExtended { -- always at same time, use 0-input object to define time
		1111 .... .... .... / object type, always 1111
		     0... .... .... / 1 - press, 0 - release
		      000 .... .... / unused bits
		          0000 0001 / input = [1, 255]
	}

	nextDelayObject {
		1110 .... / object type 14 == 1110 is delay object
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
			36		p		255
			36.5	r		255

	0000 0001

	0000 0000 0000 0000 0000 0000 0000 0000
	0000 0000 0000 0000 0000 0000 0000 0000
	0000 0000 0000 0000 0000 0000 0000 0000
	0000 0000 0000 0000 0000 0000 0000 0000

	0000 0100

	0001 1100 0000 0000 -- 1st note
	0010 1100           -- 2nd note
	1110 0010			-- 2 seconds delay
	0010 0001 0000 0000 -- 3rd note
	1110 1111			-- 15 seconds delay
	1110 1111			-- 15 seconds delay
	1110 0010			-- 2 seconds delay
	0011 0000 0000 0000 -- 4th note
	1111 1000 1111 1111 -- 5th note
	0000 0010 0000 0000 -- 0-input note (+0.5)
	1111 0000 1111 1111 -- 6th note
]]

local tobits = function(n) -- order is reversed
	local t = {}
	while n > 0 do
		local rest = n % 2
		t[#t + 1] = rest
		n = (n - rest) / 2
	end
	return t
end

assert(table.concat(tobits(1)) == "1")
assert(table.concat(tobits(2)) == "01")
assert(table.concat(tobits(1023)) == "1111111111")
assert(table.concat(tobits(1024)) == "00000000001")

NanoChart.encodeNote = function(self, input, type, sameTime, noteTime)
	local prefix = ""
	local postfix = ""
	local noteType

	local bits = {}

	bits[5] = type
	bits[6] = sameTime and 1 or 0

	if input > 12 then
		postfix = byte.int8_to_string(input)
		input = 0xff

		if not sameTime then
			prefix = self:encodeNote(0, 0, false, noteTime)
			sameTime = true
		end
	end

	local inputBits = tobits(input)
	for i = 1, 4 do
		bits[i] = inputBits[5 - i] or 0
	end
	
	local data
	if not sameTime then
		local timeBits = tobits(math.floor(noteTime * 1024))
		for i = 7, 16 do
			bits[i] = timeBits[17 - i] or 0
		end

		data = byte.int16_to_string_be(tonumber(table.concat(bits), 2))
	else
		bits[7] = 0
		bits[8] = 0
		data = byte.int8_to_string(tonumber(table.concat(bits), 2))
	end

	return prefix .. data .. postfix
end

local hexReplace = function(c) return ("%02x"):format(c:byte()) end
local tohex = function(s)
    return (s:gsub('.', hexReplace))
end

-- print(tohex(NanoChart:encodeNote(1, 0, false, 0.125)))
-- print(tohex(NanoChart:encodeNote(12, 1, true)))
-- print(tohex(NanoChart:encodeNote(128, 0, false, 1/128)))
-- print(tohex(NanoChart:encodeNote(128, 0, true, 1/128)))
assert(tohex(NanoChart:encodeNote(1, 0, false, 0.125)) == "1080")		-- 0001000010000000
assert(tohex(NanoChart:encodeNote(12, 1, true)) == "cc")				-- 11001100
assert(tohex(NanoChart:encodeNote(128, 0, false, 1/128)) == "0008f080")	-- 0000000000001000 1111000010000000
assert(tohex(NanoChart:encodeNote(128, 0, true, 1/128)) == "f480")		-- 1111010010000000

local sortNotes = function(a, b) return a.time < b.time or a.time == b.time and a.input < b.input end
NanoChart.encode = function(self, hash, inputs, notes)
	table.sort(notes, sortNotes)

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

			if input ~= 0 then
				notes[#notes + 1] = {
					time = offset + noteTime / 1024,
					type = type,
					input = input
				}
			end
		end
	end

	return version, hash, inputs, notes
end

NanoChart.getNotes = function(self, noteChart)
	local inputs = {}

	for inputType, inputCount in pairs(noteChart.inputMode.data) do
		inputs[#inputs + 1] = {inputType, inputCount}
	end
	
	table.sort(inputs, function(a, b)
		if a[2] ~= b[2] then
			return a[2] > b[2]
		else
			return a[1] < b[1]
		end
	end)

	local keymap = {}
	local c = 1
	for index, input in ipairs(inputs) do
		for i = 1, input[2] do
			keymap[input[1] .. i] = c
			c = c + 1
		end
	end
	
	local notes = {}

	for layerIndex in noteChart:getLayerDataIndexIterator() do
		local layerData = noteChart:requireLayerData(layerIndex)
		
		for noteDataIndex = 1, layerData:getNoteDataCount() do
			local noteData = layerData:getNoteData(noteDataIndex)
			
			if noteData.noteType == "ShortNote" or noteData.noteType == "LongNoteStart" then
				notes[#notes + 1] = {
					time = noteData.timePoint.absoluteTime,
					type = 1,
					input = keymap[noteData.inputType .. noteData.inputIndex]
				}
			elseif noteData.noteType == "LongNoteEnd" then
				notes[#notes + 1] = {
					time = noteData.timePoint.absoluteTime,
					type = 0,
					input = keymap[noteData.inputType .. noteData.inputIndex]
				}
			end
		end
	end

	return notes, #inputs
end

return NanoChart
