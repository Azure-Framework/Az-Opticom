RegisterNetEvent('trafficlights:syncTrafficLight')
AddEventHandler('trafficlights:syncTrafficLight', function(trafficLight, isGreen)
    TriggerClientEvent('trafficlights:updateTrafficLight', -1, trafficLight, isGreen)
end)
