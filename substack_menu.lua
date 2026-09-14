local Menu = require("ui/widget/menu")

local SubstackMenu = Menu:extend{}

function SubstackMenu:onMenuHold(item)
    if item and item.hold_callback then
        item.hold_callback(self, item)
        return true
    end
    return Menu.onMenuHold(self, item)
end

return SubstackMenu
