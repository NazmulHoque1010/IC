-- ic_directory.lua: FreeSWITCH directory users on demand for the IC system.
-- Name rule: lowercase, starts with a letter, then letters/digits/._-, 2-32 chars.
-- Password is always 1234. No user files are needed and none are written.
--   * SIP phones (MizuDroid), profile "phones": the name must be in the MySQL
--     table ic_sip.sip_users; its group (A/B/C) decides the codec.
--   * App users (Janus), profile "internal": any valid name NOT in the table.
--   * Lookups without a profile (dialplan, user_data): table users get their
--     group and codec, any other valid name is an app user.
local DOMAIN   = "ic.local"
local PASSWORD = "1234"
local CODEC    = { A = "PCMU", B = "GSM", C = "PCMA" }
local APP_CODEC = "OPUS"

local function not_found()
  XML_STRING = [[<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="result"><result status="not found"/></section>
</document>]]
end

-- Group (A/B/C) of a name from MySQL, or nil if the name is not in the table.
local function db_group(name)
  local dbh = freeswitch.Dbh("odbc://ic_sip")
  if not dbh:connected() then
    freeswitch.consoleLog("err", "ic_directory: cannot connect to database ic_sip\n")
    return nil
  end
  local grp = nil
  -- Safe to build by hand: the name already passed the name rule (no quotes).
  dbh:query("SELECT grp FROM sip_users WHERE name = '" .. name .. "'", function(row)
    grp = row.grp
  end)
  dbh:release()
  return grp
end

local user    = params:getHeader("user")
local domain  = params:getHeader("domain") or XML_REQUEST["key_value"]
local profile = params:getHeader("sip_profile")
local action  = params:getHeader("action")
local method  = params:getHeader("sip_auth_method")

if XML_REQUEST["section"] ~= "directory" or not user or domain ~= DOMAIN
   or #user > 32 or not user:match("^[a-z][a-z0-9._%-]+$") then
  not_found()
  return
end

local grp = db_group(user)

if profile == "phones" and not grp then
  freeswitch.consoleLog("warning", string.format(
    "ic_directory: refused %s on phones, not in database\n", user))
  not_found()
  return
end

if profile == "internal" and grp then
  freeswitch.consoleLog("warning", string.format(
    "ic_directory: refused %s on internal, name belongs to a SIP phone (group %s)\n", user, grp))
  not_found()
  return
end

-- Every user gets ic_codec: app users OPUS, SIP phones the codec of their group.
local group_vars = string.format([[
            <variable name="ic_codec" value="%s"/>]], APP_CODEC)
if grp then
  group_vars = string.format([[
            <variable name="ic_group" value="%s"/>
            <variable name="ic_codec" value="%s"/>]], grp, CODEC[grp] or "")
end

freeswitch.consoleLog("info", string.format(
  "ic_directory: user=%s profile=%s action=%s method=%s group=%s\n",
  user, tostring(profile), tostring(action), tostring(method), tostring(grp)))

XML_STRING = string.format([[<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<document type="freeswitch/xml">
  <section name="directory">
    <domain name="%s">
      <params>
        <param name="dial-string" value="{^^:sip_invite_domain=${dialed_domain}:presence_id=${dialed_user}@${dialed_domain}}${sofia_contact(*/${dialed_user}@${dialed_domain})}"/>
      </params>
      <groups><group name="default"><users>
        <user id="%s">
          <params>
            <param name="password" value="%s"/>
          </params>
          <variables>
            <variable name="user_context" value="default"/>
            <variable name="effective_caller_id_name" value="%s"/>
            <variable name="effective_caller_id_number" value="%s"/>%s
          </variables>
        </user>
      </users></group></groups>
    </domain>
  </section>
</document>]], DOMAIN, user, PASSWORD, user, user, group_vars)
