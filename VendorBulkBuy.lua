local ADDON_NAME = "VendorBulkBuy"
local DEFAULT_MAX_PIECES = 9999
local LARGE_PURCHASE_THRESHOLD = 20
local MAX_PURCHASES_PER_CALL = 255
local BUY_INTERVAL = 0.05
local AMOUNT_POPUP = "VENDOR_BULK_BUY_AMOUNT"
local CONFIRM_POPUP = "VENDOR_BULK_BUY_CONFIRM"

local frame = CreateFrame("Frame")
local originalOpenStackSplitFrame = nil

local pendingMerchantContext = nil
local pendingLargePurchase = nil
local purchaseQueue = nil
local timeUntilNextBuy = 0
local pendingTypedAmount = nil

local function Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. ADDON_NAME .. ":|r " .. message)
    end
end

local function IsMerchantBuyContext()
    return MerchantFrame and MerchantFrame:IsVisible() and MerchantFrame.selectedTab == 1
end

local function ResetState()
    pendingMerchantContext = nil
    pendingLargePurchase = nil
    purchaseQueue = nil
    timeUntilNextBuy = 0
    pendingTypedAmount = nil
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

local function GetExpandedMerchantMax(maxStack, parent)
    local merchantIndex
    local context

    if not IsMerchantBuyContext() then
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

    if context.numAvailable and context.numAvailable > 0 then
        return math.max(maxStack or 0, context.numAvailable * context.quantityPerPurchase)
    end

    return math.max(maxStack or 0, DEFAULT_MAX_PIECES * context.quantityPerPurchase)
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

local function StartMerchantPurchase(requestedPieces, context)
    local requestedPurchases
    local actualPurchases
    local actualPieces

    if not context then
        return
    end

    requestedPieces = math.floor(tonumber(requestedPieces) or 0)
    if requestedPieces < 1 then
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

    timeUntilNextBuy = 0
    ProcessPurchaseQueue()
end

local function PromptForPurchase(requestedPieces, context)
    if not requestedPieces or requestedPieces < 1 or not context then
        return
    end

    if requestedPieces > LARGE_PURCHASE_THRESHOLD then
        pendingLargePurchase = {
            requestedPieces = requestedPieces,
            context = context,
        }
        StaticPopupDialogs[CONFIRM_POPUP].text = "Buy " .. requestedPieces .. " " .. (context.itemName or "items") .. "?"
        StaticPopup_Show(CONFIRM_POPUP)
    else
        StartMerchantPurchase(requestedPieces, context)
    end
end

local function GetAmountPopupEditBox(popup)
    if not popup then
        return nil
    end

    return _G[popup:GetName() .. "EditBox"] or popup.editBox
end

StaticPopupDialogs[AMOUNT_POPUP] = {
    text = "",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 8,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
    OnShow = function()
        local popup = this
        local editBox = GetAmountPopupEditBox(popup)

        pendingTypedAmount = nil

        if editBox and editBox.SetNumeric then
            editBox:SetNumeric(true)
        end

    end,
    OnAccept = function()
        local popup = this
        local editBox = GetAmountPopupEditBox(popup)
        local requestedPieces = (editBox and tonumber(editBox:GetText())) or pendingTypedAmount or 0
        local context = (popup and popup.data) or pendingMerchantContext

        pendingMerchantContext = nil
        pendingTypedAmount = nil
        PromptForPurchase(requestedPieces, context)
    end,
    OnCancel = function()
        pendingMerchantContext = nil
        pendingTypedAmount = nil
    end,
    EditBoxOnEnterPressed = function()
        local popup = this:GetParent()
        local button1 = _G[popup:GetName() .. "Button1"]
        if button1 and button1:IsEnabled() then
            button1:Click()
        end
    end,
    EditBoxOnEscapePressed = function()
        this:GetParent():Hide()
    end,
    EditBoxOnTextChanged = function()
        local value = tonumber(this:GetText())
        if value and value > 0 then
            pendingTypedAmount = value
        elseif this:GetText() == "" then
            pendingTypedAmount = nil
        end
    end,
}

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
            StartMerchantPurchase(pendingLargePurchase.requestedPieces, pendingLargePurchase.context)
        end

        pendingLargePurchase = nil
    end,
    OnCancel = function()
        pendingLargePurchase = nil
    end,
}

local function HookMerchantQuantityPrompt()
    if originalOpenStackSplitFrame or not OpenStackSplitFrame then
        return
    end

    originalOpenStackSplitFrame = OpenStackSplitFrame

    OpenStackSplitFrame = function(maxStack, parent, anchor, anchorTo)
        local merchantIndex
        local context
        local expandedMax = GetExpandedMerchantMax(maxStack, parent)

        if not IsMerchantBuyContext() then
            return originalOpenStackSplitFrame(expandedMax, parent, anchor, anchorTo)
        end

        merchantIndex = GetMerchantIndexFromFrame(parent) or (this and this:GetID())
        if not merchantIndex then
            return originalOpenStackSplitFrame(expandedMax, parent, anchor, anchorTo)
        end

        context = GetMerchantItemContext(merchantIndex)
        if not context then
            return originalOpenStackSplitFrame(expandedMax, parent, anchor, anchorTo)
        end

        pendingMerchantContext = context
        StaticPopupDialogs[AMOUNT_POPUP].text = "How many " .. (context.itemName or "items") .. " do you want to buy?"

        local dialog = StaticPopup_Show(AMOUNT_POPUP)
        if dialog then
            dialog.data = context
            local editBox = GetAmountPopupEditBox(dialog)
            if editBox then
                editBox:SetText(tostring(context.quantityPerPurchase))
                editBox:HighlightText()
                editBox:SetFocus()
            end
        end

        if StackSplitFrame and StackSplitFrame:IsVisible() then
            StackSplitFrame:Hide()
        end
    end
end

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        HookMerchantQuantityPrompt()
        Print("loaded. Shift-click a vendor item to enter any amount.")
    elseif event == "MERCHANT_CLOSED" then
        ResetState()
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
frame:RegisterEvent("MERCHANT_CLOSED")