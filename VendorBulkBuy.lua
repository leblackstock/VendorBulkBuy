local ADDON_NAME = "VendorBulkBuy"
local DEFAULT_MAX_PIECES = 9999
local LARGE_PURCHASE_THRESHOLD = 255
local MAX_PURCHASES_PER_CALL = 255
local BUY_INTERVAL = 0.05
local CONFIRM_POPUP = "VENDOR_BULK_BUY_CONFIRM"
local DIAGNOSTIC = false

local frame = CreateFrame("Frame")
local originalOpenStackSplitFrame = nil
local originalStackSplitOkayOnClick = nil
local originalStackSplitTextOnEnterPressed = nil
local originalStackSplitInputBoxOnEnterPressed = nil
local originalStackSplitEditBoxOnEnterPressed = nil
local originalStackSplitOkayFunction = nil

local splitContext = nil
local pendingLargePurchase = nil
local purchaseQueue = nil
local timeUntilNextBuy = 0
local typedSplitAmount = nil

local function Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON_NAME .. ":|r " .. message)
    end
end

local function Debug(message)
    if DIAGNOSTIC then
        Print("diag: " .. message)
    end
end

local function IsMerchantBuyContext()
    return MerchantFrame and MerchantFrame:IsVisible() and MerchantFrame.selectedTab == 1
end

local function ResetMerchantState()
    splitContext = nil
    pendingLargePurchase = nil
    purchaseQueue = nil
    timeUntilNextBuy = 0
    typedSplitAmount = nil
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

local function GetMerchantItemContext(merchantIndex)
    local itemName, _, _, quantityPerPurchase, numAvailable = GetMerchantItemInfo(merchantIndex)

    if not itemName then
        return nil
    end

    if not quantityPerPurchase or quantityPerPurchase < 1 then
        quantityPerPurchase = 1
    end

    return {
        merchantIndex = merchantIndex,
        itemName = itemName,
        quantityPerPurchase = quantityPerPurchase,
        numAvailable = numAvailable,
    }
end

local function DescribeField(fieldName)
    local field = _G[fieldName]

    if not field then
        return fieldName .. "=nil"
    end

    return fieldName
        .. ":text=" .. tostring(field.GetText and field:GetText() or nil)
        .. ",getscript=" .. tostring(type(field.GetScript) == "function")
        .. ",setscript=" .. tostring(type(field.SetScript) == "function")
        .. ",hookscript=" .. tostring(type(field.HookScript) == "function")
end

local function GetExpandedMerchantMax(maxStack, parent)
    local merchantIndex
    local context

    if not IsMerchantBuyContext() then
        splitContext = nil
        return maxStack
    end

    merchantIndex = GetMerchantIndexFromFrame(parent) or (this and this:GetID())
    if not merchantIndex then
        return maxStack
    end

    context = GetMerchantItemContext(merchantIndex)
    if not context then
        return maxStack
    end

    splitContext = context

    if context.numAvailable and context.numAvailable > 0 then
        return math.max(maxStack or 0, context.numAvailable * context.quantityPerPurchase)
    end

    return math.max(maxStack or 0, DEFAULT_MAX_PIECES * context.quantityPerPurchase)
end

local function HookStackSplitFrame()
    if originalOpenStackSplitFrame or not OpenStackSplitFrame then
        return
    end

    originalOpenStackSplitFrame = OpenStackSplitFrame

    OpenStackSplitFrame = function(maxStack, parent, anchor, anchorTo)
        local expandedMax = GetExpandedMerchantMax(maxStack, parent)

        if splitContext then
            Debug(
                "OpenStackSplitFrame item=" .. tostring(splitContext.itemName)
                .. ", max=" .. tostring(maxStack)
                .. ", expanded=" .. tostring(expandedMax)
                .. ", " .. DescribeField("StackSplitText")
                .. ", " .. DescribeField("StackSplitInputBox")
                .. ", " .. DescribeField("StackSplitEditBox")
                .. ", okayButton=" .. tostring(_G.StackSplitOkayButton ~= nil)
                .. ", okayFn=" .. tostring(type(StackSplitOkayButton_OnClick) == "function")
            )
        end

        return originalOpenStackSplitFrame(expandedMax, parent, anchor, anchorTo)
    end
