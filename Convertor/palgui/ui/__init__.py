"""palgui.ui - the PySide6 layer.

NOTHING BELOW THIS PACKAGE IMPORTS QT.  settings / runner / presets / jobs run
headless and are tested that way, so the argv the GUI would have built can be
checked - and a queue can be run - from a script or a CI step with no display
and no PySide6 installed at all.
"""
