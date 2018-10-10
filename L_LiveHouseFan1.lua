-- module("L_LiveHouseFan1", package.seeall)
--
-- LiveHouse Fan Plugin
-- 
-- Control a 0-10V Qubino/GOAP Dimmer connected to a 3-stage Relay as if it was a 3 speed Fan interface
-- Supports detection/feedback updates to Vera if the Fan Speed (Potentiometer or 4 position rotary switch with fixed resistors) is adjusted at the wall or via UI
--
-- Created by Antony Winn
--
-- https://www.livehouseautomation.com.au
-- https://github.com/livehouse-automation
--
--

local FAN_SID = "urn:livehouse-automation:serviceId:LiveHouseFan1"
local SECURITY_SID = "urn:micasaverde-com:serviceId:SecuritySensor1"
local HADEVICE_SID = "urn:micasaverde-com:serviceId:HaDevice1"
local DIMMER_SID = "urn:upnp-org:serviceId:Dimming1"
local ZWAVE_SID = "urn:micasaverde-com:serviceId:ZWaveDevice1"

local DEBUG_MODE = 0
local POLLING_PERIOD = 120 -- number of seconds followup polling, 0 to disable

local OFF_LOWERLIMIT = 0
local OFF_UPPERLIMIT = 10
local OFF_TARGET = 0

local HIGH_LOWERLIMIT = 11
local HIGH_UPPERLIMIT = 50
local HIGH_TARGET = 30

local MED_LOWERLIMIT = 51
local MED_UPPERLIMIT = 79
local MED_TARGET = 65

local LOW_LOWERLIMIT = 80
local LOW_UPPERLIMIT = 100
local LOW_TARGET = 100

-- Defaults for the managed dimmer
local TRIPPED_STATUS = 1 		-- set to 1 causes a sync during startup.
local AUTO_UNTRIP = 3
local BASICSET = "00=T0,FF=T0"
local DIMMER_ID = 0				
local DEVICE_OPTIONS = "1-Input Type,1d,2,30-Save State,1d,1,141-I1 Reporting Threshold,1d,1,65-Dimming Time,2d,100"

local PARENT_DEVICE = 0


-------------------------------------------
-- Utility Functions
-------------------------------------------

local function infoLog(text)
	local id = PARENT_DEVICE or "unknown"
	luup.log("LiveHouseFan #" .. id .. " " .. text)
end

local function debugLog(text)
	if (DEBUG_MODE == "1") then
		infoLog("DEBUG " .. text)
	end
end

-- Get variable value and init if value is nil
function getVariableOrInit (lul_device, serviceId, variableName, defaultValue)
	local value = luup.variable_get(serviceId, variableName, lul_device)
		debugLog("Variable " .. variableName .. " = " .. tostring(value))
	if (value == nil) then
		debugLog("Setting default value for " .. variableName .. " to " .. defaultValue)
		luup.variable_set(serviceId, variableName, defaultValue, lul_device)
		value = defaultValue
	end
	return value
end

local function calculateFanStatus(dimmer_value)
	local fanSpeed
	dimmer_value = tonumber(dimmer_value)
	debugLog("calculateFanStatus function called.")
	if (dimmer_value >= tonumber(OFF_LOWERLIMIT) and dimmer_value <= tonumber(OFF_UPPERLIMIT)) then 
		fanSpeed = 0
		debugLog("calculateFanStatus: Fan Off")
	end
	if (dimmer_value >= tonumber(HIGH_LOWERLIMIT) and dimmer_value <= tonumber(HIGH_UPPERLIMIT)) then 
		fanSpeed = 1
		debugLog("calculateFanStatus: Fan High")
	end
	if (dimmer_value >= tonumber(MED_LOWERLIMIT) and dimmer_value <= tonumber(MED_UPPERLIMIT)) then 
		fanSpeed = 2
		debugLog("calculateFanStatus: Fan Med")
	end
	if (dimmer_value >= tonumber(LOW_LOWERLIMIT) and dimmer_value <= tonumber(LOW_UPPERLIMIT)) then 
		fanSpeed = 3
		debugLog("calculateFanStatus: Fan Low")
	end
	
	return fanSpeed
