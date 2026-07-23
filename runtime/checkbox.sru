HA$PBExportHeader$checkbox.sru

global type checkbox from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean Automatic
long BackColor
borderstyle BorderStyle
boolean BringToTop
boolean Checked
powerobject ClassDefinition
boolean DragAuto
string DragIcon
boolean Enabled
string FaceName
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean Italic
boolean LeftText
string Pointer
boolean RightToLeft
integer TabOrder
string Tag
string Text
long TextColor
integer TextSize
boolean ThirdState
boolean ThreeState
boolean Underline
boolean Visible
integer Weight
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer drag (dragmodes m)
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

on checkbox.clicked
end on

on checkbox.constructor
end on

on checkbox.destructor
end on

on checkbox.dragdrop
end on

on checkbox.dragenter
end on

on checkbox.dragleave
end on

on checkbox.dragwithin
end on

on checkbox.getfocus
end on

on checkbox.losefocus
end on
