HA$PBExportHeader$htrackbar.sru

global type htrackbar from dragobject
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
integer LineSize
integer MaxPosition
integer MinPosition
integer PageSize
string Pointer
integer Position
boolean Slider
integer SliderSize
integer TabOrder
string Tag
integer TickFrequency
htickmarks TickMarks
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

public function integer selectionrange (integer startpos, integer endpos)
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

on htrackbar.constructor
end on

on htrackbar.destructor
end on

on htrackbar.dragdrop
end on

on htrackbar.dragenter
end on

on htrackbar.dragleave
end on

on htrackbar.dragwithin
end on

on htrackbar.getfocus
end on

on htrackbar.lineleft
end on

on htrackbar.lineright
end on

on htrackbar.losefocus
end on

on htrackbar.moved
end on

on htrackbar.pageleft
end on

on htrackbar.pageright
end on