end

local function GetStackSplitValue()
    local value
    local fieldNames = {
        "StackSplitText",
        "StackSplitInputBox",
        "StackSplitEditBox",
    }
    local i

    if typedSplitAmount and typedSplitAmount > 0 then
        return typedSplitAmount
    end

    if StackSplitFrame and StackSplitFrame.split then
        value = tonumber(StackSplitFrame.split)
        if value and value > 0 then
            return value
        end
    end

    for i = 1, table.getn(fieldNames) do
        local field = _G[fieldNames[i]]
        if field and field.GetText then
            value = tonumber(field:GetText())
            if value and value > 0 then
                return value
            end
        end
    end
end

local function UpdateTypedSplitAmountFromField(field)
    local value

    if field and field.GetText then
        value = tonumber(field:GetText())
        if value and value > 0 then
            typedSplitAmount = value
            return value
        end
    end
end

local function CloseMerchantStackSplit()
    if CloseStackSplitFrame then
        CloseStackSplitFrame()
    elseif StackSplitFrame then
        StackSplitFrame:Hide()
    end
end

local function ProcessPurchaseQueue()
    local chunk

    if not purchaseQueue then
        return
    end

    if not IsMerchantBuyContext() then
        purchaseQueue = nil
        return
    end

    chunk = math.min(purchaseQueue.remainingPurchases, MAX_PURCHASES_PER_CALL)
    if chunk < 1 then
        purchaseQueue = nil
        return
    end

    BuyMerchantItem(purchaseQueue.merchantIndex, chunk)
    purchaseQueue.remainingPurchases = purchaseQueue.remainingPurchases - chunk

    if purchaseQueue.remainingPurchases <= 0 then
        purchaseQueue = nil
    end
end

local function StartLargeMerchantPurchase(requestedPieces, context)
    local requestedPurchases
    local actualPurchases
    local actualPieces

    if not context then
        return
    end

    requestedPurchases = math.ceil(requestedPieces / context.quantityPerPurchase)
    actualPurchases = requestedPurchases

    if context.numAvailable and context.numAvailable > 0 and actualPurchases > context.numAvailable then
        actualPurchases = context.numAvailable
    end

    if actualPurchases < 1 then
        return
    end

    actualPieces = actualPurchases * context.quantityPerPurchase

    if actualPieces ~= requestedPieces and context.itemName then
        Print("buying " .. actualPieces .. " " .. context.itemName .. " (sold in packs of " .. context.quantityPerPurchase .. ").")
    end

    purchaseQueue = {
        merchantIndex = context.merchantIndex,
        remainingPurchases = actualPurchases,
    }

    typedSplitAmount = nil
    timeUntilNextBuy = 0
    ProcessPurchaseQueue()
end

local function TryHandleLargePurchase()
    local requestedPieces

    if not (splitContext and IsMerchantBuyContext()) then
        return false
    end

    requestedPieces = GetStackSplitValue()

    if requestedPieces and requestedPieces > LARGE_PURCHASE_THRESHOLD then
        pendingLargePurchase = {
            requestedPieces = requestedPieces,
            context = {
                merchantIndex = splitContext.merchantIndex,
                itemName = splitContext.itemName,
                quantityPerPurchase = splitContext.quantityPerPurchase,
                numAvailable = splitContext.numAvailable,
            },
        }

        StaticPopupDialogs[CONFIRM_POPUP].text = "Buy " .. requestedPieces .. " " .. (splitContext.itemName or "items") .. "?"
        CloseMerchantStackSplit()
        StaticPopup_Show(CONFIRM_POPUP)
        return true
    end

    return false
end

StaticPopupDialogs[CONFIRM_POPUP] = {
    text = "",
    button1 = ACCEPT,
    button2 = CANCEL,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
    OnAccept = function()
        if pendingLargePurchase and pendingLargePurchase.context then
            StartLargeMerchantPurchase(pendingLargePurchase.requestedPieces, pendingLargePurchase.context)
        end

        pendingLargePurchase = nil
    end,
    OnCancel = function()
        pendingLargePurchase = nil
    end,
}

