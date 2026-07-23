HA$PBExportHeader$animation.sru

global type animation from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
string AnimationName
boolean AutoPlay
boolean Border
borderstyle BorderStyle
boolean BringToTop
powerobject ClassDefinition
boolean DragAuto
string DragIcon
boolean Enabled
integer Height
boolean OriginalSize
string Pointer
long PowerTipText
integer TabOrder
string Tag
boolean Transparent
boolean Visible
integer Width
integer X
integer Y
end variables

public function string classname ()
end function

public function integer drag ()
end function

public function integer getcontextservice ()
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer move ()
end function

public function integer play ()
end function

public function integer pointerx ()
end function

public function integer pointery ()
end function

public function boolean postevent ()
end function

public function integer resize ()
end function

public function integer seek ()
end function

public function integer setfocus ()
end function

public function integer setposition ()
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer stop ()
end function

public function integer triggerevent ()
end function

public function any typeof ()
end function

on animation.constructor
end on

on animation.destructor
end on

on animation.start
end on

on animation.stop
end on
