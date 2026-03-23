local ADDON_NAME = "VendorBulkBuy"
local DEFAULT_MAX_PURCHASES = 9999

local frame = CreateFrame("Frame")
local originalOpenStackSplitFrame = nil

local function Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON_NAME .. ":|r " .. message)
    end
end

local function IsMerchantBuyContext()
    return MerchantFrame and MerchantFrame:IsVisible() and MerchantFrame.selectedTab == 1
end

local function GetMerchantIndexFromFrame(frameObject)
    local current = frameObject
    local depth = 0

    while current and depth < 4 do
        if current.GetID then
            local id = current:GetID()
            if id and id > 0 and id <= GetMerchantNumItems() then
                return id
            end
        end

        if current.GetParent then
            current = current:GetParent()
        else
            current = nil
        end

        depth = depth + 1
    end
end

local function GetExpandedMerchantMax(maxStack, parent)
    local merchantIndex
    local _, _, _, quantityPerPurchase, numAvailable

    if not IsMerchantBuyContext() then
        return maxStack
    end

    merchantIndex = GetMerchantIndexFromFrame(parent) or (this and this:GetID())
    if not merchantIndex then
        return maxStack
    end

    _, _, _, quantityPerPurchase, numAvailable = GetMerchantItemInfo(merchantIndex)

    if not quantityPerPurchase or quantityPerPurchase < 1 then
        quantityPerPurchase = 1
    end

    if numAvailable and numAvailable > 0 then
        return math.max(maxStack or 0, numAvailable)
    end

    return math.max(maxStack or 0, DEFAULT_MAX_PURCHASES)
end

local function HookStackSplitFrame()
    if originalOpenStackSplitFrame or not OpenStackSplitFrame then
        return
    end

    originalOpenStackSplitFrame = OpenStackSplitFrame

    OpenStackSplitFrame = function(maxStack, parent, anchor, anchorTo)
        local expandedMax = GetExpandedMerchantMax(maxStack, parent)
        return originalOpenStackSplitFrame(expandedMax, parent, anchor, anchorTo)
    end
end

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        HookStackSplitFrame()
        Print("loaded. Use the normal vendor Shift-click quantity box for amounts over 20.")
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")