local ext    = session:getVariable("caller_id_number")
local dialed = session:getVariable("dialed_extension")
local domain = session:getVariable("domain_name")
local a_uuid = session:getVariable("uuid")

local balance = session:getVariable("caller_balance") or "0"

-- Route: local user if registered here, otherwise send to the peer FreeSWITCH
local PEER_IP = "192.168.99.112"
local api = freeswitch.API()
local contact = api:executeString("sofia_contact internal/" .. dialed .. "@" .. domain) or ""
local target
if contact:find("error/") then
  target = "sofia/internal/" .. dialed .. "@" .. PEER_IP
else
  target = "user/" .. dialed .. "@" .. domain
end
freeswitch.consoleLog("notice", "billed_bridge route " .. dialed .. " -> " .. target .. "\n")

session:execute("bridge", "{api_on_answer='lua mark_answer.lua " .. a_uuid .. " " .. balance .. "'}" .. target)
local t1 = os.time()

local disp  = session:getVariable("originate_disposition")
local start = tonumber(session:getVariable("bill_start")) or 0
local secs  = 0
if start > 0 then secs = t1 - start end

freeswitch.consoleLog("notice", "billed_bridge ext=" .. tostring(ext) .. " disp=" .. tostring(disp) .. " bill_start=" .. start .. " secs=" .. secs .. "\n")

if disp == "SUCCESS" then
  if secs > 0 then
    freeswitch.API():executeString("curl http://127.0.0.1:8080/?action=deduct&ext=" .. ext .. "&seconds=" .. secs)
  end
  session:hangup("NORMAL_CLEARING")
end
