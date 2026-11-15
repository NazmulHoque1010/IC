-- ic_db_test.lua: print a user's group from MySQL (ic_sip) via ODBC
local name = argv[1] or "bob"
local dbh = freeswitch.Dbh("odbc://ic_sip")
if not dbh:connected() then
  stream:write("DB: not connected\n")
  return
end
local grp = nil
dbh:query("SELECT grp FROM sip_users WHERE name = '" .. name .. "'", function(row)
  grp = row.grp
end)
dbh:release()
stream:write(name .. " -> " .. (grp or "not in DB") .. "\n")
