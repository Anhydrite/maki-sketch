-- Package entry point. maki loads every `plugin/*.lua` file of an installed
-- package; the real module lives in `lua/sketch.lua`.
local sketch = require("sketch")

sketch.setup({
  width = "60%",
  max_legend = 8,
})
