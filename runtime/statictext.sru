HA$PBExportHeader$statictext.sru

global type statictext from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
alignment Alignment
long BackColor
boolean Border
long BorderColor
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean DisabledLook
boolean DragAuto
string DragIcon
boolean Enabled
string FaceName
fillpattern FillPattern
boolean FocusRectangle
fontcharset FontCharSet
fontfamily FontFamily
fontpitch FontPitch
integer Height
boolean Italic
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

on statictext.clicked
end on

on statictext.constructor
end on

on statictext.destructor
end on

on statictext.doubleclicked
end on

on statictext.dragdrop
end on

on statictext.dragenter
end on

on statictext.dragleave
end on

on statictext.dragwithin
end on

on statictext.getfocus
end on

on statictext.losefocus
end on
