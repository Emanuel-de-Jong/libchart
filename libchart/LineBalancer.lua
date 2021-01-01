local SolutionSeeker = require("libchart.SolutionSeeker")
local enps = require("libchart.enps")

local LineBalancer = {}

LineBalancer.new = function(self)
	local lineBalancer = {}

	setmetatable(lineBalancer, self)
	self.__index = self

	return lineBalancer
end

local intersectSegment = function(tc, tm, bc, bm)
	return (
		math.max((tc - 1) / tm, math.min(tc / tm, bc / bm)) -
		math.min(tc / tm, math.max((tc - 1) / tm, (bc - 1) / bm))
	) * tm
end

LineBalancer.createIntersectTable = function(self)
	local intersectTable = {}
	for i = 1, self.targetMode do
		intersectTable[i] = {}
		for j = 1, self.columnCount do
			intersectTable[i][j] = intersectSegment(i, self.targetMode, j, self.columnCount)
		end
	end
	self.intersectTable = intersectTable
end

local factorial
factorial = function(n)
	return n == 0 and 1 or n * factorial(n - 1)
end

local getCombinationsCount = function(n, k)
	return factorial(n) / (factorial(k) * factorial(n - k))
end

local nextCombination = function(a, n, k)
	local b = {}

	for i = 1, k do
		b[i] = a[i]
	end
	b[k + 1] = n + 1

	local i = k
	while i >= 1 and b[i + 1] - b[i] < 2 do
		i = i - 1
	end

	if i >= 1 then
		b[i] = b[i] + 1
		for j = i + 1, k do
			b[j] = b[j - 1] + 1
		end
		b[k + 1] = nil
		return b
	else
		return
	end
end

