local iup = require "iuplua"
require "iupluaim"
local snmp = require "snmp"
local pretty = require "pl.pretty"
logging = require "logging"
require "logging.file"
local log = logging.file("/tmp/disp.log")
log:setLevel(logging.DEBUG)
log:info("Log started")
local async = true
-- Couple of generic constants and adjustments
local format = string.format
local yes, no = "YES", "NO"
local vertical, horizontal = "VERTICAL", "HORIZONTAL"
local HGAP, VGAP = 5, 5
local wdays = {
   "Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"
}
local scstate = "unknown"
local onoff = {
   off = {
      hour = tonumber(os.getenv("off_h")) or 22,
      min = tonumber(os.getenv("off_m")) or 30
   },
   on = {
      hour = tonumber(os.getenv("on_h")) or 9,
      min = tonumber(os.getenv("on_m")) or 0
   }
}

-- Variables
local screenOn = true
local clock
local date
local cal
local weather, weatherimage
local forecast, forecastimage = {}, {}
local screensize =  iup.GetGlobal("SCREENSIZE")
local screensize = "810 x 490"
local cnt, mcnt = 1, 1200
local statcount, statscreen, statgc
local tempsens = {}
local t1, t2, dt, dtmax, dtmaxlast = 0, 0, 0, -1, 0
local dtmaxlast = 0
local cam = {}
local camcontainer
local last_status_update = 0

-- List of computers to check
local computers = {
--   {dname = "fritzbox .... ", hname = "fritz.box"},
   {dname = "macbookpro:", hname = "macbookpro"},
   {dname = "raspi 1   :", hname = "raspberrypi1"},
   {dname = "raspi 2   :", hname = "raspberrypi2"},
   {dname = "raspi 3   :", hname = "raspberrypi3"},
   {dname = "raspi 4   :", hname = "raspberrypi4"},
   {dname = "raspi     :", hname = "raspberrypi5"},
   {dname = "maclinux  :", hname = "maclinux"}
}

for _, v in ipairs(computers) do
   v.sess, err = snmp.open{peer = v.hname}
end

-- Load and condition weather icons
local weatherImageNames = {
"01d", "02d", "03d", "04d", "09d", "10d", "11d", "13d", "50d",
"01n", "02n", "03n", "04n", "09n", "10n", "11n", "13n", "50n",
}

local weatherImageFiles = {
   ["01d"] = "day_clear.png",
   ["01n"] = "night_clear.png",
   ["02d"] = "day_partial_cloud.png",
   ["02n"] = "night_partial_cloud.png",
   ["03d"] = "cloudy.png",
   ["03n"] = "cloudy.png",
   ["04d"] = "overcast.png",
   ["04n"] = "overcast.png",
   ["09d"] = "rain.png",
   ["09n"] = "rain.png",
   ["10d"] = "day_rain.png",
   ["10n"] = "night_rain.png",
   ["11d"] = "thunder.png",
   ["11n"] = "thunder.png",
   ["13d"] = "snow.png",
   ["13n"] = "snow.png",
   ["50d"] = "mist.png",
   ["50n"] = "mist.png",
   
}
local weatherImages, forecastImages = {}, {}

local tempsess = snmp.open{peer="raspberrypi4"}

for i,v in ipairs(weatherImageNames) do
   weatherImages[v] = iup.LoadImage("/usr/local/share/luanagios/img/PNG/"..
				    weatherImageFiles[v])
   weatherImages[v].resize = "40x40"
   forecastImages[v] = iup.LoadImage("/usr/local/share/luanagios/img/PNG/"..
				     weatherImageFiles[v])
   forecastImages[v].resize = "32x32"
end

local luaicon = iup.LoadImage("/usr/local/share/luanagios/img/luanagios.png")

local sbutton = iup.button{
   title = scstate,
   action = function(self) os.exit(0) end
}

