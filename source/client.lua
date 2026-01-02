-- PARAMETERS --
local SEARCH_STEP_SIZE                = 10.0
local SEARCH_MIN_DISTANCE             = 5.0
local SEARCH_MAX_DISTANCE             = 30.0
local SEARCH_RADIUS                   = 20.0
local HEADING_THRESHOLD               = 40.0
local TRAFFIC_LIGHT_POLL_FREQUENCY_MS = 50
local TRAFFIC_LIGHT_GREEN_DURATION_MS = 5000

-- When to consider doing another heavy scan for a NEW light
local RESCAN_DIST             = 5.0           -- meters
local RESCAN_DIST_SQR         = RESCAN_DIST * RESCAN_DIST
local RESCAN_HEADING_DEG      = 12.0          -- degrees
local SCAN_MIN_INTERVAL_MS    = 100           -- ms between heavy scans
local ACTIVE_REFRESH_MARGIN_MS = 1000         -- extend green if <1s left

local MIN_DIST_SQR = SEARCH_MIN_DISTANCE * SEARCH_MIN_DISTANCE
local MAX_DIST_SQR = SEARCH_MAX_DISTANCE * SEARCH_MAX_DISTANCE

-- Traffic light models
local trafficLightObjects = {
    0x3e2b73a4, -- prop_traffic_01a
    0x336e5e2a, -- prop_traffic_01b
    0xd8eba922, -- prop_traffic_01d
    0xd4729f50, -- prop_traffic_02a
    0x272244b2, -- prop_traffic_02b
    0x33986eae, -- prop_traffic_03a
    0x2323cdc5  -- prop_traffic_03b
}

-- Natives cached locally
local GetGameTimer           = GetGameTimer
local PlayerPedId            = PlayerPedId
local IsPedInAnyVehicle      = IsPedInAnyVehicle
local GetVehiclePedIsIn      = GetVehiclePedIsIn
local IsVehicleSirenOn       = IsVehicleSirenOn
local GetEntityCoords        = GetEntityCoords
local GetEntityHeading       = GetEntityHeading
local GetClosestObjectOfType = GetClosestObjectOfType
local DoesEntityExist        = DoesEntityExist
local Wait                   = Citizen.Wait

-- Timers table: [trafficLightEntity] = expireTimeMs
local trafficLightTimers = {}

-- Notification cooldown
local notificationCooldown = 5000
local lastNotificationTime = 0

-- Current active light we care about
local currentTrafficLight = 0

-- Scan history (for gating heavy scans)
local lastScanPos     = nil
local lastScanHeading = 0.0
local lastScanTime    = 0
local lastSirenOn     = false

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------

local function angleDiff(a, b)
    local d = math.abs(a - b)
    if d > 180.0 then d = 360.0 - d end
    return d
end

local function ShowNotification(text)
    local now = GetGameTimer()
    if now - lastNotificationTime > notificationCooldown then
        SetNotificationTextEntry("STRING")
        AddTextComponentString(text)
        DrawNotification(false, false)
        lastNotificationTime = now
    end
end

local function ResetTrafficLight(trafficLight)
    SetEntityTrafficlightOverride(trafficLight, -1)
    ShowNotification("Traffic light reset.")
    trafficLightTimers[trafficLight] = nil
end

-- Central lightweight timer manager (no SetTimeout spam)
Citizen.CreateThread(function()
    while true do
        local now = GetGameTimer()
        for trafficLight, expireAt in pairs(trafficLightTimers) do
            if not DoesEntityExist(trafficLight) or now >= expireAt then
                ResetTrafficLight(trafficLight)
            end
        end
        Wait(200) -- coarse is fine; we don't need ms-perfect expiry
    end
end)

local function SetTrafficLightGreen(trafficLight)
    local now = GetGameTimer()
    SetEntityTrafficlightOverride(trafficLight, 0)
    -- extend / set the expiry
    trafficLightTimers[trafficLight] = now + TRAFFIC_LIGHT_GREEN_DURATION_MS
    ShowNotification("Traffic light set to green.")
end

local function BroadcastTrafficLightChange(trafficLight, isGreen)
    TriggerServerEvent('trafficlights:syncTrafficLight', trafficLight, isGreen)
end