end

-- Update the UI Device state variable which updates the icon/button status
local function updateFanStatus(fanSpeed)	
	debugLog("Updating plugin FanLevelStatus variable")
	luup.variable_set(FAN_SID, "FanLevelStatus", fanSpeed, lul_device)
end

-- Set the managed dimmer target when Plugin Button is pressed
function setDimmerTargetValue(fanSpeed)
	debugLog("Setting Dimmer Target from Plugin. Button: " .. fanSpeed)
	local dimmerTargetValue
	fanSpeed = tonumber(fanSpeed)
	
	if fanSpeed == 0 then 
		dimmerTargetValue = OFF_TARGET 
		debugLog("Speed is OFF. Dimmer Target is " .. dimmerTargetValue)
	end
	if fanSpeed == 1 then 
		dimmerTargetValue = HIGH_TARGET 
		debugLog("Speed is HIGH. Dimmer Target is " .. dimmerTargetValue)
	end
	if fanSpeed == 2 then 
		dimmerTargetValue = MED_TARGET 
		debugLog("Speed is MED. Dimmer Target is " .. dimmerTargetValue)		
	end
	if fanSpeed == 3 then 
		dimmerTargetValue = LOW_TARGET 
		debugLog("Speed is LOW. Dimmer Target is " .. dimmerTargetValue)
	end
		
	luup.call_action(DIMMER_SID, "SetLoadLevelTarget", {["newLoadlevelTarget"] = tonumber(dimmerTargetValue)}, DIMMER_ID)
	updateFanStatus(fanSpeed)
end

-------------------------------------------
-- Callbacks
-------------------------------------------
--   * lul_device is a number that is the device ID
--   * lul_service is the service ID (string?)
--   * lul_variable is the variable name (string?)
--   * lul_value_old / lul_value_new are the values

function dimmerInputCallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)

	debugLog("dimmerInputCallback: Executing after Tripped status on Dimmer changed.")
	-- Poll the dimmer to see what new dimmer value is, after the dimmer Tripped status resets to FALSE
	if (lul_value_new == '0') then
		luup.call_action(HADEVICE_SID, "Poll", {}, DIMMER_ID)
		debugLog("dimmerInputCallback: Polling the Dimmer via Z-wave.")
		if (POLLING_PERIOD ~= 0) then
			-- setup a follow up check for POLLING_PERIOD seconds after everyone has stopped futzing with the knob
			debugLog("dimmerInputCallback: Scheduling follow up Poll in " .. POLLING_PERIOD .. " seconds")
			luup.call_delay("dimmerFollowUp", POLLING_PERIOD, DIMMER_ID)
		end
	end
end

function dimmerFollowUp(dimmerID)
	debugLog("Double check of Fan Control Dimmer value")
	luup.call_action(HADEVICE_SID, "Poll", {}, DIMMER_ID)
end
_G.dimmerFollowUp = dimmerFollowUp

function dimmerUICallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	local fanSpeed
	debugLog("dimmerUICallback: Executing after LoadLevelStatus on Dimmer changed from " .. lul_value_old .. " to " .. lul_value_new)
	-- call a function to determine the appropriate fan speed and set FanLevelStatus variable
	fanSpeed = calculateFanStatus(lul_value_new)
	updateFanStatus(fanSpeed)
end

