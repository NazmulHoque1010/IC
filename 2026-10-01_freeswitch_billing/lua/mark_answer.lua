local a_uuid  = argv[1]
local balance = tonumber(argv[2]) or 0
local api = freeswitch.API()

api:executeString("uuid_setvar " .. a_uuid .. " bill_start " .. os.time())

if balance > 0 then
  api:executeString("sched_hangup +" .. balance .. " " .. a_uuid .. " ALLOTTED_TIMEOUT")
end

freeswitch.consoleLog("notice", "mark_answer uuid=" .. a_uuid .. " balance=" .. balance .. " bill_start=" .. os.time() .. "\n")
