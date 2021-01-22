local iup = require "iuplua"
require "iupluaim"
local pretty = require "pl.pretty"

-- Couple of constants and adjustments
local yes, no = "YES", "NO"
local vertical, horizontal = "VERTICAL", "HORIZONTAL"
local HGAP, VGAP = 20, 5
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

-- List of computers to check
local computers = {
   {dname = "macbookpro .. ", hname = "macbookpro"},
   {dname = "raspi 1 ..... ", hname = "raspberrypi1"},
   {dname = "raspi 2 ..... ", hname = "raspberrypi2"},
   {dname = "raspi 3 ..... ", hname = "raspberrypi3"},
   {dname = "raspi 4 ..... ", hname = "raspberrypi4"},
   {dname = "raspi 5 ..... ", hname = "raspberrypi5"},
   {dname = "maclinux: ... ", hname = "maclinux"}
}

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

for i,v in ipairs(weatherImageNames) do
   weatherImages[v] = iup.LoadImage("/usr/local/share/luanagios/img/PNG/"..weatherImageFiles[v])
   weatherImages[v].resize = "40x40"
   forecastImages[v] = iup.LoadImage("/usr/local/share/luanagios/img/PNG/"..weatherImageFiles[v])
   forecastImages[v].resize = "32x32"
end

local luaicon = iup.LoadImage("/usr/local/share/luanagios/img/luanagios.png")

local screenButton
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
      local res, _, n = os.execute("ping -c 1 -W 1 "..computers[index].hname)
      if res == true and n == 0 then
	 s = "OK"
      else
	 s = "--"
      end
      computers[index].label.title = computers[index].dname .. s
      return true
   else
      s = "--"
      computers[index].label = iup.flatlabel{
	 font = "Courier New, Bold 18",
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
	 font = "Arial, Bold 36",
	 title = string.format("%s, %02d.%02d.%04d",
			       wdays[t.wday], t.day, t.month, t.year)
      }
      return date
   else
      date.title = string.format("%s, %02d.%02d.%04d",
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
	 title = string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
      }
      return clock
   else
      clock.title = string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
      return true
   end
end


--------------------------------------------------------------------------------
-- Get weather forecast data
-- @return table with weather forecast data
--------------------------------------------------------------------------------
local function foo()
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
      stat, s = pcall(foo)
      if stat == true then
	 local f = load(s)
	 if f ~= nil then
	    t = f()
	 else
	    t = nil
	 end
      end
      if t ~= nil then
	 weather.title = string.format("  %+3.1f °C - %d %% - %s",
				       t.current.temp, t.current.humidity,
				       t.current.weather[1].description)
	 weatherimage.image = weatherImages[t.current.weather[1].icon]
--	 print("#1#", t.current.weather[1].icon, weatherImages[t.current.weather[1].icon])
	 for k, u in ipairs(t.daily) do
	    forecast[k].title = string.format("   %s: %+3.1f °C %5s %5s %s",
					os.date("%d.%m", u.dt),
					u.temp.day,
					os.date("%H:%M", u.sunrise),
					os.date("%H:%M", u.sunset),
					u.weather[1].description)
	    forecastimage[k].image = forecastImages[u.weather[1].icon]
