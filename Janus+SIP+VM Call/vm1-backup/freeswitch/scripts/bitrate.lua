if not session or not session:ready() then
  freeswitch.consoleLog("ERR", "Session not ready, aborting bitrate.lua\n")
  return
end

local br = 8000

-- Force OPUS on A-leg
session:execute("set", "absolute_codec_string=OPUS")

-- OPUS low bitrate settings
session:execute("set", "opus_bitrate=" .. br)
session:execute("set", "opus_maxaveragebitrate=" .. br)
session:execute("set", "opus_maxplaybackrate=" .. br)
session:execute("set", "opus_use_cbr=1")
session:execute("set", "opus_use_vbr=0")
session:execute("set", "opus_use_dtx=1")
session:execute("set", "opus_complexity=5")

-- B-leg (carrier side) codec (keep if you want G729 there)
session:execute("export", "nolocal:absolute_codec_string=PCMU")

freeswitch.consoleLog("INFO", "Forced OPUS 8kbps on A-leg for outgoing call\n")