local statproc = iup.label{
   font = "Arial, 10",
   title = "  start ..."
}

local function putStatus(s)
   statproc.title = s
   last_status_update = os.time()
end

-- SMB:
-- local wb_fname = "/mnt/pi4disk/dev/shm/mjpeg/cam.jpg"
-- NFS:
local wb_fname = "/net/nfs/mjpeg/cam.jpg"
local lwb_fname = "/dev/shm/mjpeg/cam.jpg"

--------------------------------------------------------------------------------
-- Copy webcam image to local ramdisk
--------------------------------------------------------------------------------
local function copyCam()
   local s
   local t0 = os.time()
   repeat
      local fi = assert(io.open(wb_fname,"rb"))
      s = fi:read("*a")
      fi:close()
      if os.time() - t0 > 5 then
	 log:error(format("read timeout %d sec", os.time() - t0))
	 s = nil
	 break
      end
   until s ~= nil 
   if s then
      local fo = assert(io.open(lwb_fname, "wb"))
      fo:write(s)
      fo:close()
   end
end

--------------------------------------------------------------------------------
-- Read webcam image
-- @return iup image object
--------------------------------------------------------------------------------
local function getWebcamImage()
   local wwidth = 220
   local img
   local trial = 1
   local t0=os.time()
   copyCam()
   repeat
      img = iup.LoadImage(lwb_fname)
      if os.time() - t0 > 2 then
	 return nil, "timeout"
      end
      trial = trial + 1
   until img ~= nil
   img.resize = tostring(wwidth).."x"..tostring(wwidth*3/4)
   return img
end

--------------------------------------------------------------------------------
-- Rechner Callback
-- @param vb result as varbind, nil in case of an error.
-- @param err error string.
-- @param index table index.
-- @param reqid request id.
-- @param sess session handle.
-- @param magic opaque magic value, here: index of computer
--------------------------------------------------------------------------------
local function rechner_cb(vb, err, index, reqid, sess, magic)
   if vb then
      log:debug(format("rechner_cb() ok %s for rechner %q",
		       pretty.write(vb,""),
		       computers[magic].hname))
      computers[magic].label.title =
	 format("%s %2d d %02d:%02d", computers[magic].dname,
		vb.value.days, vb.value.hours, vb.value.minutes)
   else
      log:error(format("rechner_cb() error %s for rechner %q",
		       err, computers[magic].dname))
      computers[magic].label.title = computers[magic].dname .. " down"
   end
end

--------------------------------------------------------------------------------
-- Computer status evaluation and display.
-- @param index Index to retrieve computer info: display and hostname
-- @param check Control what to do:
--              flase - generate diag elements
--              true  - check status and display result
-- @return IUP element showing the computer status
--------------------------------------------------------------------------------
local function rechner(index, check)
   local s
   if check == true then
      if async == true then
	 local sess = computers[index].sess
	 if sess then
	    local ret, err = computers[index].sess:asynch_get("sysUpTime.0",
							      rechner_cb, index)
	 else
	    computers[index].label.title = computers[index].dname .. " down"
	 end
	 return true
      else
	 putStatus(format("  check rechner %q ...", computers[index].hname))
	 local res, _, n = os.execute("ping -c 1 -W 1 " .. computers[index].hname .. "> /dev/null")
	 if res == true and n == 0 then
	    s = "OK"
	 else
	    s = "--"
	 end
	 computers[index].label.title = computers[index].dname .. s
	 return true
      end
   else
      s = " wait ...     "
      computers[index].label = iup.flatlabel{
	 font = "Courier New, 12",
	 title = computers[index].dname .. s
      }
      return computers[index].label
   end
end

