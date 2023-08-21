-- Copyright (c) 2023 Paul Osborne
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- TODO: Ambient Light
-- TODO: Temp/Humidity Not Working

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local zigbee_defaults = require "st.zigbee.defaults"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local device_management = require "st.zigbee.device_management"
local utils = require "st.utils"

local IKEA_MANUF_ID = 0x117C

local FAN_SPEED_IKEA_TO_ST_MAPPING = {
    [0] = 0,
    [10] = 1,
    [20] = 2,
    [30] = 3,
    [40] = 3,
    [50] = 4,
}

local FAN_SPEED_ST_TO_IKEA_MAPPING = {
    [0] = 0,
    [1] = 10,
    [2] = 20,
    [3] = 30,
    [4] = 50,
}

-- This is based on https://www.samsung.com/au/support/home-appliances/have-cleaner-air-with-the-samsung-air-purifier/
local PM25_UPPER_BOUNDS_TO_HEALTH_CONCERN = {
    { upper_bound = 15, value = "good" },
    { upper_bound = 35, value = "moderate" },
    { upper_bound = 75, value = "slightlyUnhealthy"},
    { upper_bound = 200, value = "unhealthy" },
    { upper_bound = 0xFFFF, value = "hazardous" },
}

local IkeaAirPurifierMfrSpecificCluster = {
    ID = 0xFC7D,
    attributes = {
        FilterRunTime = {
            ID = 0x0000,
            NAME = "FilterRunTime",
            base_type = data_types.Uint32,
        },
        ReplaceFilter = {
            ID = 0x0001,
            NAME = "ReplaceFilter",
            base_type = data_types.Uint8,
        },
        FilterLifeTime = {
            ID = 0x0002,
            NAME = "FilterLifeTime",
            base_type = data_types.Uint32,
        },
        ControlPanelLight = {
            ID = 0x0003,
            NAME = "DisabledLed",
            base_type = data_types.Boolean,
        },
        ParticularMatter25Measurement = {
            ID = 0x0004,
            NAME = "ParticularMatter25Measurement",
            base_type = data_types.Uint16,
        },
        ChildLock = {
            ID = 0x0005,
            NAME = "ChildLock",
            base_type = data_types.Boolean,
        },
        FanMode = {
            ID = 0x0006,
            NAME = "FanMode",
            -- RW: Off=0, Auto=1, Speed 10 - 50
            base_type = data_types.Uint8,
        },
        FanSpeed = {
            ID = 0x0007,
            NAME = "FanSpeed",
            -- RO: Current Fan Speed (10-50)
            base_type = data_types.Uint8,
        },
        DeviceRunTime = {
            ID = 0x0008,
            NAME = "DeviceRunTime",
            base_type = data_types.Uint32
        },
    }
}

local function handle_capability_command_set_fan_speed(driver, device, command)
    -- we write the desired level using the ikea "mode" parameter which is:
    -- Off = 0
    -- Auto = 1
    -- 10-50 is on between level 1 and 5 on the device
    local ikea_fan_speed = FAN_SPEED_ST_TO_IKEA_MAPPING[command.args.speed]

    device:send(cluster_base.write_manufacturer_specific_attribute(
        device,
        IkeaAirPurifierMfrSpecificCluster.ID,
        IkeaAirPurifierMfrSpecificCluster.attributes.FanMode.ID,
        IKEA_MANUF_ID,
        IkeaAirPurifierMfrSpecificCluster.attributes.FanMode.base_type,
        ikea_fan_speed
    ))
end

local function handle_zbattr_fan_mode(driver, device, value)
    print(string.format("Got Fan Mode Change: %s", value))
end

local function handle_zbattr_fan_speed(driver, device, value)
    -- Setting 1: 0x0A (10)
    -- Setting 2: 0x14 (20)
    -- Setting 3: 0x1E (30)
    -- Setting 4: 0x28 (40)
    -- Setting 5: 0x32 (50)
    -- The SmartThings fanSpeed capability supports 0-4 speeds so we'll
    -- just do 0 -> 0, 10 -> 1, 20 -> 2, 30,40 -> 3, 50 -> 4
    print(utils.stringify_table(value, "value", true))
    local attr_value = FAN_SPEED_IKEA_TO_ST_MAPPING[value.value]
    device:emit_event(capabilities.fanSpeed.fanSpeed(attr_value))
end

