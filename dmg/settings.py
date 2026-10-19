# Оформление окна DMG (используется dmgbuild при сборке на GitHub)
import os

app = defines.get("app", "build/Raskladka.app")  # noqa: F821 — переменная передаётся dmgbuild
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"

background = "dmg/background.png"
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (165, 185),
    "Applications": (495, 185),
}