--------------------------------------------------------------------------------
-- Date evaluation and display
-- @param check Control what to do:
--              flase - generate diag elements
--              true  - check status and display result
-- @return IUP element showing the date
--------------------------------------------------------------------------------
local function datum(check)
   local t = os.date("*t")
   if check == false then
      date = iup.label{
	 font = "Arial, Bold 32",
	 title = format("%s, %02d.%02d.%04d",
			       wdays[t.wday], t.day, t.month, t.year)
      }
      return date
   else
      date.title = format("%s, %02d.%02d.%04d",
				 wdays[t.wday], t.day, t.month, t.year)
      return true
   end
end

--------------------------------------------------------------------------------
-- Time evaluation and display
-- @param check Control what to do:
--              flase - generate diag elements
--              true  - check status and display result
-- @return IUP element showing the time
--------------------------------------------------------------------------------
local function uhrzeit(check)
   local t = os.date("*t")
   if check == false then
      clock = iup.label{
	 font = "Arial, Bold 48",
	 title = format("%02d:%02d:%02d", t.hour, t.min, t.sec)
      }
      return clock
   else
      clock.title = format("%02d:%02d:%02d", t.hour, t.min, t.sec)
      return true
   end
end

--------------------------------------------------------------------------------
-- Rechner Callback
-- @param vb result as varbind, nil in case of an error.
-- @param err error string.
-- @param index table index.
-- @param reqid request id.
-- @param sess session handle.
-- @param magic opaque magic value, here: index of computer
--------------------------------------------------------------------------------
local function temp_cb(vb, err, index, reqid, sess, magic)
   if vb then
      log:debug(format("temp_cb(): %s for sensor %d", tostring(vb), magic))
      tempsens[magic].title = format("Temp %d: %5.1f °C", magic, vb.value) 
   else
      -- log error
      log:error(format("temp_cb() error %d", err))
   end
end

--------------------------------------------------------------------------------
-- Temperature sensors
-- @param index sensor index.
-- @param check true: measure, false: build gui element
-- @return true if check == true, iUP element if check == false
--------------------------------------------------------------------------------
local function tempsensor(index, check)
   if check == false then
      tempsens[index] = iup.label{
	    font = "Arial, Bold 12",
	    title = format("Temp %d: wait ...", index)
	 }
      return tempsens[index]
   else
      putStatus(format("  check temperature %d ...", index))
      if async == true then
	 local ret, err = tempsess:asynch_get("extOutput."..index, temp_cb, index)
	 return true
      else
	 local temp = tonumber(tempsess["extOutput_"..index])
	 tempsens[index].title = format("Temp %d: %5.1f °C", index, temp)
	 return true
      end
   end
end

--------------------------------------------------------------------------------
-- Get weather forecast data
-- @return table with weather forecast data
--------------------------------------------------------------------------------
local function getWeather()
   return io.popen("check_weather -l 'Gross Kummerfeld' -L de -m forecast -P `cat ~/.appid` -t"):read("*a")
end

--------------------------------------------------------------------------------
-- Weather status evaluation and display.
-- @param check Control what to do:
--              flase - generate diag elements
--              true  - check status and display result
--------------------------------------------------------------------------------
local function wetter(check)
   local stat, s, t
   if check == true then
      putStatus("  check weather ...")
      stat, s = pcall(getWeather)
      if stat == true then
	 local f = load(s)
	 if f ~= nil then
	    t = f()
	 else
	    t = nil
	 end
      end
      if t ~= nil then
	 weather.title = format("  %+3.1f °C - %d %% - %s",
				       t.current.temp, t.current.humidity,
				       t.current.weather[1].description)
	 weatherimage.image = weatherImages[t.current.weather[1].icon]
	 for k, u in ipairs(t.daily) do
	    forecast[k].title = format("   %s: %+3.1f °C %5s %5s %s",
					os.date("%d.%m", u.dt),
					u.temp.day,
					os.date("%H:%M", u.sunrise),
					os.date("%H:%M", u.sunset),
					u.weather[1].description)
	    forecastimage[k].image = forecastImages[u.weather[1].icon]
	 end
      end
      return true
   else
      weather = iup.label{
	 font = "Courier New, Bold 14",
	 title = "wait ...",
      }
      
      weatherimage = iup.label{
	 image = weatherImages["50d"],
      }
      local forecastcont = {}
      for i = 1, 8 do
	 forecast[i] = iup.label{
	    font = "Courier New, Bold 12",
	    title = "wait ...",
	 }
	 forecastimage[i] = iup.label{
	    image = forecastImages["50d"],
	 }
	 forecastcont[i] = iup.hbox{
	    gap=5,
	    normalizesize="VERTICAL",
	    forecastimage[i],
	    forecast[i]
	 }
      end
      return
	 iup.hbox{
	    gap=5, normalizesize="VERTICAL",
	    weatherimage,
	    weather
	 },
	 iup.vbox{
	    gap=-3,
	    table.unpack(forecastcont)
	 }
   end
