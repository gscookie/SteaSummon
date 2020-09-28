local addonName, addonData = ...

local cw_spells = {} -- current summon spells being cast, module level because accessed in a callback
local g_self -- for callbacks

local summon = {
  waiting = {}, -- the summon list
  numwaiting = 0, -- the summon list length
  hasSummoned = false, -- when true we believe you more
  tainted = false, -- indicates player has cancelled something that's nothing to do with them
  myLocation = "", -- the location player is
  myZone = "", -- the zone player is
  location = "", -- area of zone summons are going to
  zone = "", -- the zone summons are going to
  summoningPlayer = "", -- the player currently being summoned
  shards = 0, -- the number of shards in our bag
  isWarlock = false,
  infoSend = false,

  ---------------------------------
  init = function(self)
    addonData.debug:registerCategory("summon.display")
    addonData.debug:registerCategory("summon.waitlist.record")
    addonData.debug:registerCategory("summon.tick")
    addonData.debug:registerCategory("summon.misc")
    addonData.debug:registerCategory("summon.spellcast")

    self.isWarlock = addonData.util:playerIsWarlock()

    self.waiting = SteaSummonSave.waiting
    if not IsInGroup() or (SteaSummonSave.timeStamp - GetTime() > SteaSummonSave.waitingKeepTime * 60) then
      wipe(self.waiting)
    end
  end,

  ---------------------------------
  waitRecord = function(self, player, time, status, prioReason)
    local rec
    rec = {player, time, status, prioReason}
    db("summon.waitlist.record","Created record {",
        self:recPlayer(rec), self:recTime(rec), self:recStatus(rec), self:recPrio(rec), "}")

    return rec
  end,

  ---------------------------------
  recPlayer = function(self, rec, val)
    if val then
      db("summon.waitlist.record","setting record player value:", val)
      rec[1] = val
    end
    return rec[1]
  end,

  ---------------------------------
  recTime = function(self, rec, val)
    if val then
      db("summon.waitlist.record","setting record time value:", val)
      rec[2] = val
    end
    return rec[2]
  end,

  ---------------------------------
  recTimeIncr = function(self, rec)
    rec[2] = rec[2] + 1
    db("summon.tick","setting record time value:", rec[2]) -- too verbose for summon.waitlist.record
    return rec[2]
  end,

  ---------------------------------
  recStatus = function(self, rec, val)
    if val then
      db("summon.waitlist.record","setting record status value:", val)
      rec[3] = val
    end
    return rec[3]
  end,

  ---------------------------------
  recPrio = function(self, rec, val)
    if val then
      db("summon.waitlist.record","setting record priority reason value:", val)
      rec[4] = val
    end
    return rec[4]
  end,

  ---------------------------------
  recRemove = function(self, player)
    local ret = false
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      ret = self:recRemoveIdx(idx)
    end
    return ret
  end,

  ---------------------------------
  recRemoveIdx = function(self, idx)
    local ret = false
    if idx and idx <= #self.waiting then
      db("summon.waitlist.record", "removing", self:recPlayer(self.waiting[idx]), "from the waiting list")
      table.remove(self.waiting, idx)
      self.numwaiting = self.numwaiting - 1
      ret = true
    else
      db("summon.waitlist.record","invalid index for remove", idx)
    end
    return ret
  end,

  recAdd = function(self, rec, pos)
    if not pos or pos > #self.waiting then
      db("summon.waitlist.record","appending record to waiting list for", self:recPlayer(rec))
      table.insert(self.waiting, rec)
    else
      db("summon.waitlist.record","adding record to waiting list index", pos,"for", self:recPlayer(rec))
      table.insert(self.waiting, pos, rec)
    end
    self.numwaiting = self.numwaiting + 1
  end,

  ---------------------------------
  addWaiting = function(self, player)
    local isWaiting = self:findWaitingPlayer(player)
    if isWaiting then
      db("summon.waitlist", "Resetting status of player", player, "to requested")
      self:recStatus(isWaiting, "requested")-- allow those in summon queue to reset status when things go wrong
      return
    end
    player = strsplit("-", player)
    db("summon.waitlist", "Making some space for ", player)

    -- priorities
    local inserted = false

    -- Prio warlock
    if SteaSummonSave.warlocks and addonData.util:playerCanSummon(player) then
      db("summon.waitlist", "Warlock " .. player .. " gets prio")
      self:recAdd(self:waitRecord(player, 0, "requested", "warlock"), 1)
      inserted = true
    end

    -- Prio buffs
    local buffs = addonData.buffs:report(player) -- that's all for now, just observing
    if not inserted and SteaSummonSave.buffs == true and #buffs > 0 then
      for k, wait in pairs(self.waiting) do
        if not (self:recPrio(wait) == "warlock" or self:recPrio(wait) == "buffed") then
          self:recAdd(self:waitRecord(player, 0, "requested", "buffed"), k)
          db("summon.waitlist", "Buffed " .. player .. " gets prio")
          inserted = true
          break
        end
      end
    end

    -- Prio list
    if not inserted and addonData.settings:findPrioPlayer(player) ~= nil then
      for k, wait in pairs(self.waiting) do
        if not (self:recPrio(wait) == "warlock" or self:recPrio(wait) == "buffed"
            or addonData.settings:findPrioPlayer(self:recPlayer(wait))) then
          self:recAdd(self:waitRecord(player, 0, "requested", "prioritized"), k)
          db("summon.waitlist", "Priority " .. player .. " gets prio")
          inserted = true
          break
        end
      end
    end

    -- Prio last
    if not inserted and addonData.settings:findShitlistPlayer(player) ~= nil then
      self:recAdd(self:waitRecord(player, 0, "requested", "last"))
      inserted = true
    end

    -- Prio normal
    if not inserted then
      local i = self.numwaiting + 1
      while i > 1 and self:recPrio(self.waiting[i-1]) == "last"
          and not (self:recPrio(self.waiting[i-1]) == "buffed"
          or self:recPrio(self.waiting[i-1]) == "warlock"
          or self:recPrio(self.waiting[i-1]) == "prioritized") do
        db("summon.waitlist", self:recPlayer(self.waiting[i-1]), "on shitlist, finding a better spot")
        i = i - 1
      end
      self:recAdd(self:waitRecord(player, 0, "requested", "normal"), i)
    end

    db("summon.waitlist", player .. " added to waiting list")
    self:showSummons()
  end,

  ---------------------------------
  tick = function(self)
    --- update our location
    self:setCurrentLocation()

    --- update timers
    -- yea this is dumb, but time doesnt really work in wow
    -- so we count (rough) second ticks for how long someone has been waiting
    -- and need to update each individually (a global would wrap)
    for _, wait in pairs(self.waiting) do
      self:recTimeIncr(wait)
    end

    --- detect arriving players
    local players = {}
    for _, wait in pairs(self.waiting) do
      local player = self:recPlayer(wait)
      if addonData.util:playerClose(player) then
        db("summon.tick", player .. " detected close by")
        table.insert(players, player) -- don't mess with tables while iterating on them
      end
    end

    for _, player in pairs(players) do
      local z, l = self:getCurrentLocation()
      if z == self.zone and l == self.location then
        self:arrived(player)
        addonData.gossip:arrived(player) -- let everyone else know
      end
    end

    --- update display
    self:showSummons()
  end,

  ---------------------------------
  getWaiting = function(self) return self.waiting end,

  ---------------------------------
  showSummons = function(self)
    if InCombatLockdown() then
      return
    end

    if not SummonFrame then
      g_self = self
      local f = CreateFrame("Frame", "SummonFrame", UIParent, "AnimatedShineTemplate")--, "DialogBoxFrame")
      f:SetPoint("CENTER")
      f:SetSize(300, 250)
      f:SetScale(SteaSummonSave.windowSize)
      local wpos = addonData.settings:getWindowPos()
      if wpos and #wpos > 0 then
        f:ClearAllPoints()
        f:SetPoint(wpos[1], wpos[2], wpos[3], wpos[4], wpos[5])
        --f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", wpos["left"], wpos["top"])
        f:SetSize(wpos["width"], wpos["height"])
        db("summon.display",  wpos[1], wpos[2], wpos[3], wpos[4], wpos[5], "width:", wpos["width"], "height:", wpos["height"])
      end

      f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        --"Interface\\BlackMarket\\BlackMarketBackground-BottomShadow",
        --"Interface\\DRESSUPFRAME\\DressupBackground-VoidElf1", --"Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\PVPFrame\\UI-Character-PVP-Highlight", -- this one is neat
        edgeSize = 16,
        insets = { left = 8, right = 6, top = 8, bottom = 8 },
      })
      f:SetBackdropColor(.57, .47, .85, 0.5) -- (147, 112, 219) purple
      f:SetBackdropBorderColor(.57, .47, .85, 0.5)

      --- Movable
      f:SetMovable(true)
      f:SetClampedToScreen(true)
      f:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
          self:StartMoving()
        end
      end)

      local movefunc = function(self, _)
        SummonFrame:StopMovingOrSizing()
        SummonFrame:SetUserPlaced(false)

        local p1, p2, p3, p4, p5 = SummonFrame:GetPoint()
        local pos = {p1, p2, p3, p4, p5}
        pos["width"] = SummonFrame:GetWidth()
        pos["height"] = SummonFrame:GetHeight()

        addonData.settings:setWindowPos(pos)

        db("summon.display", pos[1], pos[2], pos[3], pos[4], pos[5], "width:", pos["width"], "height:", pos["height"])
        if pos["height"] < 65 then
          ButtonFrame:Hide()
          ScrollFrame:Hide()
        else
          ScrollFrame:Show()
          ButtonFrame:Show()
        end

        if pos["height"] < 42 then
          ShardIcon:Hide()
        else
          ShardIcon:Show()
        end

        if pos["height"] < 26 then
          SummonToButton:Hide()
        else
          SummonToButton:Show()
        end

        if pos["width"] < 140 then
          SummonFrame.location:Hide()
          SummonFrame.destination:Hide()
        else
          SummonFrame.location:Show()
          SummonFrame.destination:Show()
        end
      end

      f:SetScript("OnMouseUp", movefunc)

      --- ScrollFrame
      local sf = CreateFrame("ScrollFrame", "ScrollFrame", SummonFrame, "UIPanelScrollFrameTemplate")
      sf:SetPoint("LEFT", 8, 0)
      sf:SetPoint("RIGHT", -40, 0)
      sf:SetPoint("TOP", 0, -32)
      sf:SetScale(0.5)

      addonData.buttonFrame = CreateFrame("Frame", "ButtonFrame", SummonFrame)
      addonData.buttonFrame:SetSize(sf:GetSize())
      addonData.buttonFrame:SetScale(SteaSummonSave.listSize)
      sf:SetScrollChild(addonData.buttonFrame)

      --- Table of summon info
      addonData.buttons = {}
      for i=1, 36 do
        self:createButton(i)
      end

      --- Setup Next button
      addonData.buttons[36].Button:SetPoint("TOPLEFT","SummonFrame","TOPLEFT", -10, 10)
      addonData.buttons[36].Button:SetText("Next")


      --- Resizable
      f:SetResizable(true)
      f:SetMinResize(80, 25)
      f:SetClampedToScreen(true)

      local rb = CreateFrame("Button", "ResizeButton", SummonFrame)
      rb:SetPoint("BOTTOMRIGHT", -6, 7)
      rb:SetSize(8, 8)

      rb:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
      rb:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
      rb:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")

      rb:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
          f:StartSizing("BOTTOMRIGHT")
          self:GetHighlightTexture():Hide() -- more noticeable
        end
      end)
      rb:SetScript("OnMouseUp", movefunc)

      if addonData.util:playerCanSummon() then
        local summonTo = function(otherself, button, worked)
          if button == "LeftButton" and worked then
            if self.infoSend then
              SummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Up")
              self:setDestination(self.myZone, self.myLocation)
              addonData.gossip:destination(self.myZone, self.myLocation)
            else
              SummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
              self:setDestination("", "")
              addonData.gossip:destination("", "")
            end
            self.infoSend = not self.infoSend
          end
        end

        --- summon to button
        local place = CreateFrame("Button", "SummonToButton", SummonFrame)
        place:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
        place:SetHighlightTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
        place:SetPushedTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
        place:SetPoint("TOPLEFT","SummonFrame", "TOPLEFT", 42, -8)
        place:SetSize(16,16)
        place:SetScript("OnMouseUp", summonTo)
      end

      if self.isWarlock then
        --- shard count icon
        f.shards = CreateFrame("Frame", "ShardIcon", SummonFrame)
        f.shards:SetBackdrop({
          bgFile = "Interface\\ICONS\\INV_Misc_Gem_Amethyst_02",
        })
        f.shards:SetPoint("TOPLEFT","SummonFrame", "TOPLEFT", 45, -24)
        --shards:SetAlpha(0.5)
        f.shards:SetSize(12,12)

        f.shards.count = f.shards:CreateFontString(nil,"ARTWORK", nil, 7)
        f.shards.count:SetFont("Fonts\\ARIALN.ttf", 12, "BOLD")
        f.shards.count:SetPoint("CENTER","ShardIcon", "CENTER", 5, -5)
        f.shards.count:SetText("0")
        f.shards.count:SetTextColor(1,1,1,1)
        f.shards.count:Show()
        self.shards = self:shardCount()
      end

      --- Text items
      f.location = f:CreateFontString(nil,"ARTWORK")
      f.location:SetFont("Fonts\\ARIALN.ttf", 8, "OUTLINE")
      f.location:SetPoint("TOPLEFT","SummonFrame", "TOPLEFT", 70, -16)
      f.location:SetAlpha(.5)
      f.location:SetText("")

      f.destination = f:CreateFontString(nil,"ARTWORK")
      f.destination:SetFont("Fonts\\ARIALN.ttf", 8, "OUTLINE")
      f.destination:SetPoint("TOPLEFT","SummonFrame", "TOPLEFT", 70, -8)
      f.destination:SetAlpha(.5)
      f.destination:SetText("")

      f.status = f:CreateFontString(nil,"ARTWORK")
      f.status:SetFont("Fonts\\ARIALN.ttf", 8, "OUTLINE")
      f.status:SetPoint("TOPLEFT","SummonFrame", "TOPLEFT", -30, -20)
      f.status:SetAlpha(.5)
      f.status:SetText("")

      movefunc()

      db("summon.display","Screen Size (w/h):", GetScreenWidth(), GetScreenHeight() )
    end

    --- update buttons
    local next = false
    for i=1, 35 do
      local player = nil
      local summonClick = nil
      local cancelClick = nil

      if self.waiting[i] ~= nil then
        self:enableButton(i)
        player = self:recPlayer(self.waiting[i])
        addonData.buttons[i].Button:SetText(player)

        if self:recStatus(self.waiting[i]) == "offline" then
          addonData.buttons[i].Status["FS"]:SetTextColor(0.2,0.2,0.2, 1)
        else
          _, class = UnitClass(player)
          r,g,b,_ = GetClassColor(class)
          addonData.buttons[i].Status["FS"]:SetTextColor(r,g,b, 1)
        end

        if (addonData.util:playerCanSummon()) then
          addonData.buttons[i].Button:SetAttribute("macrotext", "/target " .. player .. "\n/cast Ritual of Summoning")
        end
      else
        self:enableButton(i, false)
      end

      local z,l = self:getCurrentLocation()

      if (addonData.util:playerCanSummon()) then
        summonClick = function(otherself, button, worked)
          if button == "LeftButton" and worked then
            db("summon.display","summoning ", player)
            addonData.gossip:status(player, "pending")
            addonData.chat:raid(SteaSummonSave.raidchat, player)
            addonData.chat:say(SteaSummonSave.saychat, player)
            addonData.chat:whisper(SteaSummonSave.whisperchat, player)
            self.summoningPlayer = player
            self:summoned(player)
            self:setDestination(z, l)
            addonData.gossip:destination(z, l)
            self.hasSummoned = true
          end
        end
        addonData.buttons[i].Button:SetScript("OnMouseUp", summonClick)
      end

      --- Cancel Button
      -- Can cancel from own UI
      -- Cancelling self sends msg to others
      -- If summoning warlock, can cancel and send msg to others
      cancelClick = function(otherself, button, worked)
        if button == "LeftButton" and worked then
          if hasSummoned then
            addonData.gossip:arrived(player)
          end
          db("summon.display","cancelling ", player)
          self:recRemove(player)
        end
      end

      addonData.buttons[i].Cancel:SetScript("OnMouseUp", cancelClick)

      if self.waiting[i]  then
        --- Next Button
        if not next and self:recStatus(self.waiting[i]) == "requested" and addonData.util:playerCanSummon() then
          next = true
          addonData.buttons[36].Button:SetAttribute("macrotext", "/target " .. player .. "\n/cast Ritual of Summoning")
          addonData.buttons[36].Button:SetScript("OnMouseUp", summonClick)
          addonData.buttons[36].Button:Show()
        end

        --- Time
        addonData.buttons[i].Time["FS"]:SetText(string.format(SecondsToTime(self:recTime(self.waiting[i]))))
        local strwd = addonData.buttons[i].Time["FS"]:GetStringWidth()
        if strwd < 60 then
          addonData.buttons[i].Time:SetWidth(80)
        else
          addonData.buttons[i].Time:SetWidth(strwd+20)
        end

        --- Status
        addonData.buttons[i].Status["FS"]:SetText(self:recStatus(self.waiting[i]))
      end
    end


    if not next then
      -- all summons left are pending, disable the next button
      addonData.buttons[36].Button:Hide()
    end

    --- show summon window
    local show = false
    if addonData.settings:showWindow() or (addonData.settings:showActive() and self.numwaiting > 0) then
      show = true
    elseif addonData.settings:showJustMe() then
      local me, _ = UnitName("player")

      if self:findWaitingPlayer(me) then
        show = true
      end
    end

    if show then
      SummonFrame:Show()
      if self.numwaiting > 0 then
        addonData.monitor:start() -- start ui update tick
      end
    else
      SummonFrame:Hide()
      addonData.monitor:stop() -- stop ui update tick
    end

    if self.numwaiting == 0 then
      self.hasSummoned = false
    end
  end,

  ---------------------------------
  shardCount = function(self)
    local count = 0
    if ShardIcon then
      local _, itemLink = GetItemInfo("Soul Shard")
      for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, GetContainerNumSlots(bag) do
          if(GetContainerItemLink(bag, slot) == itemLink) then
            count = count + 1
          end
        end
      end
      ShardIcon.count:SetText(tostring(count))
    end
    return count
  end,

  ---------------------------------
  createButton = function(self, i)
    -- Summon Button
    local bw = 80
    local bh = 25
    local wpad = 40
    local hpad = 20

    local parent = addonData.buttonFrame
    if i == 36 then
      parent = SummonFrame
    end

    local tex, texDisabled,texHighlight, texPushed, icon

    addonData.buttons[i] = {}
    addonData.buttons[i].Button = CreateFrame("Button", "SummonButton"..i, parent, "SecureActionButtonTemplate");
    addonData.buttons[i].Button:SetPoint("TOPLEFT","ButtonFrame","TOPLEFT", wpad,-((i*bh)+hpad))
    addonData.buttons[i].Button:SetText("Stea")
    addonData.buttons[i].Button:SetNormalFontObject("GameFontNormalSmall")
    tex = addonData.buttons[i].Button:CreateTexture()
    texHighlight = addonData.buttons[i].Button:CreateTexture()
    texPushed = addonData.buttons[i].Button:CreateTexture()
    texDisabled = addonData.buttons[i].Button:CreateTexture()
    if i < 36 then
      addonData.buttons[i].Button:SetWidth(bw)
      addonData.buttons[i].Button:SetHeight(bh)
      tex:SetTexture("Interface/Buttons/UI-Panel-Button-Up")
      tex:SetTexCoord(0, 0.625, 0, 0.6875)
      texHighlight:SetTexture("Interface/Buttons/UI-Panel-Button-Highlight")
      texHighlight:SetTexCoord(0, 0.625, 0, 0.6875)
      texPushed:SetTexture("Interface/Buttons/UI-Panel-Button-Down")
      texPushed:SetTexCoord(0, 0.625, 0, 0.6875)
      texDisabled:SetTexture("Interface/Buttons/UI-Panel-Button-Disabled")
      texDisabled:SetTexCoord(0, 0.625, 0, 0.6875)
    else
      addonData.buttons[i].Button:ClearAllPoints()
      addonData.buttons[i].Button:SetWidth(bw - 30)
      addonData.buttons[i].Button:SetHeight(bw - 30)
      tex:SetTexCoord(0, 1, 0, 1)
      tex:SetTexture("Interface/Buttons/UI-QuickSlot")
      texHighlight:SetTexture("Interface/Buttons/UI-QuickSlot-Depress")
      texHighlight:SetTexCoord(0, 1, 0, 1)
      texPushed:SetTexture("Interface/Buttons/UI-QuickSlot2")
      texPushed:SetTexCoord(0, 1, 0, 1)
      texDisabled:SetTexture("Interface/Buttons/UI-QuickSlotRed")
      texDisabled:SetTexCoord(0, 1, 0, 1)
      -- icon
      icon = addonData.buttons[i].Button:CreateTexture()
      icon:SetTexture("Interface/ICONS/Spell_Shadow_Twilight")
      icon:SetTexCoord(0, 1, 0, 1)
      icon:SetAllPoints()
    end

    tex:SetAllPoints()
    addonData.buttons[i].Button:SetNormalTexture(tex)

    texHighlight:SetAllPoints()
    addonData.buttons[i].Button:SetHighlightTexture(texHighlight)

    texPushed:SetAllPoints()
    addonData.buttons[i].Button:SetPushedTexture(texPushed)

    texDisabled:SetAllPoints()
    addonData.buttons[i].Button:SetDisabledTexture(texDisabled)

    addonData.buttons[i].Button:RegisterForClicks("LeftButtonUp")
    addonData.buttons[i].Button:SetAttribute("type1", "macro");
    addonData.buttons[i].Button:SetAttribute("macrotext", "")

    if i < 36 then -- last button we use for next summon, so don't want these
      -- Cancel
      addonData.buttons[i].Cancel = CreateFrame("Button", "CancelButton"..i, parent, "UIPanelCloseButtonNoScripts")
      addonData.buttons[i].Cancel:SetWidth(bh)
      addonData.buttons[i].Cancel:SetHeight(bh)
      addonData.buttons[i].Cancel:SetText("X")
      addonData.buttons[i].Cancel:SetPoint("TOPLEFT","ButtonFrame","TOPLEFT", 10,-((i*bh)+hpad))

      -- Wait Time
      addonData.buttons[i].Time = CreateFrame("Frame", "SummonWaitTime"..i, addonData.buttonFrame)
      addonData.buttons[i].Time:SetWidth(bw)
      addonData.buttons[i].Time:SetHeight(bh)
      addonData.buttons[i].Time:SetPoint("TOPLEFT", addonData.buttonFrame, "TOPLEFT",bw + wpad + 90,-((i*bh)+hpad))
      addonData.buttons[i].Time:SetBackdrop( {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 5, edgeSize = 15, insets = { left = 1, right = 1, top = 1, bottom = 1 }
      });

      addonData.buttons[i].Time["FS"] = addonData.buttons[i].Time:CreateFontString("TimeText"..i,"ARTWORK", "ChatFontNormal")
      addonData.buttons[i].Time["FS"]:SetParent(addonData.buttons[i].Time)
      addonData.buttons[i].Time["FS"]:SetPoint("TOP",addonData.buttons[i].Time,"TOP",0,0)
      addonData.buttons[i].Time["FS"]:SetWidth(bw)
      addonData.buttons[i].Time["FS"]:SetHeight(bh)
      addonData.buttons[i].Time["FS"]:SetJustifyH("CENTER")
      addonData.buttons[i].Time["FS"]:SetJustifyV("CENTER")
      addonData.buttons[i].Time["FS"]:SetFontObject("GameFontNormalSmall")
      addonData.buttons[i].Time["FS"]:SetText(string.format(SecondsToTime(0)))

      -- Status
      addonData.buttons[i].Status = CreateFrame("Frame", "SummonStatus"..i, addonData.buttonFrame)
      addonData.buttons[i].Status:SetWidth(bw)
      addonData.buttons[i].Status:SetHeight(bh)
      addonData.buttons[i].Status:SetPoint("TOPLEFT", addonData.buttonFrame, "TOPLEFT",bw + wpad + 5,-((i*bh)+hpad))
      addonData.buttons[i].Status:SetBackdrop( {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 5, edgeSize = 15, insets = { left = 1, right = 1, top = 1, bottom = 1 }
      });
      addonData.buttons[i].Status["FS"] = addonData.buttons[i].Status:CreateFontString("StatusText"..i,"ARTWORK", "ChatFontNormal")
      addonData.buttons[i].Status["FS"]:SetParent(addonData.buttons[i].Status)
      addonData.buttons[i].Status["FS"]:SetPoint("TOP",addonData.buttons[i].Status,"TOP",0,0)
      addonData.buttons[i].Status["FS"]:SetWidth(bw)
      addonData.buttons[i].Status["FS"]:SetHeight(bh)
      addonData.buttons[i].Status["FS"]:SetJustifyH("CENTER")
      addonData.buttons[i].Status["FS"]:SetJustifyV("CENTER")
      addonData.buttons[i].Status["FS"]:SetFontObject("GameFontNormalSmall")
      addonData.buttons[i].Status["FS"]:SetTextColor(1,1,1)
      addonData.buttons[i].Status["FS"]:SetText("Waiting")
    end
  end,

  ---------------------------------
  enableButton = function(self, idx, enable)
    if enable == nil then
      enable = true
    end

    if enable then
      if not InCombatLockdown() then
        addonData.buttons[idx].Button:Show()
        addonData.buttons[idx].Cancel:Show()
        addonData.buttons[idx].Time:Show()
        addonData.buttons[idx].Status:Show()
        addonData.buttons[idx].Button:Enable()
      end
    else
      if not InCombatLockdown() then
        addonData.buttons[idx].Button:Hide()
        addonData.buttons[idx].Cancel:Hide()
        addonData.buttons[idx].Time:Hide()
        addonData.buttons[idx].Status:Hide()
        addonData.buttons[idx].Button:Enable()
      end
    end
  end,

  ---------------------------------
  enableButtons = function(self, enable)
    for i=1, 35 do
      self:enableButton(i, enable)
    end
  end,

  ---------------------------------
  findWaitingPlayerIdx = function(self, player)
    for i, wait in pairs(self.waiting) do
      if self:recPlayer(wait) == player then
        return i
      end
    end
    return nil
  end,

  ---------------------------------
  findWaitingPlayer = function(self, player)
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      return self.waiting[idx]
    end
    return nil
  end,

  ---------------------------------
  summoned = function(self, player)
    -- update status
    waitEntry = self:findWaitingPlayer(player)
    if waitEntry ~= nil then
      db("summon.waitlist", "a summon is pending for " .. player)
      self:recStatus(waitEntry, "pending")
    end
  end,

  ---------------------------------
  status = function(self, player, status)
    -- update status
    waitEntry = self:findWaitingPlayer(player)
    if waitEntry ~= nil then
      db("summon.waitlist", "status changed to", status, "for", player)
      self:recStatus(waitEntry, status)
    end
  end,

  ---------------------------------
  arrived = function(self, player)
    self:remove(player)
  end,

  ---------------------------------
  summonFail = function(self)
    local idx = self:findWaitingPlayerIdx(self.summoningPlayer)
    if idx then
      db("summon.waitlist", "something went wrong, resetting status of " .. self.summoningPlayer .. " to requested")
      self:recStatus(self.waiting[idx], "requested")
      addonData.gossip:status(self.summoningPlayer, "requested")
    end
  end,

  ---------------------------------
  summonSuccess = function(self)
    local idx = self:findWaitingPlayerIdx(self.summoningPlayer)
    if idx then
      db("summon.waitlist", "summon succeeded, setting status of " .. self.summoningPlayer .. " to summoned")
      self:recStatus(self.waiting[idx], "summoned")
      addonData.gossip:status(self.summoningPlayer, "summoned")
    end
  end,

  offline = function(self, offline, player)
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      local state = ""
      if offline then
        db("summon.waitlist", "setting status of " .. player .. " to offline")
        state = "offline"
      else
        if self:recStatus(self.waiting[idx]) == "offline" then
          db("summon.waitlist", "setting status of " .. player .. " from offline to waiting")
          state = "waiting"
        end
      end
      if state ~= "" then
        self:recStatus(self.waiting[idx], state)
      end
    end
  end,

  remove = function(self, player)
    return self:recRemove(player)
  end,

  dead = function(self, dead, player)
    local idx = self:findWaitingPlayerIdx(player)
    if idx then
      local state = ""
      if dead then
        state = "dead"
        db("summon.waitlist", "setting status of", player, "to dead")
      else
        if self.waiting[idx][3] == "dead" then
          db("summon.waitlist", "setting status of", player, "from dead to waiting")
          state = "waiting"
        end
      end
      if state ~= "" then
        self:recStatus(self.waiting[idx], state)
      end
    end
  end,

  ---------------------------------
  callback = function(self, event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
      -- entered combat, stop everything or we might get tainted
      SummonFrame:Hide()
    end
    if event == "PLAYER_REGEN_ENABLED" then
      -- start things up again, nothing to do
    end
  end,

  ---------------------------------
  getCurrentLocation = function(self)
    return self.myZone, self.myLocation
  end,

  ---------------------------------
  setCurrentLocation = function(self)
    self.myZone, self.myLocation = GetZoneText(), GetMinimapZoneText()

    if self.myZone == self.zone and self.myLocation == self.location then
      SummonFrame.destination:SetTextColor(0,1,0,.5)
      SummonFrame.location:SetTextColor(0,1,0,.5)
      if SummonToButton then
        SummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Up")
      end
    else
      SummonFrame.destination:SetTextColor(1,1,1,.5)
      SummonFrame.location:SetTextColor(1,0,0,.5)
      if SummonToButton then
        SummonToButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-MOTD-Disabled")
      end
    end

    SummonFrame.location:SetText("Location: " .. self.myZone .. ", " .. self.myLocation)
  end,

  ---------------------------------
  setDestination = function(self, zone, location)
    self.location = location
    self.zone = zone

    db("summon.misc", "setting destination: ", location, " in ", zone)
    if location and location ~= "" and zone and zone ~= "" then
      SummonFrame.destination:SetText("Destination: " .. self.location .. ", " .. self.zone)
    else
      SummonFrame.destination:SetText("")
    end
  end,

  ---------------------------------
  castWatch = function(self, event, target, castUID, spellId, ...)
    db("summon.spellcast", event, " ", target, castUID, spellId, ...)

    local name, rank, icon, castTime, minRange, maxRange = GetSpellInfo(spellId)
    db("summon.spellcast", name, rank, castTime, minrange, maxrange)

    -- these events can get posted up to 3 times (at least testing on myself) player, raid1 (me), target
    -- observed:
    -- when target is you, get target message. otherwise no
    -- guesses:
    -- you get target if target is casting
    -- you get player if you are casting
    -- you get raid1 if there is a raid (not party) if someone in your raid is casting (even if it is you) *** if true this is very cool

    -- only interested in summons cast by player for now
    if target ~= "player" then
      return
    end

    --db("summon.spellcast", "cast info: ", UnitCastingInfo(unit)) internal blizz call? Their code def calls this

    if event == "UNIT_SPELLCAST_START" then
      -- cast started, register this
      -- {raider}
      --local cast = cw_spells[castUID]
      --if not cast then
      --cast = {UnitName(target)}
      --cw_spells[castUID] = cast
      --db(cast[1])
      --end

    elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
      -- never seen this
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
      -- end of cast, into channel
    elseif event == "UNIT_SPELLCAST_DELAYED" then
      -- presumably if you get hit while casting
    elseif event == "UNIT_SPELLCAST_STOP" then
      -- this is a normal end of cast
      if g_self.isWarlock then
        g_self.shards = addonData.summon.shardCount(g_self)
      end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
      if g_self.isWarlock then
        local oldCount = g_self.shards
        g_self.shards = addonData.summon.shardCount(g_self)
        if name == "Ritual of Summoning" then
          --- update shards (if shard count decreased then the summon went through!)
          if oldCount > g_self.shards then
            addonData.summon.summonSuccess(g_self)
          end
        end
      end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_FAILED" then
      -- something went wrong
      -- no castid for stop lol
      if name == "Ritual of Summoning" then
        addonData.summon.summonFail(g_self)
      end
    end
  end,
}

    addonData.summon = summon
