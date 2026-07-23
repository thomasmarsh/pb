HA$PBExportHeader$radiobutton.sru

global type radiobutton from dragobject
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

on radiobutton.clicked
end on

on radiobutton.constructor
end on

on radiobutton.destructor
end on

on radiobutton.dragdrop
end on

on radiobutton.dragenter
end on

on radiobutton.dragleave
end on

on radiobutton.dragwithin
end on

on radiobutton.getfocus
end on

on radiobutton.losefocus
end on
