local iup = require "iuplua"
require "iupluaim"
local snmp = require "snmp"
local soap_client = require "soap.client"
local pretty = require "pl.pretty"
logging = require "logging"
require "logging.file"
local copas = require "copas"
local asynchttp = require("copas.http").request
local json = require "cjson"
local socket = require "socket"
local lxp = require "lxp.lom"
local _USER = "leuwer"
local fn = os.getenv("HOME").."/.passwd"
local fin=assert(io.open(fn, "r"))
local _PASSWORD = fin:read("*l")
fin:close()
--print(_USER, _PASSWORD)
--iup.SetGlobal("IUPLUA_THREADED", "1")
--------------------------------------------------------------------------------
-- We need this for decoding openweathermap.com json results correctly
os.setlocale("de_DE.UTF-16")

local opt = {
   weather = {
      showPressure = true,
      togglePressure = true,
   },
   toggleWebcam = true
}

--------------------------------------------------------------------------------
-- Logging stuff
local log = logging.file("/tmp/disp.log")
log:setLevel(logging.INFO)
log:info("Log started")

--------------------------------------------------------------------------------
-- Couple of generic constants and adjustments
local format = string.format
local tinsert = table.insert
local yes, no = "YES", "NO"
local on, off = "ON", "OFF"
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

--------------------------------------------------------------------------------
-- Variables
local screenOn = true
local update = {
   datum = true,
   uhrzeit = true,
   wetter = true,
   tempsensor = true,
   rechner = true,
   status = true,
   webcam = true,
   kalender = true
}
local clock
local date
local cal
local weather, weatherimage
local forecast, forecastimage = {}, {}
local screensize =  iup.GetGlobal("SCREENSIZE")
log:debug("screensize: "..screensize)
--local screensize = "810 x 490"
local cnt, mcnt = 1, 1200
local statcount, statscreen, statgc
local tempsens = {}
local t1, t2, dt, dtmax, dtmaxlast = 0, 0, 0, -1, 0
local dtmaxlast = 0
local cam = {}
local camcontainer
local last_status_update = 0



--------------------------------------------------------------------------------
-- Fonts
local fonts = {
   headline = "Arial, 12",
   list = "Courier New, 11",
   standard = "Arial, 10",
   clock = "Arial, Bold, 48",
   datum = "Arial, 36",
   temp = "Arial, 12",
   weather = "Courier New, 11",
   kalender = "Courier New, 10",
   forecast = "Courire, 12",
   status = "Courier New, 8",
   button = "Arial, 9"
}

--------------------------------------------------------------------------------
-- Local weather context
local lastWeather

--------------------------------------------------------------------------------
-- Main Content
local _content
local function content(t)
   _content =  iup.zbox(t)
   _content.valuepos = 0
   return _content
end

--------------------------------------------------------------------------------
-- Some predefined GUI elements
local luaicon = iup.LoadImage("/usr/local/share/luanagios/img/luanagios.png")

local sbutton = iup.button{
   title = scstate,
   font = fonts.button,
   tip = "Schalte Bildschirm hell oder dunkel",
   action = function(self) os.exit(0) end
}

local statproc = iup.label{
      font = fonts.status,
      expand = horizontal,
      title = "  start ..."
}

local function putStatus(s)
   statproc.title = s
   last_status_update = os.time()
end

--------------------------------------------------------------------------------
-- Alternate content: call list

local _calls = iup.list{
   visiblelines = 18,
   minsize = "800x",
   font = fonts.list,
   rebuild = function(self, vall)
      self.items = vall
      self.removeitem = "ALL"
      for _, v in ipairs(vall) do
	 if string.sub(v, 1, 2) == "IN" and togCallIn.value == on then
	    self.appenditem = v
	 elseif string.sub(v, 1, 3) == "OUT" and togCallOut.value == on then
	    self.appenditem = v
	 elseif string.sub(v, 1, 4) == "NONE" and togCallNone.value == on then
	    self.appenditem = v
	 end
      end
   end
}

local function togCallback(self)
   log:info(format("toggled callist %q to %s", self.title, self.value))
   return self.calls:rebuild(self.calls.items)
end

togCallIn = iup.toggle {
   title = "eingehend",
   value = on,
   calls = _calls,
   valuechanged_cb = togCallback
}
togCallOut = iup.toggle {
   title = "ausgehend",
   value = off,
   calls = _calls,
   valuechanged_cb = togCallback
}
togCallNone = iup.toggle {
   title = "unerreicht",
   value = off,
   calls = _calls,
   valuechanged_cb = togCallback
}

