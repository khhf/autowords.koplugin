local _ = require("gettext")
return {
    fullname = _("AutoWords"),
    description = _([[
Automatic page turning paced by the amount of text on the page.

Instead of a fixed timeout, the delay before each page turn is computed
from the actual word/character count of the current page and a reading
speed you can calibrate on the very page you are looking at.]]),
}
