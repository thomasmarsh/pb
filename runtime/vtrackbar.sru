HA$PBExportHeader$vtrackbar.sru

global type vtrackbar from dragobject
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
vtickmarks TickMarks
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

on vtrackbar.constructor
end on

on vtrackbar.destructor
end on

on vtrackbar.dragdrop
end on

on vtrackbar.dragenter
end on

on vtrackbar.dragleave
end on

on vtrackbar.dragwithin
end on

on vtrackbar.getfocus
end on

on vtrackbar.linedown
end on

on vtrackbar.lineup
end on

on vtrackbar.losefocus
end on

on vtrackbar.moved
end on

on vtrackbar.pagedown
end on

on vtrackbar.pageup
end on
