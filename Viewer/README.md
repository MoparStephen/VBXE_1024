# VBXE 1024 Colour Image Viewer
Slideshow viewer for new format 1024 colour images

#TODOs (ATARI Viewer):
About screen #1 (shows the convertor's report.txt for each image)
About screen #2 (shows all 4 palettes in 4 distinct quadrants)
File selector which can cycle through selected images in a subdirectory
	All images will consist of 4 files:
		.PAL (4 palettes merged into a single file)
		.RAW (the raw 320*240 image data)
		.MAP (the attribute map data)
		.NFO (report info on the file)
	The file selector will simply show one filename without an extension
	We should allow to just view the about text so we don't have to load approzimately 90kB of data to see the image
	We'll have to be very careful about error handling for opening & reading each file