local function handle_zbattr_pm25(driver, device, value)
    print(string.format("Got PM25 Change: %s", value))

    -- this isn't directly documented but based on IKEA app, the values
    -- we see in the cluster seem to be micro-grams per cubic meter
    -- without additional conversion required.
    local pm25_ug_m3 = value.value

    -- sometimes the devices sends 0xFFFF for the attribute which appears
    -- to just indicate that the sensor isn't ready, ignore.
    if pm25_ug_m3 >= 0xFFFF then
        return
    end

    local health_concern = "unhealthy"
    for _, candidate in ipairs(PM25_UPPER_BOUNDS_TO_HEALTH_CONCERN) do
        if pm25_ug_m3 < candidate.upper_bound then
            health_concern = candidate.value
            break
        end
    end

    device:emit_event(capabilities.fineDustSensor.fineDustLevel(pm25_ug_m3))
    device:emit_event(capabilities.fineDustHealthConcern.fineDustHealthConcern(health_concern))
end

local function handle_zbattr_filter_life_time(driver, device, value)
    print(string.format("Got Filter Life Change: %s", value))
end

local ikea_air_driver_template = {
    supported_capabilities = {
        -- Uses standard clusters
        capabilities.relativeHumidityMeasurement,
        capabilities.temperatureMeasurement,

        -- Uses manufacturer specific profiles
        capabilities.fineDustSensor,
        capabilities.fineDustHealthConcern,
        capabilities.fanSpeed,
        capabilities.filterState,
    },
    zigbee_handlers = {
        global = {},
        cluster = {},
        attr = {
            [IkeaAirPurifierMfrSpecificCluster.ID] = {
                [IkeaAirPurifierMfrSpecificCluster.attributes.FanMode.ID] = handle_zbattr_fan_mode,
                [IkeaAirPurifierMfrSpecificCluster.attributes.FanSpeed.ID] = handle_zbattr_fan_speed,
                [IkeaAirPurifierMfrSpecificCluster.attributes.ParticularMatter25Measurement.ID] = handle_zbattr_pm25,
                [IkeaAirPurifierMfrSpecificCluster.attributes.FilterLifeTime.ID] = handle_zbattr_filter_life_time,
            }
        }
    },
    cluster_configurations = {
        [capabilities.fineDustSensor.ID] = {
            {
                cluster = IkeaAirPurifierMfrSpecificCluster.ID,
                attribute = IkeaAirPurifierMfrSpecificCluster.attributes.ParticularMatter25Measurement.ID,
                minimum_interval = 0,
                maximum_interval = 5 * 60,
                reportable_change = 1,
                data_type = IkeaAirPurifierMfrSpecificCluster.attributes.ParticularMatter25Measurement.base_type,
                mfg_code = IKEA_MANUF_ID,
            }
        },
        [capabilities.fanSpeed.ID] = {
            {
                cluster = IkeaAirPurifierMfrSpecificCluster.ID,
                attribute = IkeaAirPurifierMfrSpecificCluster.attributes.FanSpeed.ID,
                minimum_interval = 0,
                maximum_interval = 5 * 60,
                reportable_change = 1,
                data_type = IkeaAirPurifierMfrSpecificCluster.attributes.FanSpeed.base_type,
                mfg_code = IKEA_MANUF_ID,
            },
        },
        [capabilities.filterState.ID] = {
            {
                cluster = IkeaAirPurifierMfrSpecificCluster.ID,
                attribute = IkeaAirPurifierMfrSpecificCluster.attributes.FilterLifeTime.ID,
                minimum_interval = 60,
                maximum_interval = 60 * 60,
                reportable_change = 1,
                data_type = IkeaAirPurifierMfrSpecificCluster.attributes.FilterLifeTime.base_type,
                mfg_code = IKEA_MANUF_ID,
            }
        },
    },
    capability_handlers = {
        [capabilities.fanSpeed.ID] = {
            [capabilities.fanSpeed.commands.setFanSpeed.NAME] = handle_capability_command_set_fan_speed,
        }
        -- maybe add switch to control fan off or on(level) or auto.
        -- maybe add custom cap. for child lock, led control, etc.
    },
}
zigbee_defaults.register_for_default_handlers(ikea_air_driver_template, ikea_air_driver_template.supported_capabilities)
local ikea_air_driver = ZigbeeDriver("ikea-air", ikea_air_driver_template)
ikea_air_driver:run()