-------------------------------------------
-- Startup
-------------------------------------------
-- Init plugin instance
function initPluginInstance(lul_device)
	-- Get debug mode
	DEBUG_MODE = getVariableOrInit(lul_device, FAN_SID, "Debug", DEBUG_MODE)
	
	PARENT_DEVICE = lul_device
	
	debugLog("initPluginInstance Function")
	
	OFF_LOWERLIMIT = getVariableOrInit(lul_device, FAN_SID, "OffLowerLimit", OFF_LOWERLIMIT)
	OFF_UPPERLIMIT = getVariableOrInit(lul_device, FAN_SID, "OffUpperLimit", OFF_UPPERLIMIT)
	OFF_TARGET = getVariableOrInit(lul_device, FAN_SID, "OffTarget", OFF_TARGET)

	HIGH_LOWERLIMIT = getVariableOrInit(lul_device, FAN_SID, "HighLowerLimit", HIGH_LOWERLIMIT)
	HIGH_UPPERLIMIT = getVariableOrInit(lul_device, FAN_SID, "HighUpperLimit", HIGH_UPPERLIMIT)
	HIGH_TARGET = getVariableOrInit(lul_device, FAN_SID, "HighTarget", HIGH_TARGET)

	MED_LOWERLIMIT = getVariableOrInit(lul_device, FAN_SID, "MedLowerLimit", MED_LOWERLIMIT)
	MED_UPPERLIMIT = getVariableOrInit(lul_device, FAN_SID, "MedUpperLimit", MED_UPPERLIMIT)
	MED_TARGET = getVariableOrInit(lul_device, FAN_SID, "MedTarget", MED_TARGET)
	
	LOW_LOWERLIMIT = getVariableOrInit(lul_device, FAN_SID, "LowLowerLimit", LOW_LOWERLIMIT)
	LOW_UPPERLIMIT = getVariableOrInit(lul_device, FAN_SID, "LowUpperLimit", LOW_UPPERLIMIT)
	LOW_TARGET = getVariableOrInit(lul_device, FAN_SID, "LowTarget", LOW_TARGET)

	DIMMER_ID = getVariableOrInit(lul_device, FAN_SID, "DimmerID", DIMMER_ID)
	DIMMER_ID = tonumber(DIMMER_ID)
	TRIPPED_STATUS = getVariableOrInit(lul_device, FAN_SID, "TrippedStatus", TRIPPED_STATUS)
	AUTO_UNTRIP = getVariableOrInit(lul_device, FAN_SID, "AutoUntrip", AUTO_UNTRIP)
	BASICSET = getVariableOrInit(lul_device, FAN_SID, "BasicSetCapabilities", BASICSET)
	DEVICE_OPTIONS = getVariableOrInit(lul_device, FAN_SID, "DeviceOptions", DEVICE_OPTIONS)
	
	-- For the managed dimmer, force the settings if a dimmer is not default value
	if (DIMMER_ID ~= 0) then
		debugLog("Dimmer ID found " .. DIMMER_ID)
		luup.variable_set(SECURITY_SID, "Tripped", TRIPPED_STATUS, DIMMER_ID)
		luup.variable_set(SECURITY_SID, "AutoUntrip", AUTO_UNTRIP, DIMMER_ID)
		luup.variable_set(ZWAVE_SID, "BasicSetCapabilities", BASICSET, DIMMER_ID)
		luup.variable_set(ZWAVE_SID, "VariablesSet", DEVICE_OPTIONS, DIMMER_ID)
	end
end

function startup(lul_device)
	infoLog("We are not gonna be great. We are not gonna be amazing. We are gonna be amazingly amazing!")
	-- Init
	initPluginInstance(lul_device)

	-- Watch the managed dimmer to see if it's been updated at the wall. 
	debugLog("Watching Tripped variable on " .. DIMMER_ID)
	luup.variable_watch("dimmerInputCallback", SECURITY_SID, "Tripped", DIMMER_ID)

	-- Watch the managed dimmer to see if it's been updated on the Vera UI
	debugLog("Watching LoadLevelStatus on " .. DIMMER_ID)
	luup.variable_watch("dimmerUICallback", DIMMER_SID, "LoadLevelStatus", DIMMER_ID)
	
	return true
end