--------------------------------------------------------------------------------
-- Call list handler.
-- Runs as coroutine scheduled by copas.
-- Performs asynchronous http request for call list.
-- @param url URL of call list CGI script.
-- @return none.
--------------------------------------------------------------------------------
local function callListHandler(url)
   local function adj(s)
      return s .. string.rep(" ", 25-#s)
   end
   log:info(format("reading call list from %q", url))
   local res, err = asynchttp(url)
   log:info(format("call list read result %s", err or "nil"))
   if res == nil then
      log:error("Cannot read call list %q", url)
   end
   local t = lxp.parse(res)
   local r = {}
   for i, v in ipairs(t) do
      if type(v) == "table" then
	 if v.tag == "Call" then
	    local e = {}
	    for j, w in ipairs(v) do
	       if type(w) == "table" then
		  e[w.tag] = w[1]
	       end
	    end
	    tinsert(r, e)
	 elseif v.tag == "timestamp" then
	    r.timestamp = v[1]
	    r.date = os.date(nil, tonumber(v[1]))
	    end
      end
   end
   local vall = {}
   local n_in, n_out, n_none = 0, 0, 0
   for _, e in ipairs(r) do
      if e.Type == "1" then
	 -- incoming
	 tinsert(vall, format("IN   %14s\t%-s\t%5s\t%-16s",
			      e.Date, adj(e.Name or e.Caller), e.Duration, e.Device))
	 n_in = n_in + 1
      elseif e.Type == "3" then
	 -- outgoing
	 tinsert(vall, format("OUT  %14s\t%-s\t%5s\t%-16s",
			      e.Date, adj(e.Name or e.Called), e.Duration, e.Device))
	 n_out = n_out + 1
      elseif e.Type == "2" then
	 -- absent
	 tinsert(vall, format("NONE %14s\t%-s\t%5s\t%-16s",
			      e.Date, adj(e.Name or e.Caller), e.Duration, e.Device or "-"))
	 n_none = n_none + 1
      end
   end
   _calls:rebuild(vall)
   return true
end

--------------------------------------------------------------------------------
-- Call list callback.
-- Executed once soap request completed.
-- @param ns namespace of soap request.
-- @param meth soap method table.
-- @param ent result table.
-- @param soap_headers soap request headers in table.
-- @param body body of response.
-- @param magic opaque value from request.
-- @return true.
--------------------------------------------------------------------------------
local function calls_cb(ns, meth, ent, soap_headers, body, magic)
   local url = ent[2][1]
   log:info(format("call list URL: %q", ent[2][1]))
   url = string.gsub(url, "%[(.+)%]", "fritz7590")
   local res, err = copas.addthread(callListHandler, url)
   if not res then
      log:error(format("lauching call list request failed with %q", err))
   end
   return true
end

--------------------------------------------------------------------------------
-- Call list action.
-- @param check false: return GUI element; true: update GUI element
-- @return GUI element if check == false; nothing otherwise
--------------------------------------------------------------------------------
local function calls(check)
   if check == true then
      local request =  {
	 auth = "digest",
	 soapaction = "urn:dslforum-org:service:X_AVM-DE_OnTel:1#GetCallList",
	 method = "GetCallList",
	 namespace = "urn:dslforum-org:service:X_AVM-DE_OnTel:1",
	 url = "http://".._USER..":".._PASSWORD.."@fritz7590:49000/upnp/control/x_contact",
	 entries = {
	    tag = "u:GetCallList"
	 },
	 handler = calls_cb,
	 opaque = "call-list"
      }
      putStatus(format("  retrieving call list ..."))
      soap_client.call(request)
   else
      local ret = iup.vbox {
	 iup.frame {
	    iup.hbox {
	       gap = 20, 
	       iup.label{
		  title = "Anrufliste",
		  font = fonts.headline
	       },
	       iup.button {
		  title = "Abholen",
		  font = fonts.button,
		  action = function(self)
		     calls(true)
		  end
	       },
	       togCallIn,
	       togCallOut,
	       togCallNone,
	    }
	 },
	 _calls,
      }
      return ret
   end
end

--------------------------------------------------------------------------------
-- Button that toggles through the contents
local contentButton = iup.button{
   title = "Anrufe",
   font = fonts.button,
   expand = horizontal,
   tip = "Nächsten Inhalt sichtbar machen",
   action = function(self)
      if _content.valuepos == "1" then
	 _content.valuepos = "0"
	 self.title = "Anrufe"
      else
	 _content.valuepos = tostring(tonumber(_content.valuepos) + 1)
	 self.title = "Messwerte"
	 calls(true)
      end
   end
}

--------------------------------------------------------------------------------
-- List of computers to check
local computers = {
--   {dname = "fritzbox .... ", hname = "fritz.box"},
   {dname = "fritz7590 :", hname = "macbookpro", reqtype = "soap"},
   {dname = "macbookpro:", hname = "macbookpro.local", reqtype = "snmp"},
   {dname = "raspi 1   :", hname = "raspberrypi1", reqtype = "snmp"},
   {dname = "raspi 2   :", hname = "raspberrypi2", reqtype = "snmp"},
   {dname = "raspi 3   :", hname = "raspberrypi3", reqtype = "snmp"},
   {dname = "raspi 4   :", hname = "raspberrypi4", reqtype = "snmp"},
   {dname = "raspi 5   :", hname = "raspberrypi5", reqtype = "snmp"},
   {dname = "maclinux  :", hname = "maclinux", reqtype = "snmp"}
   
}

--------------------------------------------------------------------------------
-- Create an SNMP session for each computer
for _, v in ipairs(computers) do
   if v.reqtype == "snmp" then
      v.sess, err = snmp.open{peer = v.hname, retries = 1}
   end
end

--------------------------------------------------------------------------------
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
   weatherImages[v].resize = "32x32"
   forecastImages[v] = iup.LoadImage("/usr/local/share/luanagios/img/PNG/"..
				     weatherImageFiles[v])
   forecastImages[v].resize = "32x32"
end

-- SMB: do not use - NFS seems more stable
-- local wb_fname = "/mnt/pi4disk/dev/shm/mjpeg/cam.jpg"
-- NFS:
local wb_fname = "/net/nfs/mjpeg/cam.jpg"
local lwb_fname = "/mnt/mjpeg/cam.jpg"
--local lwb_fname = "/dev/shm/mjpeg/cam.jpg"

--------------------------------------------------------------------------------
-- URL for weather data
local fin = assert(io.open("/home/leuwer/.appid", "r"))
local appid = fin:read("*l")
local url = "http://api.openweathermap.org/data/2.5/onecall?lat=54.05&lon=10.08&lang=de&units=metric&appid="..appid
local url_ = "http://api.openweathermap.org/data/2.5/weather?lat=52.52&lon=13.41&lang=de&units=metric&appid=c3454c3a68e2abd6d7e86471b429686e"
fin:close()
log:debug("URL: " .. url)

--------------------------------------------------------------------------------
-- Copy webcam image to local ramdisk
-- @return none.
--------------------------------------------------------------------------------
local function _copyCam()
end

local function copyCam()
   local s
   local t0 = os.time()
   repeat
      --      local fi = assert(io.open(wb_fname,"rb"))
      local status, fi = pcall(io.open, wb_fname, "rb")
      if status == true then
	 status, s = pcall(fi.read, fi, "*a")
	 if status == true then
	    fi:close()
	 end
      end
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
   if vb and vb.value then
      log:debug(format("rechner_cb(): ok %s for rechner %q",
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

local function secs2date(secs)
   local days = math.floor(secs / 86400)
   local hours = math.floor(secs / 3600) - (days * 24)
   local minutes = math.floor(secs / 60) - (days * 1440) - (hours * 60)
   local seconds = secs % 60
   return {
      days = days, hours = hours, minutes = minutes, seconds = seconds
   }
end

local function router_cb(ns, meth, ent, soap_headers, body, magic)
   local r = secs2date(tonumber(ent[22][1]))
   computers[magic].label.title =
      format("%s %2d d %02d:%02d", computers[magic].dname,
	     r.days, r.hours, r.minutes, r.seconds)
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
      putStatus(format("  check rechner %q ...", computers[index].hname))
      if computers[index].reqtype == "snmp" then
	 local sess = computers[index].sess
	 if sess then
	    local ret, err = computers[index].sess:asynch_get("sysUpTime.0",
							      rechner_cb, index)
	 else
	    computers[index].label.title = computers[index].dname .. " down"
	 end
      elseif computers[index].reqtype == "soap" then
	 local user, pw = _USER, _PASSWORD
	 local request = {
	    soapaction = "urn:dslforum-org:service:DeviceInfo:1#GetInfo",
	    url = "http://"..user..":"..pw.."@fritz.box:49000/upnp/control/deviceinfo",
	    auth = "digest",
	    entries = {
	       tag = "u:GetInfo"
	    },
	    method = "GetInfo",
	    namespace = "urn:dslforum-org:service:DeviceInfo:1",
	    handler = router_cb,
	    opaque = index
	 }
	 local ns, meth, ent = soap_client.call(request)
      end
      return true
   else
      s = " wait ...     "
      computers[index].label = iup.label{
         font = fonts.list,
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
	 font = fonts.datum,
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
	 font = fonts.clock,
	 title = format("%02d:%02d:%02d", t.hour, t.min, t.sec)
      }
      return clock
   else
      log:debug("uhrzeit(): updating time ...")
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
      log:debug("temp_cb(): "..tostring(vb).." "..tostring(magic))
      log:debug(format("temp_cb(): %s for sensor %s", tostring(vb), tostring(magic)))
--      tempsens[magic].title = format("Temp %s: %+5.1f °C", tostring(magic), vb.value) 
      tempsens[magic].title = format("Temp %s: %8s °C", tostring(magic), vb.value) 
   else
      -- log error
      log:error(format("temp_cb() error %s", err or "???"))
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
	    font = fonts.temp,
	    title = format("Temp %d: wait ...          ", index)
	 }
      return tempsens[index]
   else
      putStatus(format("  check temperature %d ...", index))
      local ret, err = tempsess:asynch_get("extOutput."..index, temp_cb, index)
      return true
   end
end


--------------------------------------------------------------------------------
-- Get weather forecast data
-- @return table with weather forecast data
--------------------------------------------------------------------------------
local function getWeather()
   local res, err = asynchttp(url)
   return res
end

--------------------------------------------------------------------------------
-- Update weather in GUI.
-- @param t Table containing weather data.
-- @return none.
--------------------------------------------------------------------------------
local function updateWeather(t)
   log:debug(format("updateWeather(): updating weather: %s", pretty.write(t))) 
   weather.title = format("  %+3.1f °C - %d %% - %s",
			  t.current.temp, t.current.humidity,
			  t.current.weather[1].description)
   weatherimage.image = weatherImages[t.current.weather[1].icon]
--   log:debug(format("daily: %", pretty.write(t.daily)))
   for k, u in ipairs(t.daily) do
--      log:debug(format("k=%d u=%s", k, pretty.write(u,"")))
      if opt.weather.showPressure == true then
   	 forecast[k].title = format(" %s: %+5.1f °C %4d hPa - %s",
				    os.date("%d.%m", u.dt),
				    u.temp.day,
				    u.pressure,
				    u.weather[1].description)
	 log:debug(format("forecast %d %s", k, forecast[k].title))
      else
	 forecast[k].title = format(" %s: %+5.1f °C %5s %5s %s",
				    os.date("%d.%m", u.dt),
				    u.temp.day,
				    os.date("%H:%M", u.sunrise),
				    os.date("%H:%M", u.sunset),
				    u.weather[1].description)
	 log:debug(format("forecast %d %s", k, forecast[k].title))
      end
      forecastimage[k].image = forecastImages[u.weather[1].icon]
   end
end
--------------------------------------------------------------------------------
-- Weather data response handler.
-- @return none.
--------------------------------------------------------------------------------
local function weatherHandler(url)
   local t
   local res, err = asynchttp(url)
   log:debug(format("weatherHandler(): weather result received: json=%s err=%q", res, err))
   if res ~= nil then
      t = json.decode(res)
      log:debug(format("weatherHandler(): weather result decoded: lua=%s %s", pretty.write(t), tostring(t)))
      if t ~= nil then
	 updateWeather(t)
	 lastWeather = t
      end
   else
      log:error(format("weather request faild with %q", err))
   end
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
      log:debug(format("wetter(): launching weather request %s", url))
      local res, err = copas.addthread(weatherHandler, url)
      if not res then
	 log:error(format("wetter(): launching weather request failed with %q", err))
      end
      return true
   else
      weather = iup.label{
	 font = fonts.forecast,
	 expand = yes,
	 title = "  wait ...",
      }
      weatherimage = iup.label{
	 image = weatherImages["50d"],
      }
      local forecastcont = {}
      for i = 1, 8 do
	 forecast[i] = iup.label{
	    font = fonts.forecast,
	    expand = yes,
	    title = "  wait ...",
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
      log:debug("webcam(): updating webcam")
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
   font = fonts.button,
   expand = horizontal,
   tip = "Schalte Bildschirm dunkel und wieder hell",
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
	 font = fonts.status,
	 title = format("%5d", 0)
      }
      statscreen = iup.label{
	 font = fonts.status,
	 title = "---"
      }
      statgc = iup.label{
	 font = fonts.status,
	 title = "---- kB"
      }
      return iup.hbox{
	 gap = 10,
	 statscreen, statcount, statgc
      }
   else
      log:debug("status(): updating status")
      if os.time() - last_status_update > 5 then
	 putStatus("")
	 log:debug("status(): time:"..os.time())
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
      log:debug("kalender(): updating kalender")
      return true
   else
      cal = iup.calendar{
	 weeknumbers = yes,
	 font = fonts.kalender,
	 value = "TODAY",
	 bgcolor = "50 50 50"
      }
      return cal
   end
end

-------------------------------------------------------------------------------
-- Option check boxes
-------------------------------------------------------------------------------
local show_sunrise = iup.toggle{
   title = "Sonnenauf- u. Untergang",
   tip = "Zeige Sonnenaufgang und -untergang in Wettervorhersage",
   font = fonts.standard,
   flat = yes,
   action = function(v)
      opt.weather.showPressure = false
      opt.weather.togglePressure = false
      updateWeather(lastWeather)
   end
}
local show_pressure = iup.toggle{
   title = "Luftdruck",
   tip = "zeige Luftdurck in Wettervorhersage",
   font = fonts.standard,
   flat = yes,
   action = function(v)
      opt.weather.showPressure = true
      opt.weather.togglePressure = false
      updateWeather(lastWeather)
   end
}
local show_toggle = iup.toggle{
   title = "Wechsel",
   tip = "Wechsel zwischen Sonnenaufgang/-untergang und Luftdruck",
   font = fonts.standard,
   flat = yes,
   action = function(v)
      opt.weather.showPressure = false
      opt.weather.togglePressure = true
      updateWeather(lastWeather)
   end
}

-------------------------------------------------------------------------------
-- Create  Icon in upper left corner
-- @param which  "cal" for calendar, "lua" for Luanagios icon
-- @return flatfram with selected icon embedded.
-------------------------------------------------------------------------------
local function icon(which)
   local function _radio_selector()
      if opt.weather.togglePressure == true then
	 return show_toggle
      else
	 if opt.weather.showPressure == true then
	    return show_pressure
	 else
	    return show_sunrise
	 end
      end
   end
   icontab = iup.tabs{
      alignment = "CENTER",
      bgcolor = "52 57 59",
      font = fonts.standard,
      childoffset = "5x10",
      tabpadding = "5x5",
      iup.flatframe{
	 marginleft = 5,
	 margintop = 5,
	 kalender(false),
	 frame = no,
      },
      iup.flatframe{
	 webcam(false),
	 marginleft = 5,
	 margintop = 5,
	 frame = no,
      },
      iup.flatframe{
	 iup.vbox{
	    iup.radio{
	       iup.vbox{
		  show_sunrise,
		  show_pressure,
		  show_toggle
	       },
	       value = _radio_selector()
	    },
	    iup.button{
	       title = "Temperatur    ",
	       font = fonts.button,
--	       flat = yes,
	       size = "80x",
	       tip = "Rufe Temperatur ab",
	       action = function(self)
		  for i = 2, 4 do
		     tempsensor(i, true)
		  end
	       end
	    },
	    iup.button{
	       title = "Wetter abrufen",
	       font = fonts.button,
--	       flat = yes,
	       tip = "Rufe Wetter ab",
	       size = "80x",
	       action = function(self) wetter(true) end
	    },
	    iup.button{
	       title = "Prüfe Rechner ",
	       font = fonts.button,
--	       flat = yes,
	       size = "80x",
	       tip = "Prüfe alle Rechner",
	       action = function(self)
		  for i = 1, #computers do
		     rechner(i, true)
		  end
	       end
	    }
	 },
	 marginleft = 5,
	 margintop = 5,
	 frame = no
      },
      tabtitle0 = "Kalender",
      tabtitle1 = " Kamera ",
      tabtitle2 = "Options"
   }
   if which == "cal" then
      icontab.valuepos = 0
   elseif which == "cam" then
      icontab.valuepos = 1
   else
      icontab.valuepos = 3
   end
   return icontab
end

local function bookmark_dialog() end

-------------------------------------------------------------------------------
-- This is the main dialog
-------------------------------------------------------------------------------
local dlg = iup.dialog {
   rastersize = screensize,
   menubox = no,
   maxbox = no,
   minbox = no,
   resize = no,
   iup.vbox {
      content {
	 -- CONTENT 1: measurements
	 iup.vbox {
	    iup.hbox {
	       gap = HGAP,
	       iup.vbox {
		  gap = 3,
		  margin = "5x5",
		  icon("cam"),
		  iup.space{
		     size = "x5"
		  },
		  iup.label{font = fonts.list, titele = ""},
		  iup.label{font = fonts.list, title = "Computer:"},
		  rechner(1, false),
		  rechner(2, false),
		  rechner(3, false),
		  rechner(4, false),
		  rechner(5, false),
		  rechner(6, false),
		  rechner(7, false),
		  rechner(8, false),
	       },
	       iup.vbox {
		  gap = 5,
		  datum(false),
		  iup.hbox {
		     uhrzeit(false),
		     iup.space{size="x2", expand=yes},
		     iup.vbox {
			iup.space{size="x1", expand=yes},
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
	 },
	 -- CONTENT 2: call list
	 iup.vbox {
	    calls(false),
	 },
	 -- CONTENT 3: not used now
--	 iup.vbox {
--	    iup.label{
--	       title = "Content 3"
--	    }
--	 }
      },
      iup.vbox {
	 iup.hbox {
	    gap = 40,
	    iup.hbox {
	       screenButton,
	       contentButton,
	       iup.vbox {
		  gap = 0,
		  status(false),
		  iup.hbox{
		     statproc,
		     expand = yes
		  }
	       },
	       iup.button{
		  title = "Schließen",
		  font = fonts.button,
		  expand = horizontal,
		  tip = "Verlasse das Programm",
		  action = function(self) os.exit(0) end
	       }
	    }
	 },
	 iup.hbox {
	    margin = "x3"
	 }
      }
   }
}

-- show the dialog
dlg:show()

-------------------------------------------------------------------------------
-- Timer for triggering the updates -- every 500 ms
-------------------------------------------------------------------------------
local calTrig = 0
local timer = iup.timer{
   time = 500,
   action_cb = function(self)
      if false  then
	 return
      end
      -- 300 second interval - 5 minutes
      if update.rechner then
	 if cnt % (600) == 10 then
	    for i = 1, #computers do
	       rechner(i, true)
	    end
	 end
      end

      -- 600 second interval - 10  minutes
      if cnt % (1200) == 12 then
	 if update.wetter then
	    wetter(true)
	    mcnt = 1200
	 end
      end

      -- every 0.5 seconds: collect garbage
      collectgarbage("collect")

      -- 30 seconds update temperatures
      if update.tempsensor then
	 if cnt % 60 == 8 then
	    for i = 2, 4 do
	       tempsensor(i, true)
	    end
	 end
      end

      -- every 0.5 seconds: data, time, calendar, webcam, status
      local t = os.date("*t")
      if update.uhrzeit then
	 uhrzeit(true)
      end
      if update.datum then
	 datum(true)
      end
      if update.kalender then
      kalender(true)
      end
      if update.webcam then
	 webcam(true)
      end
      if update.status then
	 status(true)
      end
      cnt = cnt + 1
--      log:debug("counter: "..cnt)
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

      -- every 30 seconds: change between pressure and sunrise/sunset
      if cnt % 60 == 0 then
	 if opt.weather.togglePressure == true then
	    opt.weather.showPressure = not opt.weather.showPressure
	    if update.wetter then
	       updateWeather(lastWeather)
	    end
	 end
      end

      -- every minute: show calendar for 10 seconds
      if cnt % 120 == calTrig then
	 if opt.toggleWebcam == true and icontab.valuepos ~= "2" then
	    if calTrig == 0 then
	       icontab.valuepos = 0
	       calTrig = 20
	    else
	       icontab.valuepos = 1
	       calTrig = 0
	    end
	 end
      end
      
      -- update status
      sbutton.title = checkOnOff(screenButton, t)
      copas.step()
   end
}

-------------------------------------------------------------------------------
-- Timer for event hanlding - every 50 ms
-------------------------------------------------------------------------------
local timerSnmp = iup.timer{
   time = 50,
   action_cb = function(self)
      snmp.event()
      copas.step(0)
   end
}
timerSnmp.run = yes
timer.run = yes
--while true do
--   iup.LoopStep()
--   copas.step(0)
--end
iup.MainLoop()
