HA$PBExportHeader$hprogressbar.sru

global type hprogressbar from dragobject
end type

type variables
string AccessibleDescription
string AccessibleName
accessiblerole AccessibleRole
boolean BringToTop
powerobject ClassDefinition
boolean DragAuto
string DragIcon
integer Height
unsignedinteger MaxPosition
unsignedinteger MinPosition
string Pointer
integer Position
integer SetStep
boolean SmoothScroll
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

public function integer getcontextservice (string servicename, powerobject servicereference)
end function

public function powerobject getparent ()
end function

public function integer hide ()
end function

public function integer move (any x, any y)
end function

public function integer offsetpos (integer increment)
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

public function integer setrange (integer startpos, integer endpos)
end function

public function integer setredraw ()
end function

public function integer show ()
end function

public function integer stepit ()
end function

public function integer triggerevent (string event, long word, long long)
end function

public function any typeof ()
end function

on hprogressbar.clicked
end on

on hprogressbar.constructor
end on

on hprogressbar.destructor
end on

on hprogressbar.doubleclicked
end on

on hprogressbar.dragdrop
end on

on hprogressbar.dragenter
end on

on hprogressbar.dragleave
end on

on hprogressbar.dragwithin
end on

on hprogressbar.getfocus
end on

on hprogressbar.losefocus
end on