local function HookStackSplitOkayButton()
    if originalStackSplitOkayOnClick or not StackSplitOkayButton then
        Debug("HookStackSplitOkayButton skipped: button=" .. tostring(StackSplitOkayButton ~= nil) .. ", already=" .. tostring(originalStackSplitOkayOnClick ~= nil))
        return
    end

    originalStackSplitOkayOnClick = StackSplitOkayButton:GetScript("OnClick")
    if not originalStackSplitOkayOnClick then
        Debug("HookStackSplitOkayButton found button but no OnClick script")
        return
    end

    Debug("HookStackSplitOkayButton attached")

    StackSplitOkayButton:SetScript("OnClick", function()
        if TryHandleLargePurchase() then
            return
        end

        return originalStackSplitOkayOnClick()
    end)
end

local function HookStackSplitEnterHandlers()
    local function HookField(fieldName, originalStoreName)
        local field = _G[fieldName]
        local originalScript

        if not field or field.VendorBulkBuyEnterHooked or type(field.GetScript) ~= "function" or type(field.SetScript) ~= "function" then
            Debug("HookField skipped for " .. fieldName .. ": exists=" .. tostring(field ~= nil) .. ", hooked=" .. tostring(field and field.VendorBulkBuyEnterHooked or false) .. ", getscript=" .. tostring(field and type(field.GetScript) == "function" or false) .. ", setscript=" .. tostring(field and type(field.SetScript) == "function" or false))
            return
        end

        originalScript = field:GetScript("OnEnterPressed")
        if not originalScript then
            Debug("HookField no OnEnterPressed for " .. fieldName)
            return
        end

        Debug("HookField attached for " .. fieldName)

        field.VendorBulkBuyEnterHooked = true

        if originalStoreName == "text" then
            originalStackSplitTextOnEnterPressed = originalScript
        elseif originalStoreName == "input" then
            originalStackSplitInputBoxOnEnterPressed = originalScript
        elseif originalStoreName == "edit" then
            originalStackSplitEditBoxOnEnterPressed = originalScript
        end

        field:SetScript("OnEnterPressed", function()
            UpdateTypedSplitAmountFromField(this)
            if TryHandleLargePurchase() then
                return
            end

            return originalScript()
        end)

        if not field.VendorBulkBuyTextChangedHooked and type(field.HookScript) == "function" then
            field.VendorBulkBuyTextChangedHooked = true
            field:HookScript("OnTextChanged", function()
                UpdateTypedSplitAmountFromField(this)
            end)
        end
    end

    HookField("StackSplitText", "text")
    HookField("StackSplitInputBox", "input")
    HookField("StackSplitEditBox", "edit")
end

local function HookStackSplitOkayFunction()
    if originalStackSplitOkayFunction or not StackSplitOkayButton_OnClick then
        Debug("HookStackSplitOkayFunction skipped: fn=" .. tostring(type(StackSplitOkayButton_OnClick) == "function") .. ", already=" .. tostring(originalStackSplitOkayFunction ~= nil))
        return
    end

    originalStackSplitOkayFunction = StackSplitOkayButton_OnClick
    Debug("HookStackSplitOkayFunction attached")
    StackSplitOkayButton_OnClick = function()
        if TryHandleLargePurchase() then
            return
        end

        return originalStackSplitOkayFunction()
    end
end

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        HookStackSplitFrame()
        HookStackSplitOkayButton()
        HookStackSplitEnterHandlers()
        HookStackSplitOkayFunction()
        Print("loaded. Use the normal vendor Shift-click quantity box for amounts over 20.")
    elseif event == "MERCHANT_SHOW" then
        HookStackSplitOkayButton()
        HookStackSplitEnterHandlers()
        HookStackSplitOkayFunction()
    elseif event == "MERCHANT_CLOSED" then
        ResetMerchantState()
    end
end)

frame:SetScript("OnUpdate", function()
    if not purchaseQueue then
        return
    end

    timeUntilNextBuy = timeUntilNextBuy - arg1
    if timeUntilNextBuy <= 0 then
        timeUntilNextBuy = BUY_INTERVAL
        ProcessPurchaseQueue()
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")