LineBalancer.createLineCombinationsTable = function(self)
	local lineCombinationsTable = {}

	for noteCount = 1, self.targetMode do
		local combinations = {}
		lineCombinationsTable[noteCount] = combinations

		local combination = {}
		for j = 1, noteCount do
			combination[j] = j
		end

		while combination do
			combinations[#combinations + 1] = combination
			combination = nextCombination(combination, self.targetMode, noteCount)
		end
	end
	self.lineCombinationsTable = lineCombinationsTable
end

LineBalancer.createLineCombinationsMap = function(self)
	local lineCombinationsTable = self.lineCombinationsTable

	local lineCombinationsMap = {}
	for noteCount = 1, self.targetMode do
		local combinations = {}
		lineCombinationsMap[noteCount] = combinations
		for lineCombinationIndex = 1, #lineCombinationsTable[noteCount] do
			local combination = lineCombinationsTable[noteCount][lineCombinationIndex]
			local map = {}
			for i = 1, #combination do
				map[combination[i]] = 1
			end
			for i = 1, self.targetMode do
				map[i] = map[i] or 0
			end
			combinations[lineCombinationIndex] = map
		end
	end

	self.lineCombinationsMap = lineCombinationsMap
end

LineBalancer.createLineCombinationsCountTable = function(self)
	local lineCombinationsCountTable = {}
	for noteCount = 1, self.targetMode do
		lineCombinationsCountTable[noteCount] = getCombinationsCount(self.targetMode, noteCount)
	end
	self.lineCombinationsCountTable = lineCombinationsCountTable
end

LineBalancer.overDiff = function(self, columnNotes, columns)
	local intersectTable = self.intersectTable
	local overlap = {}

	for i = 1, self.targetMode do
		overlap[i] = 0
		local intersectSubTable = intersectTable[i]
		for j = 1, #columns do
			local rate = intersectSubTable[columns[j]]
			overlap[i] = overlap[i] + rate
		end
	end

	assert(#overlap == #columnNotes)
	local sum = 0
	for i = 1, #overlap do
		sum = sum + math.abs(
			overlap[i] - columnNotes[i]
		)
	end

	return sum
end

LineBalancer.lineExpDensities = function(self, time)
	local densityStacks = self.densityStacks

	local densities = {}
	for i = 1, self.targetMode do
		local stack = densityStacks[i]
		local stackObject = stack[#stack]
		densities[i] = enps.expDensity((time - stackObject[1]) / 1000, stackObject[2])
	end

	return densities
end

local recursionLimitLines = 8
LineBalancer.checkLine = function(self, lineIndex, lineCombinationIndex)
	local lines = self.lines
	local lineCombinationsMap = self.lineCombinationsMap
	local lineCombinationsTable = self.lineCombinationsTable
	local line = lines[lineIndex]

	if not line then
		return 1
	end

	local columns = lineCombinationsTable[line.reducedNoteCount][lineCombinationIndex]
	local columnNotes = lineCombinationsMap[line.reducedNoteCount][lineCombinationIndex]

	if #columns ~= line.reducedNoteCount then
		print(unpack(columns))
		print(line.reducedNoteCount)
		error(123)
		return 0
	end

	local targetMode = self.targetMode

	local prevLine = lines[lineIndex - 1]
	if lineIndex - 1 ~= 0 and prevLine then
		local prevLineCombinationIndex = prevLine.appliedLineCombinationIndex or prevLine.bestLineCombinationIndex
		local columnNotesPrev = lineCombinationsMap[prevLine.reducedNoteCount][prevLineCombinationIndex]

		local jackCount = line.pair1.jackCount
		-- print("checkLine", lineIndex, prevLine.reducedNoteCount, prevLineCombinationIndex, jackCount)
		if jackCount == 0 then
			for i = 1, targetMode do
				if columnNotes[i] == columnNotesPrev[i] and columnNotes[i] == 1 then
					return 0
				end
			end
		else
			local hasJack = false
			local actualJackCount = 0
			for i = 1, targetMode do
				if columnNotes[i] == columnNotesPrev[i] and columnNotes[i] == 1 then
					hasJack = true
					actualJackCount = actualJackCount + 1
				end
			end
			if not hasJack then
				return 0
			end

			if actualJackCount > jackCount then
				return 0
			end
		end
	end

	local densitySum = 0

	local time = line.time
	local lineExpDensities = self:lineExpDensities(time)
	local densityStacks = self.densityStacks
	for i = 1, targetMode do
		if columnNotes[i] == 1 then
			local stack = densityStacks[i]
			stack[#stack + 1] = {
				time,
				lineExpDensities[i]
			}
			densitySum = densitySum + lineExpDensities[i]
		end
	end
	-- densitySum = 0

	local overDiff = self:overDiff(columnNotes, line.combination)

	local rate = 1
	if overDiff > 0 then
		rate = rate * (1 / overDiff)
	end
	if densitySum > 0 then
		rate = rate * (1 / densitySum)
	end

	if recursionLimitLines ~= 0 and lines[lineIndex + 1] then
		recursionLimitLines = recursionLimitLines - 1
		line.appliedLineCombinationIndex = lineCombinationIndex

		local maxNextRate = 0
		for i = 1, self.lineCombinationsCountTable[lines[lineIndex + 1].reducedNoteCount] do
			maxNextRate = math.max(maxNextRate, self:checkLine(lineIndex + 1, i))
		end
		rate = rate * maxNextRate

		recursionLimitLines = recursionLimitLines + 1
		line.appliedLineCombinationIndex = nil
	end

	for i = 1, targetMode do
		if columnNotes[i] == 1 then
			local stack = densityStacks[i]
			stack[#stack] = nil
		end
	end

	return rate
end

LineBalancer.balanceLines = function(self)
	local densityStacks = {}
	self.densityStacks = densityStacks

	for i = 1, self.targetMode do
		densityStacks[i] = {{-math.huge, 0}}
	end

	local lines = self.lines

	for lineIndex, line in ipairs(lines) do
		local rates = {}
		for lineCombinationIndex = 1, self.lineCombinationsCountTable[line.reducedNoteCount] do
			rates[#rates + 1] = {lineCombinationIndex, self:checkLine(lineIndex, lineCombinationIndex)}
		end

		local bestLineCombinationIndex
		local bestRate = 0
		for k = 1, #rates do
			local lineCombinationIndex = rates[k][1]
			local rate = rates[k][2]
			if rate > bestRate then
				bestLineCombinationIndex = lineCombinationIndex
				bestRate = rate
			end
		end

		line.bestLineCombinationIndex = bestLineCombinationIndex
		line.bestLineCombination = self.lineCombinationsTable[line.reducedNoteCount][bestLineCombinationIndex]

		local time = assert(line.time)
		local columnNotes = self.lineCombinationsMap[line.reducedNoteCount][bestLineCombinationIndex]
		-- print("balanceLines", lineIndex, line.reducedNoteCount, bestLineCombinationIndex, #rates)
		-- print(time)
		-- print(line.pair1.jackCount, line.pair2.jackCount)
		-- print(line.pair1.index, line.pair2.index)

		local lineExpDensities = self:lineExpDensities(time)
		for i = 1, self.targetMode do
			if columnNotes[i] == 1 then
				local stack = densityStacks[i]
				stack[#stack + 1] = {
					time,
					lineExpDensities[i]
				}
			end
		end
	end
end

LineBalancer.process = function(self, lines, columnCount, targetMode)
	self.lines = lines
	self.columnCount = columnCount
	self.targetMode = targetMode
	-- local Profiler = require("aqua.util.Profiler")
	-- local profiler = Profiler:new()
	-- profiler:start()

	self:createIntersectTable()
	self:createLineCombinationsCountTable()
	self:createLineCombinationsTable()
	self:createLineCombinationsMap()

	--[[input
		reducedNoteCounts,
		lines
	]]

	print("balanceLines")
	self:balanceLines()

	--[[
		lineCombinations
	]]

	-- profiler:stop()
end

return LineBalancer