end

--------------------------------------------------------------------------------
-- Check screen status
-- @return true: screen is on, false: screen is off
--------------------------------------------------------------------------------
local function isScreenOn()
   local fd, s
   repeat
      fd =  io.popen("/usr/local/sbin/screen-show")
   until fd ~= nil
   repeat
      s = fd:read()
   until s ~= nil
   if s == "0" then
      return true
   else
      return false
   end
end

-------------------------------------------------------------------------------
-- Webcam picture.
-- @param check control what do do
--              false - generate diag elements
--              true  - read new image
-- @return IUP element
-------------------------------------------------------------------------------
local function webcam(check)
   if check == true then
      local img
      if camix == 0 then
	 -- pic 0 is visible: make 1 visible and load into 0
	 camcontainer.valuepos = 1
	 cam[0].visble = no
	 cam[1].visible = yes
	 img = cam[0].image
	 cam[0].image = getWebcamImage()
	 camix = 1
      else
	 -- pic 1 is visible: make 0 visible and load into 1
	 camcontainer.valuepos = 0
	 cam[1].visble = no
	 cam[0].visible = yes
	 img = cam[1].image
	 cam[1].image = getWebcamImage()
	 camix = 0
      end
      if img ~= nil then
	 img:destroy()
      end
   else
      cam[0] = iup.label{
	 image = getWebcamImage(),
	 alignment = "ARIGHT:ABOTTOM",
	 visible = yes
      }
      cam[1] = iup.label{
	 image = getWebcamImage(),
	 alignment = "ARIGHT:ABOTTOM",
	 visible = no
      }
      camix = 0
      camcontainer = iup.zbox{
	 cam[0],
	 cam[1],
	 valuepos = 0
      }
      return camcontainer
   end
end

--------------------------------------------------------------------------------
-- Turn screen on or off and update state.
-- @param button  Button to update title.
-- @param v  New state: true=on, false=off
-- @return state of screen "on"/"off"
--------------------------------------------------------------------------------
local function screenOn(button, v)
   if v == true then
      repeat
	 os.execute("/usr/local/sbin/screen-on")
      until isScreenOn() == true 
      scstate = "on"
      button.title = "Dunkel"
   else
      repeat
	 os.execute("/usr/local/sbin/screen-off")
      until isScreenOn() == false
      scstate = "off"
      button.title = "Hell"
   end
   return scstate
end

-- Button to turn screen backlight on or off
local screenButton = iup.button{
   title = "Dunkel",
   font = "Arial, 12",
   expand = horizontal,
   action = function(self)
      if scstate == "on" then
	 screenOn(self, false)
      else
	 screenOn(self, true)
      end
   end
}

