-- call.lua
-- DO NOT call session:answer() — let bridge handle it

local caller_number      = session:getVariable("caller_id_number")
local destination_number = session:getVariable("destination_number")

freeswitch.consoleLog("INFO", string.format(
    "[call.lua] Caller: %s -> Destination: %s\n",
    tostring(caller_number),
    tostring(destination_number)
))

if not destination_number or destination_number == "" then
    freeswitch.consoleLog("ERR", "[call.lua] No destination number. Hanging up.\n")
    session:hangup("NO_ROUTE_DESTINATION")
    return
end

-- Set codec preferences BEFORE bridge (not after answer)
session:execute("set", "absolute_codec_string=OPUS")
session:execute("set", "opus_bitrate=8000")
session:execute("set", "opus_maxaveragebitrate=8000")
session:execute("set", "opus_maxplaybackrate=8000")
session:execute("set", "opus_use_cbr=1")
session:execute("set", "opus_use_dtx=1")

-- Bridge will: ring B-leg → B answers → THEN answer A-leg automatically
session:execute("bridge", "user/" .. destination_number)

freeswitch.consoleLog("INFO", string.format(
    "[call.lua] Bridge completed for destination: %s\n",
    destination_number
))
