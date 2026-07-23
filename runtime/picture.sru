HA$PBExportHeader$picture.sru

global type picture from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean DragAuto
string DragIcon
boolean Enabled
boolean FocusRectangle
integer Height
boolean Invert
boolean Map3DColors
boolean OriginalSize
string PictureName
string Pointer
long PowerTipText
integer TabOrder
string Tag
boolean Visible
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer drag (dragmodes m)
end function

public function integer draw (any xlocation, any ylocation)
end function

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer move (any x, any y)
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function boolean postevent (string event, long word, any long)
end function

public function integer print ()
end function

public function integer resize (any width, any height)
end function

public function integer setfocus ()
end function

public function integer setpicture (blob bimage)
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on picture.clicked
end on

on picture.constructor
end on

on picture.destructor
end on

on picture.doubleclicked
end on

on picture.dragdrop
end on

on picture.dragenter
end on

on picture.dragleave
end on

on picture.dragwithin
end on

on picture.getfocus
end on

on picture.losefocus
end on