--------------------------------------------------------------------------------
-- Couonter status (just temporary help  - should vanish)
-- @param check Control what to do:
--              flase - generate diag elements
--              true  - check status and display result
-- @return IUP element.
--------------------------------------------------------------------------------
local function status(check)
   local sstat
   if check == false then
      statcount = iup.label{
	 font = "Arial, 10",
	 title = format("%5d", 0)
      }
      statscreen = iup.label{
	 font = "Arial, 10",
	 title = "---"
      }
      statgc = iup.label{
	 font = "Arial, 10",
	 title = "---- kB"
      }
      return iup.hbox{
	 gap = 40,
	 statscreen, statcount, statgc
      }
   else
      if os.time() - last_status_update > 5 then
	 putStatus("")
      end
      statcount.title = format("%5d", mcnt)
      sstat = isScreenOn()
      statgc.title = format("%4d kB", collectgarbage("count"))
      if sstat == true then
	 statscreen.title = " on"
      else
	 statscreen.title = "off"
      end
      return true
   end
end

--------------------------------------------------------------------------------
-- Check whether screen shall be on (day) or off (night).
-- @param now current time
-- @return screen state
--------------------------------------------------------------------------------
local function checkOnOff(button, now)
   if scstate == "on" then
      if now.hour == onoff.off.hour and now.min == onoff.off.min then
	 screenOn(button, false)
      end
   elseif scstate == "off" then
      if now.hour == onoff.on.hour and  now.min == onoff.on.min then
	 screenOn(button, true)
      end
   elseif scstate == "unknown" then
      local on_mins = onoff.on.hour * 60 + onoff.on.min
      local off_mins = onoff.off.hour * 60 + onoff.off.min
      local now_mins = now.hour * 60 + now.min
      if now_mins >= on_mins and now_mins < off_mins then
	 screenOn(button, true)
      else
	 screenOn(button, false)
      end
   end
   return scstate
end

-------------------------------------------------------------------------------
-- Calendar.
-- @param check Control what to do:
--              flase - generate diag elements
--              true  - check status and display result
-- @return IUP element 
-------------------------------------------------------------------------------
local function kalender(check)
   if check == true then
      cal.value = "TODAY"
      return true
   else
      cal = iup.calendar{
	 weeknumbers = yes,
	 font = "Courier, Bold 12",
	 value = "TODAY",
	 bgcolor = "50 50 50"
      }
      return cal
   end
end

-------------------------------------------------------------------------------
-- Create  Icon in upper left corner
-- @param which  "cal" for calendar, "lua" for Luanagios icon
-- @return flatfram with selected icon embedded.
-------------------------------------------------------------------------------
local function icon(which)
   icontab = iup.tabs{
      alignment = "CENTER",
      bgcolor = "52 57 59",
      font = "Arial, 12",
      childoffset = "5x10",
      tabpadding = "5x5",
      iup.flatframe{
	 marginleft = 5,
	 margintop = 5,
	 kalender(false),
	 frame = no,
      },
--      iup.flatframe{
--	 bgcolor = "132 132 132",
--	 iup.label{
--	    image = luaicon,
--	 }
--      },
      iup.flatframe{
	 webcam(false),
	 marginleft = 5,
	 margintop = 5,
	 frame = no,
      },
      tabtitle0 = "Kalender",
--      tabtitle1 = "Icon",
      tabtitle1 = " Kamera ",
--      tabtype = "BOTTOM",
--      taborientation = "VERTICAL"
   }
   if which == "cal" then
      icontab.valuepos = 0
--   elseif which == "lua" then
--      icontab.valuepos = 1
   else
      icontab.valuepos = 1
   end
   return icontab
end

-------------------------------------------------------------------------------
-- Create  Icon in upper left corner
-- @param which  "cal" for calendar, "lua" for Luanagios icon
-- @return flatfram with selected icon embedded.
-------------------------------------------------------------------------------
local function __icon(which)
   which = which or "cal"
   if which == "cal" then
      icontype = which
      return
	 iup.flatframe{
	    marginleft = 5,
	    margintop = 5,
	    kalender(false),
	 },
	 iup.space{
	    size = "x10",
	    expand = no
	 }
	 
   elseif which == "lua" then
      return
	 iup.flatframe{
	    bgcolor = "132 132 132",
	    iup.label{
	       image = luaicon,
	    }
	 },
	 iup.space{
	    size = "x10",
	    expand = no
	 }
   elseif which == "cam" then
      return
	 iup.flatframe{
	    webcam(false)
	 },
	 iup.space{
	    size = "x10",
	    expand = no
	 }
	 
   end
