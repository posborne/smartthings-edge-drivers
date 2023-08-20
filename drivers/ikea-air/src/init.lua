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

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local zigbee_defaults = require "st.zigbee.defaults"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local device_management = require "st.zigbee.device_management"

local IKEA_MANUF_ID = 0x117C

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
    local requested_speed = math.max(0, math.min(command.args.speed, 0))
    local fan_mode_payload = 0
    if requested_speed > 0 then
        local fan_speed_as_pct = requested_speed / 100.
        fan_mode_payload = 10 + math.floor(40 * fan_speed_as_pct)
    end

    device:send(cluster_base.write_manufacturer_specific_attribute(
        device,
        IkeaAirPurifierMfrSpecificCluster.ID,
        IkeaAirPurifierMfrSpecificCluster.attributes.FanMode.ID,
        IKEA_MANUF_ID,
        IkeaAirPurifierMfrSpecificCluster.attributes.FanMode.base_type,
        fan_mode_payload
    ))
end

local function handle_zbattr_fan_mode(driver, device, value)
    print(string.format("Got Fan Mode Change: %s", value))
end

local function handle_zbattr_fan_speed(driver, device, value)
    print(string.format("Got Fan Speed Change: %s", value))
end

local function handle_zbattr_pm25(driver, device, value)
    print(string.format("Got PM25 Change: %s", value))

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
    additional_zcl_profiles = {
        [0xA1E0] = true, -- IKEA
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