-- Do we really need another heavy scan right now?
local function shouldHeavyScan(playerPos, playerHeading, now)
    if not lastScanPos then
        return true
    end

    if now - lastScanTime < SCAN_MIN_INTERVAL_MS then
        return false
    end

    local dx = playerPos.x - lastScanPos.x
    local dy = playerPos.y - lastScanPos.y
    local dz = playerPos.z - lastScanPos.z
    local distSqr = dx * dx + dy * dy + dz * dz

    if distSqr >= RESCAN_DIST_SQR then
        return true
    end

    if angleDiff(playerHeading, lastScanHeading) >= RESCAN_HEADING_DEG then
        return true
    end

    return false
end

-- Is the cached light still the one in front of us?
local function isLightStillRelevant(light, playerPos, playerHeading)
    if light == 0 or not DoesEntityExist(light) then
        return false
    end

    local lp = GetEntityCoords(light)
    local dx = lp.x - playerPos.x
    local dy = lp.y - playerPos.y
    local dz = lp.z - playerPos.z
    local distSqr = dx * dx + dy * dy + dz * dz

    if distSqr < MIN_DIST_SQR or distSqr > MAX_DIST_SQR then
        return false
    end

    local lightHeading = GetEntityHeading(light)
    local diff = angleDiff(playerHeading, lightHeading)
    if diff >= HEADING_THRESHOLD then
        return false
    end

    return true
end

-- Heavy scan: same 30/20/10 search pattern as original
local function findTrafficLightAhead(playerPos, playerHeading)
    local headingRad = math.rad(playerHeading)
    local sinH       = math.sin(headingRad)
    local cosH       = math.cos(headingRad)

    for searchDistance = SEARCH_MAX_DISTANCE, SEARCH_MIN_DISTANCE, -SEARCH_STEP_SIZE do
        local searchPos = vector3(
            playerPos.x - searchDistance * sinH,
            playerPos.y + searchDistance * cosH,
            playerPos.z
        )

        for i = 1, #trafficLightObjects do
            local model = trafficLightObjects[i]

            local foundLight = GetClosestObjectOfType(
                searchPos,
                SEARCH_RADIUS,
                model,
                false, false, false
            )

            if foundLight ~= 0 then
                local lightHeading = GetEntityHeading(foundLight)
                local diff         = angleDiff(playerHeading, lightHeading)

                if diff < HEADING_THRESHOLD then
                    return foundLight
                end
            end
        end
    end

    return 0
end

-- kept for compatibility if something else uses it
function translateVector3(pos, angle, distance)
    local angleRad = angle * 2.0 * math.pi / 360.0
    return vector3(
        pos.x - distance * math.sin(angleRad),
        pos.y + distance * math.cos(angleRad),
        pos.z
    )
end

---------------------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------------------

Citizen.CreateThread(function()
    while true do
        local playerPed = PlayerPedId()

        if IsPedInAnyVehicle(playerPed, false) then
            local vehicle = GetVehiclePedIsIn(playerPed, false)
            local sirenOn = IsVehicleSirenOn(vehicle)

            if sirenOn then
                local now          = GetGameTimer()
                local playerPos    = GetEntityCoords(playerPed)
                local playerHeading = GetEntityHeading(playerPed)

                -- Force fresh scan when turning siren on
                if not lastSirenOn then
                    lastSirenOn        = true
                    currentTrafficLight = 0
                    lastScanPos         = nil
                end

                -- 1) If we already have a valid light, keep it green with almost no cost
                if currentTrafficLight ~= 0 and isLightStillRelevant(currentTrafficLight, playerPos, playerHeading) then
                    local expiresAt = trafficLightTimers[currentTrafficLight]
                    if not expiresAt or (expiresAt - now) <= ACTIVE_REFRESH_MARGIN_MS then
                        SetTrafficLightGreen(currentTrafficLight)
                        BroadcastTrafficLightChange(currentTrafficLight, true)
                    end

                    Wait(TRAFFIC_LIGHT_POLL_FREQUENCY_MS)
                else
                    -- Need to find a (new) light
                    currentTrafficLight = 0

                    if shouldHeavyScan(playerPos, playerHeading, now) then
                        lastScanPos     = playerPos
                        lastScanHeading = playerHeading
                        lastScanTime    = now

                        local found = findTrafficLightAhead(playerPos, playerHeading)
                        if found ~= 0 then
                            currentTrafficLight = found
                            SetTrafficLightGreen(found)
                            BroadcastTrafficLightChange(found, true)
                        end
                    end

                    Wait(TRAFFIC_LIGHT_POLL_FREQUENCY_MS)
                end
            else
                -- Siren off
                lastSirenOn        = false
                currentTrafficLight = 0
                Wait(1000)
            end
        else
            -- Not in vehicle
            lastSirenOn        = false
            currentTrafficLight = 0
            Wait(1000)
        end
    end
end)