end

-------------------------------------------------------------------------------
-- This is the main dialog
-------------------------------------------------------------------------------
local dlg = iup.dialog {
--   size = "FULL",
   rastersize = screensize,
   --   font = "Arial, Bold 18"
   menubox = no,
   maxbox = no,
   minbox = no,
   resize = no,
   iup.vbox {
      iup.hbox {
	 gap = HGAP,
	 iup.vbox {
--	    gap = 3,
	    margin = "5x5",
	    --	    icon("cal"),
	    icon("cam"),
--[[
	    iup.hbox {
	       iup.label{
		  font = "Arial, Bold 18",
		  title = "  "
		  --title = "RECHNER:"
	       },
--	       sbutton,
	       normalizesize = "VERTICAL"
	    },
]]
	    rechner(1, false),
	    rechner(2, false),
	    rechner(3, false),
	    rechner(4, false),
	    rechner(5, false),
	    rechner(6, false),
	    rechner(7, false),
--	    rechner(8, false)
	 },
--	 iup.vbox {
--	    width = "10x"
--	 },
	 iup.vbox {
	    gap = 10,
	    datum(false),
	    iup.hbox {
	       uhrzeit(false),
	       iup.vbox {
		  tempsensor(2, false),
		  tempsensor(3, false),
		  tempsensor(4, false)
	       }
	    },
	    wetter(false)
	 },
      },
      iup.space {
	 size="x2",
	 expand = yes
      },
      iup.hbox {
	 gap = 40,
	 iup.hbox {
	    screenButton,
	    iup.vbox {
	       gap = 0,
	       status(false),
	       statproc
	    },
	    iup.button{
	       title = "Schließen",
	       font = "Arial, 12",
	       expand = horizontal,
	       action = function(self) os.exit(0) end
	    }
	 }
      }
   }
}

-- show the dialog
dlg:show()

-------------------------------------------------------------------------------
-- Timer for triggering the updates.
-------------------------------------------------------------------------------
local timer = iup.timer{
   time = 500,
   action_cb = function(self)
      -- 300 second interval - 5 minutes
      if cnt % (600) == 10 then
	 for i = 1, #computers do
	    rechner(i, true)
	 end
      end
      -- 600 second interval - 10  minutes
      if cnt % (1200) == 12 then
	 wetter(true)
	 mcnt = 1200
      end
      collectgarbage("collect")
      -- 30 seconds update temperatures
      
      if cnt % 60 == 8 then
	 for i = 2, 4 do
	    tempsensor(i, true)
	 end
      end
      
      local t = os.date("*t")
      uhrzeit(true)
      datum(true)
      kalender(true)
      webcam(true)
      status(true)
      cnt = cnt + 1
      -- we display this counter in the status line
      mcnt = mcnt - 1
      
      -- track for missed triggers: we log every period that exceeds the last one
      t2 = self.elapsedtime
      dt = (t2 - t1)/1000
      t1 = t2
      if dt > dtmax then dtmax = dt end
      if dtmax ~= dtmaxlast then
	 log:info(format("dt=%.3f dtmax=%.3f gc=%d", dt, dtmax,
			 collectgarbage("count")))
      end
      dtmaxlast = dtmax
--      snmp.event()
      -- update status
      sbutton.title = checkOnOff(screenButton, t)
   end
}

local timerSnmp = iup.timer{
   time = 50,
   action_cb = function(self)
      snmp.event()
   end
}
timer.run = yes
timerSnmp.run = yes

iup.MainLoop()