--	    print("#2#", u.weather[1].icon, forecastImages[u.weather[1].icon])
	 end
      end
      return true
   else
      weather = iup.label{
	 font = "Courier New, Bold 16",
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

--------------------------------------------------------------------------------
-- Turn screen on or off and update state.
-- @param v  New state: true=on, false=off
-- @return state of screen "on"/"off"
--------------------------------------------------------------------------------
local function screenOn(v)
   if v == true then
      repeat
	 os.execute("/usr/local/sbin/screen-on")
      until isScreenOn() == true 
      scstate = "on"
      screenButton.title = "Dunkel"
   else
      repeat
	 os.execute("/usr/local/sbin/screen-off")
      until isScreenOn() == false
      scstate = "off"
      screenButton.title = "Hell"
   end
   return scstate
end

-- Button to turn screen backlight on or off
screenButton = iup.button{
   title = "Dunkel",
   expand = horizontal,
   action = function(self)
      if scstate == "on" then
	 screenOn(false)
      else
	 screenOn(true)
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
	 title = string.format("%d", 0)
      }
      statscreen = iup.label{
	 title = "-"
      }
      statgc = iup.label{
	 title = "-"
      }
      return iup.hbox{statscreen, statcount, statgc}
   else
      statcount.title = string.format("%d", mcnt)
      sstat = isScreenOn()
      statgc.title = string.format("%d", collectgarbage("count"))
      if sstat == true then
	 statscreen.title = "on"
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
local function checkOnOff(now)
   if scstate == "on" then
      if now.hour == onoff.off.hour and now.min == onoff.off.min then
	 screenOn(false)
      end
   elseif scstate == "off" then
      if now.hour == onoff.on.hour and  now.min == onoff.on.min then
	 screenOn(true)
      end
   elseif scstate == "unknown" then
      local on_mins = onoff.on.hour * 60 + onoff.on.min
      local off_mins = onoff.off.hour * 60 + onoff.off.min
      local now_mins = now.hour * 60 + now.min
      if now_mins >= on_mins and now_mins < off_mins then
	 screenOn(true)
      else
	 screenOn(false)
      end
   end
   return scstate
end

local sbutton = iup.button{
   title = scstate,
   action = function(self) os.exit(0) end
}

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
	 value = "TODAY"
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
   which = which or "cal"
   if which == "cal" then
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
	    gap = 3,
	    icon("cal"),
	    iup.hbox {
	       iup.label{
		  font = "Arial, Bold 18",
		  title = "  "
		  --title = "RECHNER:"
	       },
	       sbutton,
	       normalizesize = "VERTICAL"
	    },
	    rechner(1, false),
	    rechner(2, false),
	    rechner(3, false),
	    rechner(4, false),
	    rechner(5, false),
	    rechner(6, false),
	    rechner(7, false)
	 },
	 iup.vbox {
	    width = "10x"
	 },
	 iup.vbox {
	    gap = 10,
	    datum(false),
	    uhrzeit(false),
	    wetter(false)
	 },
      },
      iup.space {
	 size="x2",
	 expand = yes
      },
      iup.hbox {
	 gap = HGAP,
	 iup.hbox {
	    screenButton,
	    status(false),
	    iup.button{
	       title = "Schließen",
	       expand = horizontal,
	       action = function(self) os.exit(0) end
	    }
	 }
      }
   }
}
local logfile = assert(io.open("/tmp/disp.log", "a+"))
logfile:write("=== log started" .. os.date() .. "\n")
dlg:show()
local t1, t2, dt, dtmax, dtmaxlast = 0, 0, 0, -1, 0
local dtmaxlast = 0
--collectgarbage("setstepmul", 300)
--collectgarbage("setpause", 100)
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
      -- 1 second interval
      if cnt % 2 == 0 then
	 collectgarbage("collect")
      end
      local t = os.date("*t")
      uhrzeit(true)
      datum(true)
      kalender(true)
      status(true)
      cnt = cnt + 1
      mcnt = mcnt - 1
      t2 = self.elapsedtime
      dt = (t2 - t1)/1000
      t1 = t2
      if dt > dtmax then dtmax = dt end
--      print("dt=", dt, dtmax, collectgarbage("count"))
      if dtmax ~= dtmaxlast then
	 logfile:write(string.format("dt=%.3f dtmax=%.3f gc=%d  at %s\n",
				     dt, dtmax, 
				     collectgarbage("count"), os.date()))
      end
      dtmaxlast = dtmax
      if dt > 5 then
	 iup.Message("Attention", string.format("Missed a time tick: dt=%.1f at %.1f", dt, t2/1000))
      end
      sbutton.title = checkOnOff(t)
   end
}

timer.run = yes

iup.MainLoop()
